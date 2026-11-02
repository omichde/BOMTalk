//
//  RestartTests.swift
//  BOMTalkTests
//

import Foundation
import Testing
@testable import BOMTalk

/// Failure modes found in simulator rig runs (RELAY-PLAN.md, "Findings from simulator rig runs"):
/// devices that stop and start again ("dark") while MPC on their former neighbours still holds the
/// old session, invitations that hang, half-open links, small link caps.
@Suite(.serialized) @MainActor struct RestartTests {

	/// MPC as seen in the rig: losses noticed late, stale sessions for a restarted peer id, some
	/// invitations hanging, some links half open.
	static func rigLike(maxPeers: Int, freshHandles: Bool) -> SimConfig {
		var config = SimConfig()
		config.step = .milliseconds(100)
		config.maxPeers = maxPeers
		config.freshHandles = freshHandles
		config.lossDetection = .seconds(45)
		config.staleSession = .seconds(120)
		config.hangProbability = 0.05
		config.halfOpenProbability = 0.05
		return config
	}

	/// The failure modes themselves, on bare link transports: a device restarts while its peer has
	/// not noticed the loss yet (`lossDetection`). With one handle for all runs the peer's stale session
	/// makes every invitation between them hang until `staleSession` passes; with a fresh handle the
	/// restarted device is a new peer on the radio and connects at once, replacing the dead link.
	@Test(arguments: [true, false]) func restartWithStaleSession(freshHandles: Bool) async {
		var config = SimConfig()
		config.freshHandles = freshHandles
		config.lossDetection = .seconds(30)
		config.staleSession = .seconds(60)
		let net = SimNetwork(count: 2, seed: 51, config: config)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { net[0].peers(.connected) == [1] && net[1].peers(.connected) == [0] }, limit: .seconds(10)))
		let handle = net[1].radio.localHandle
		net.vanish(1)
		await net.run(for: .seconds(1))
		#expect(net[0].peers(.connected) == [1])	// not noticed yet
		#expect(throws: Never.self) { try net[0].link.send(Data([1]), to: net[1].id) }	// goes nowhere
		net.reappear(1)
		#expect(net[1].radio.localHandle == (freshHandles ? SimHandle(index: 1, run: 2) : handle))
		let restarted = net.now
		let linked = { net[0].peers(.connected) == [1] && net[1].peers(.connected) == [0] && net.isConnected(0, 1) }
		if freshHandles {
			#expect(await net.run(until: linked, limit: .seconds(10)))
			#expect(net.hungInvitations == 0)
		} else {
			await net.run(for: .seconds(50))
			#expect(net[1].peers(.connected).isEmpty)
			#expect(net.hungInvitations > 0)
			#expect(await net.run(until: linked, limit: .seconds(60)))
			#expect(net.now - restarted >= .seconds(59))
		}
		#expect(net.contractViolations.isEmpty)
	}

	/// A half-open link holds the invitee's slot until the relay finds it silent; the link comes back.
	@Test func halfOpenLinkRecovers() async {
		var config = SimConfig()
		config.halfOpenProbability = 1
		let net = SimNetwork(count: 2, seed: 52, config: config, wrap: SimNetwork.relay)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { net.halfOpenLinks > 0 }, limit: .seconds(10)))
		await net.run(for: .seconds(1))
		#expect(net.devices.count { $0.relay.snapshot.neighbours.isEmpty } == 1)	// only the invitee has it
		net.config.halfOpenProbability = 0
		#expect(await net.run(until: { net.allConnected }, limit: RelayPolicy.stalledDisconnect + MPCPolicy.watchdogDelay + .seconds(40)))
		#expect(net.totalCounters.stalledDisconnects <= 1)
		#expect(net.contractViolations.isEmpty)
	}

	/// The rig's soak at cap 3: 8 devices that all see each other, a random one goes dark for 20 s
	/// every 60 s, for 10 virtual minutes. After the last dark everyone reaches everyone within 60 s;
	/// at no time does a running device stay without any neighbour for more than 30 s, or have all its
	/// slots held by pending attempts for more than 10 s. Both with a fresh handle per start (`MPCRadio`)
	/// and with one handle for all runs (stale sessions on the remotes after every restart).
	@Test(arguments: [true, false], [50, 52, 53] as [UInt64]) func darkEveryMinuteAtCapThree(freshHandles: Bool, seed: UInt64) async {
		let net = SimNetwork(count: 8, seed: seed, config: Self.rigLike(maxPeers: 3, freshHandles: freshHandles), wrap: SimNetwork.relay)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(60)))
		var rng = SeededGenerator(seed: seed)
		var monitor = Monitor()
		func observe(_ seconds: Int) async {
			for _ in 0 ..< seconds {
				await net.run(for: .seconds(1))
				monitor.observe(net)
			}
		}
		for round in 0 ..< 10 {
			await observe(round == 0 ? 60 : 40)
			let index = Int.random(in: 0 ..< 8, using: &rng)
			net.vanish(index)
			await observe(20)
			net.reappear(index)
		}
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(60)))
		await observe(30)
		#expect(net.allConnected)
		#expect(monitor.worstIsolated <= .seconds(30))
		#expect(monitor.worstStarved <= .seconds(10))
		#expect(!net.devices.contains { $0.isStarved })
		#expect(net.totalCounters.radioResets == 0)	// hanging attempts, but never with every peer
		#expect(net.maxLinks <= 3)
		#expect(net.capRefusals == 0)
		#expect(net.contractViolations.isEmpty)
	}

	/// Cap 2 (1 + 1), 8 devices that all see each other, with fresh handles but 30 % of the invitations
	/// hanging until the watchdog and 10 % of the links half open: everyone reaches everyone within a
	/// minute and stays so; no device goes without a neighbour for more than 30 s or starves for more
	/// than 10 s. (Before the fixes: up to 3 minutes without a neighbour, 75 s starving.)
	@Test(arguments: [60, 61, 62] as [UInt64]) func hangingInvitationsAtCapTwo(seed: UInt64) async {
		var config = Self.rigLike(maxPeers: 2, freshHandles: true)
		config.hangProbability = 0.3
		config.halfOpenProbability = 0.1
		let net = SimNetwork(count: 8, seed: seed, config: config, wrap: SimNetwork.relay)
		net.fullMesh()
		net.startAll()
		var monitor = Monitor()
		var converged: Duration?
		for _ in 0 ..< 180 {
			await net.run(for: .seconds(1))
			monitor.observe(net)
			if converged == nil, net.allConnected {
				converged = net.now
			}
		}
		#expect(converged.map { $0 <= .seconds(60) } ?? false)
		#expect(net.allConnected)
		#expect(monitor.worstIsolated <= .seconds(30))
		#expect(monitor.worstStarved <= .seconds(10))
		#expect(net.maxLinks <= 2)
		#expect(net.capRefusals == 0)
		#expect(net.contractViolations.isEmpty)
	}
}

/// How long running devices go without any neighbour, or with every slot held by pending attempts.
@MainActor struct Monitor {
	private var isolated: [Int: Duration] = [:]
	private var starved: [Int: Duration] = [:]
	private(set) var worstIsolated = Duration.zero
	private(set) var worstStarved = Duration.zero

	/// Call once per virtual second.
	mutating func observe(_ net: SimNetwork) {
		for device in net.devices {
			let running = device.radio.isRunning
			isolated[device.index] = running && device.relay.snapshot.neighbours.isEmpty ? (isolated[device.index] ?? .zero) + .seconds(1) : .zero
			starved[device.index] = running && device.isStarved ? (starved[device.index] ?? .zero) + .seconds(1) : .zero
			worstIsolated = max(worstIsolated, isolated[device.index] ?? .zero)
			worstStarved = max(worstStarved, starved[device.index] ?? .zero)
		}
	}
}

extension SimDevice {

	/// Every slot is in use, but not a single link is up: all held by pending attempts.
	var isStarved: Bool {
		guard let slots = relay.snapshot.slots else { return false }
		return slots.regular + slots.bridge >= slots.capacity.total && relay.snapshot.neighbours.isEmpty
	}
}
