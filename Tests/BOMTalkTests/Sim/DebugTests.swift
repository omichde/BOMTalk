//
//  DebugTests.swift
//  BOMTalkTests
//

import Foundation
import Testing
@_spi(Debug) @testable import BOMTalk

/// The Debug SPI (`Talk.debugSnapshot()`, block list, disconnect, `TalkDebugOptions`) on the
/// simulated radio network, on virtual time.
@Suite(.serialized) @MainActor struct DebugTests {

	static func talk(_ net: SimNetwork, _ index: Int) throws -> Talk {
		try #require(net[index].talk)
	}

	/// A line of 4: the snapshot of an end shows the whole topology, and it survives JSON.
	@Test func snapshotReflectsTopology() async throws {
		var config = SimConfig()
		config.bandwidth = 100_000
		let net = SimNetwork(count: 4, seed: 71, config: config, talk: true, wrap: SimNetwork.relay)
		net.line()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(30)))
		await net.run(for: .seconds(5))
		let first = try Self.talk(net, 0)
		let snapshot = first.debugSnapshot()

		#expect(snapshot.me == .init(id: net[0].id, name: net[0].name))
		#expect(snapshot.isRunning && snapshot.issue == nil)
		#expect(snapshot.neighbours.map(\.id) == [net[1].id])
		#expect(snapshot.neighbours.map(\.name) == [net[1].name])
		#expect(snapshot.reachable.map(\.hops).sorted() == [1, 2, 3])
		#expect(snapshot.reachable.allSatisfy { $0.nextHop == net[1].id })
		#expect(snapshot.reachable.first { $0.id == net[3].id }?.name == net[3].name)
		#expect(Set(snapshot.map.map(\.id)) == Set(net.devices.dropFirst().map(\.id)))	// the others, not this device
		let entry = try #require(snapshot.map.first { $0.id == net[1].id })
		#expect(Set(entry.neighbours) == [net[0].id, net[2].id])
		#expect(entry.age >= 0 && entry.age < 10)
		#expect(snapshot.peers.count == 3 && snapshot.peers.allSatisfy { $0.state == "connected" })
		#expect(snapshot.counters.hellosSent > 0 && snapshot.counters.hellosReceived > 0)
		#expect(snapshot.counters.heartbeatBytesSent > 0 && snapshot.counters.recordRequestsSent == 0)
		#expect(snapshot.helloInterval == RelayPolicy.minHelloInterval.seconds)
		#expect(snapshot.counters.drops.keys.sorted() == RelayCounters.Drop.allCases.map(\.rawValue).sorted())
		#expect(snapshot.counters.entriesExpired == 0 && snapshot.counters.voluntaryDrops == 0)
		let slots = try #require(snapshot.slots)
		#expect(slots.regular == 1 && slots.bridge == 0 && slots.regularCapacity == 6 && slots.bridgeCapacity == 1)
		#expect(snapshot.suppressed.isEmpty && snapshot.bridgeCandidates.isEmpty && snapshot.blocked.isEmpty)
		#expect(snapshot.flags.contains("bridgeSlotFree") && !snapshot.flags.contains("regularSlotsFull"))
		#expect(snapshot.transfers.isEmpty)
		#expect(snapshot.clock > 0)

		// a transfer in flight shows up with its direction and sizes
		let last = try Self.talk(net, 3)
		let sending = FlowControlTests.send(Blob(data: randomData(300_000)), from: first, to: try #require(first.peer(last)))
		let inbox = Inbox<Blob>(last)
		#expect(await net.run(until: { !last.debugSnapshot().transfers.isEmpty && !first.debugSnapshot().transfers.isEmpty }, limit: .seconds(30)))
		let out = try #require(first.debugSnapshot().transfers.first)
		let incoming = try #require(last.debugSnapshot().transfers.first)
		#expect(out.direction == "outgoing" && out.kind == "blob" && out.peer == net[3].id && out.totalBytes > 300_000)
		#expect(incoming.direction == "incoming" && incoming.peer == net[0].id && incoming.id == out.id)
		#expect(await net.run(until: { sending.result != nil }, limit: .seconds(60)))
		#expect(sending.result == .success)
		#expect(await net.run(until: { inbox.messages.count == 1 }))
		#expect(first.debugSnapshot().transfers.isEmpty)

		let decoded = try JSONDecoder().decode(TalkDebugSnapshot.self, from: try JSONEncoder().encode(snapshot))
		#expect(decoded == snapshot)
		#expect(net.contractViolations.isEmpty)
	}

	/// Full visibility, but block lists leave only a chain d0–d1–d2–d3: links follow the lists, routes
	/// still reach everybody. Unblocking brings the shortcuts back.
	@Test func blockListForcesLine() async throws {
		let net = SimNetwork(count: 4, seed: 72, talk: true, wrap: SimNetwork.relay)
		net.fullMesh()
		let names = net.devices.map(\.name)
		// symmetric, so neither side keeps inviting the other
		let blocks: [Int: Set<String>] = [0: [names[2], names[3]], 1: [names[3]], 2: [names[0]], 3: [names[0], names[1]]]
		for (index, blocked) in blocks {
			try Self.talk(net, index).debugSetBlocked(blocked)
		}
		net.startAll()
		#expect(await net.run(until: { (0 ..< 4).allSatisfy { net.hops(0, $0) != nil || $0 == 0 } && net.hops(3, 0) != nil }, limit: .seconds(60)))
		await net.run(for: .seconds(20))
		#expect(net.devices.map { Set($0.talk!.debugSnapshot().neighbours.map(\.id)) } == [[net[1].id], [net[0].id, net[2].id], [net[1].id, net[3].id], [net[2].id]])
		#expect(net.hops(0, 3) == 3 && net.hops(3, 0) == 3 && net.hops(1, 3) == 2)
		#expect(try Self.talk(net, 0).debugSnapshot().blocked == [names[2], names[3]].sorted())
		#expect(try Self.talk(net, 0).debugSnapshot().reachable.count == 3)
		#expect(net.invitations(0, 3) == 0 && net.invitations(0, 2) == 0)

		for index in 0 ..< 4 {
			try Self.talk(net, index).debugSetBlocked([])
		}
		#expect(await net.run(until: { net.hops(0, 3) == 1 }, limit: .seconds(120)))
		#expect(net.contractViolations.isEmpty)
	}

	/// Blocking at run time drops the existing link and the device stays invisible (no reconnect);
	/// it is still reachable through others.
	@Test func blockAtRunTimeDropsLink() async throws {
		let net = SimNetwork(count: 3, seed: 73, talk: true, wrap: SimNetwork.relay)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { net.allConnected && net.hops(0, 2) == 1 }, limit: .seconds(30)))
		let a = try Self.talk(net, 0), c = try Self.talk(net, 2)
		a.debugSetBlocked([net[2].name])
		c.debugSetBlocked([net[0].name])
		#expect(await net.run(until: { net.hops(0, 2) == 2 }, limit: .seconds(30)))
		await net.run(for: .seconds(60))
		#expect(!net.isConnected(0, 2) && net.hops(0, 2) == 2 && net.allConnected)
		#expect(a.debugSnapshot().neighbours.map(\.id) == [net[1].id])
		#expect(a.peers.first { $0.id == net[2].id }?.state == .connected)	// via the relay
		a.debugSetBlocked([])
		c.debugSetBlocked([])
		#expect(await net.run(until: { net.hops(0, 2) == 1 }, limit: .seconds(120)))
		#expect(net.contractViolations.isEmpty)
	}

	/// `maxPeers` 2 (1 regular + 1 bridge): nobody holds more than 2 links, everybody still reaches
	/// everybody through relays, and the snapshot reports the split.
	@Test func linkCapHonoured() async throws {
		var config = SimConfig()
		config.maxPeers = 2
		config.step = .milliseconds(100)
		let net = SimNetwork(count: 6, seed: 74, config: config, talk: true, wrap: SimNetwork.relay)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(120)))
		for _ in 0 ..< 30 {
			await net.run(for: .seconds(1))
			#expect(net.maxLinks <= 2)
		}
		let snapshots = net.devices.map { $0.talk!.debugSnapshot() }
		for snapshot in snapshots {
			let slots = try #require(snapshot.slots)
			#expect(slots.regularCapacity == 1 && slots.bridgeCapacity == 1)
			#expect(slots.regular + slots.bridge <= 2 && snapshot.neighbours.count <= 2)
			#expect(snapshot.reachable.count == 5)
		}
		#expect(snapshots.contains { $0.reachable.contains { $0.hops > 1 } })
		#expect(net.capRefusals == 0 && net.contractViolations.isEmpty)
	}

	/// Dropping a direct link: the link layer reconnects; a device that is not a neighbour reports false.
	@Test func disconnectDirectLink() async throws {
		let net = SimNetwork(count: 3, seed: 75, talk: true, wrap: SimNetwork.relay)
		net.line()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(30)))
		let a = try Self.talk(net, 0)
		#expect(!a.debugDisconnect(net[2].id))	// relayed only
		#expect(!a.debugDisconnect(UUID()))
		#expect(a.debugDisconnect(net[1].id))
		#expect(await net.run(until: { !net.isConnected(0, 1) }, limit: .seconds(5)))
		#expect(await net.run(until: { net.allConnected && net.isConnected(0, 1) }, limit: .seconds(120)))
		#expect(net.contractViolations.isEmpty)
	}

	/// The creation options reach the link layer: cap 2 = 1 + 1, ephemeral identities are random and
	/// leave no trace in `UserDefaults`.
	@Test func debugOptions() throws {
		let appID = "de.werk01.debug-options-test"
		let options = TalkDebugOptions(linkCap: 2, ephemeralIdentity: true, blockedNames: ["x"])
		let a = Talk(serviceType: "bomtalk-test", appID: appID, displayName: "A", debug: options)
		let b = Talk(serviceType: "bomtalk-test", appID: appID, displayName: "A", debug: options)
		#expect(a.me.id != b.me.id)
		#expect(UserDefaults.standard.object(forKey: MPCIdentity.key(appID: appID)) == nil)
		let snapshot = a.debugSnapshot()
		#expect(snapshot.slots?.regularCapacity == 1 && snapshot.slots?.bridgeCapacity == 1)
		#expect(snapshot.blocked == ["x"] && !snapshot.isRunning && snapshot.me.name == "A")
		let capped = Talk(serviceType: "bomtalk-test", appID: appID, displayName: "A", debug: TalkDebugOptions(linkCap: 99))
		#expect(capped.debugSnapshot().slots?.total == 7)
		let plain = Talk(serviceType: "bomtalk-test", appID: appID, displayName: "A", debug: TalkDebugOptions())
		#expect(plain.debugSnapshot().slots?.total == 7)
		#expect(UserDefaults.standard.object(forKey: MPCIdentity.key(appID: appID)) != nil)	// the non-ephemeral one stores
		UserDefaults.standard.removeObject(forKey: MPCIdentity.key(appID: appID))
	}
}

private extension TalkDebugSnapshot.Slots {
	var total: Int { regularCapacity + bridgeCapacity }
}
