//
//  SimTests.swift
//  BOMTalkTests
//

import Foundation
import Testing
@testable import BOMTalk

/// Full link transport stacks on the simulated radio network, on virtual time.
@Suite @MainActor struct SimTests {

	@Test func manualTimersOrder() {
		let timers = ManualTimers()
		var fired: [String] = []
		timers.schedule(after: .seconds(2)) { fired.append("b") }
		timers.schedule(after: .seconds(1)) {
			fired.append("a")
			timers.schedule(after: .milliseconds(500)) { fired.append("a2") }	// inside the window
			timers.schedule(after: .seconds(5)) { fired.append("late") }
		}
		timers.schedule(after: .seconds(2)) { fired.append("c") }	// tie: scheduling order
		timers.schedule(after: .seconds(1)) { fired.append("cancelled") }.cancel()
		#expect(timers.advance(by: .seconds(3)) == 4)
		#expect(fired == ["a", "a2", "b", "c"])
		#expect(timers.now == .seconds(3))
		#expect(timers.pendingCount == 1)
	}

	@Test func fullMeshConverges() async {
		let net = SimNetwork(count: 5, seed: 1)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { net.devices.allSatisfy { $0.peers(.connected).count == 4 } }, limit: .seconds(30)))
		for device in net.devices {
			#expect(net.sessionPeers(device.index).count == 4)
		}
	}

	/// More devices than session slots: nobody exceeds the cap, nobody hangs in connecting.
	@Test func sessionCap() async {
		let net = SimNetwork(count: 12, seed: 2)
		net.fullMesh()
		net.startAll()
		await net.run(for: .seconds(180))
		let stuck = net.now - MPCPolicy.watchdogDelay
		for device in net.devices {
			#expect(device.peers(.connected).count <= MPCPolicy.maxRemotePeers)
			#expect(device.peers(.connected).count >= 1)
			#expect(net.sessionPeers(device.index).count <= MPCPolicy.maxRemotePeers)
			#expect(!device.peers.values.contains { $0.state == .connecting && $0.since < stuck })
		}
		// connected views agree with the radio's links
		for device in net.devices {
			for other in device.peers(.connected) {
				#expect(net.isConnected(device.index, other))
				#expect(net[other].peers(.connected).contains(device.index))
			}
		}
	}

	/// Machines allowing more peers than a session holds: the radio refuses like MPC, sessions stay at
	/// the cap and failed attempts don't leave anyone in connecting.
	@Test func radioEnforcesCap() async {
		var config = SimConfig()
		config.maxPeers = 10
		let net = SimNetwork(count: 11, seed: 8, config: config)
		net.fullMesh()
		net.startAll()
		await net.run(for: .seconds(120))
		#expect(net.capRefusals > 0)
		let stuck = net.now - MPCPolicy.watchdogDelay
		for device in net.devices {
			#expect(net.sessionPeers(device.index).count <= config.sessionCapacity - 1)
			#expect(device.peers(.connected).count <= config.sessionCapacity - 1)
			#expect(!device.peers.values.contains { $0.state == .connecting && $0.since < stuck })
		}
	}

	@Test func dropReconnects() async throws {
		let net = SimNetwork(count: 2, seed: 3)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { net.isConnected(0, 1) && net[0].peers(.connected) == [1] && net[1].peers(.connected) == [0] }))
		net.drop(0, 1)
		await net.settle()
		#expect(net[0].peers(.connected).isEmpty && net[1].peers(.connected).isEmpty)
		#expect(net[0].peers(.visible) == [1] && net[1].peers(.visible) == [0])
		let dropped = net.now
		#expect(await net.run(until: { net[0].peers(.connected) == [1] && net[1].peers(.connected) == [0] }, limit: .seconds(30)))
		#expect(net.now - dropped >= MPCPolicy.backoff[0])	// reconnected after backoff, not instantly
	}

	@Test func vanishAndReappear() async {
		let net = SimNetwork(count: 4, seed: 4)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { net.devices.allSatisfy { $0.peers(.connected).count == 3 } }))
		net.vanish(2)
		await net.run(for: .seconds(1))
		for index in [0, 1, 3] {
			#expect(net[index].peers[net[2].id] == nil)
			#expect(net[index].peers(.connected).count == 2)
		}
		#expect(net.log.contains { $0.hasSuffix("d0 lost d2") })
		net.reappear(2)
		#expect(await net.run(until: { net.devices.allSatisfy { $0.peers(.connected).count == 3 } }, limit: .seconds(60)))
	}

	@Test func hiddenPairOnlyConnectsInRange() async {
		let net = SimNetwork(count: 3, seed: 5)
		net.line()	// 0 – 1 – 2
		net.startAll()
		await net.run(for: .seconds(20))
		#expect(net[0].peers(.connected) == [1])
		#expect(net[1].peers(.connected) == [0, 2])
		#expect(net[2].peers(.connected) == [1])
		net.hide(1, 2)
		await net.run(for: .seconds(1))
		#expect(net[1].peers(.connected) == [0])
		#expect(net[2].peers.isEmpty)
	}

	@Test func blackholedLinkStallsData() async throws {
		let net = SimNetwork(count: 2, seed: 6)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { net[0].peers(.connected) == [1] && net[1].peers(.connected) == [0] }))
		net.blackhole(0, 1)
		try net[0].transport.send(Data([1, 2, 3]), to: net[1].id)
		await net.run(for: .seconds(1))
		#expect(!net[1].events.contains { if case .received = $0 { true } else { false } })
		net.blackhole(0, 1, false)
		try net[0].transport.send(Data([4]), to: net[1].id)
		await net.run(for: .seconds(1))
		#expect(net.log.contains { $0.hasSuffix("d1 received 1 d0") })
		#expect(throws: TalkError.notConnected) { try net[0].transport.send(Data(), to: UUID()) }
	}

	@Test func talkMessage() async throws {
		let net = SimNetwork(count: 2, seed: 7, talk: true)
		net.fullMesh()
		net.startAll()
		let a = try #require(net[0].talk), b = try #require(net[1].talk)
		#expect(await net.run(until: { a.connectedCount == 1 && b.connectedCount == 1 }))
		let inbox = Inbox<Chat>(b)
		let peer = try #require(a.peer(b))
		let sending = Task { try await a.send(Chat(text: "Hi"), to: peer) }
		#expect(await net.run(until: { inbox.messages == [Chat(text: "Hi")] }))
		try await net.value(of: sending)
		#expect(try inbox.results[0].get().peer.id == a.me.id)
	}

	@Test func deterministic() async {
		func scenario() async -> [String] {
			let net = SimNetwork(count: 10, seed: 42)
			net.random(probability: 0.6)
			net.startAll()
			await net.run(for: .seconds(20))
			net.drop(0, 1)
			net.vanish(3)
			await net.run(for: .seconds(20))
			net.reappear(3)
			await net.run(for: .seconds(30))
			return net.log
		}
		let first = await scenario(), second = await scenario()
		#expect(first.count > 100)
		#expect(first == second)
	}
}
