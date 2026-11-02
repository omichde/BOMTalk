//
//  RadioResetTests.swift
//  BOMTalkTests
//

import Foundation
import Testing
@testable import BOMTalk

/// Wedged sessions (RELAY-PLAN.md, "Findings from simulator rig runs", second round): a device
/// whose attempts with everyone hang recovers by resetting its radio (`RadioHealth`), and healthy
/// networks never reset.
@Suite(.serialized) @MainActor struct RadioResetTests {

	static let peerA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
	static let peerB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

	// MARK: - RadioHealth

	/// Watchdog expiries with two peers: the third one asks for a reset, quick declines never do.
	@Test func slowFailuresWithTwoPeers() {
		var health = RadioHealth()
		var now = Duration.zero
		func attempt(_ id: UUID, lasting duration: Duration) -> Bool {
			_ = health.observe(.connecting(id), at: now)
			now += duration
			return health.observe(.disconnected(id), at: now)
		}
		for _ in 0 ..< 10 {
			#expect(!attempt(Self.peerA, lasting: .seconds(1)))	// declined: the radio works
		}
		#expect(!health.shouldReset(at: now, peersVisible: true))
		#expect(attempt(Self.peerA, lasting: MPCPolicy.watchdogDelay))
		#expect(attempt(Self.peerA, lasting: MPCPolicy.watchdogDelay))
		#expect(!health.shouldReset(at: now, peersVisible: true))	// one peer only
		#expect(attempt(Self.peerB, lasting: MPCPolicy.watchdogDelay))
		#expect(health.shouldReset(at: now, peersVisible: true))
		#expect(!health.shouldReset(at: now, peersVisible: false))
		#expect(!health.shouldReset(at: now + RadioResetPolicy.window, peersVisible: true))	// too old
	}

	/// Links dying young count, data on an old one clears everything; no reset while a link lives.
	@Test func youngLinkDeathsAndSuccess() {
		var health = RadioHealth()
		var now = Duration.zero
		func youngLink(_ id: UUID) -> Bool {
			_ = health.observe(.connecting(id), at: now)
			_ = health.observe(.connected(TransportPeer(id: id, name: "", info: [:])), at: now)
			_ = health.observe(.received(Data([1]), from: id), at: now + .seconds(1))	// a burst, then silence
			now += .seconds(20)
			return health.observe(.disconnected(id), at: now)
		}
		#expect(youngLink(Self.peerA))
		#expect(youngLink(Self.peerB))
		// a healthy link: alive, so no reset
		let peerC = UUID()
		_ = health.observe(.connected(TransportPeer(id: peerC, name: "", info: [:])), at: now)
		#expect(youngLink(Self.peerA))
		_ = health.observe(.received(Data([1]), from: peerC), at: now)
		#expect(!health.shouldReset(at: now, peersVisible: true))
		#expect(health.shouldReset(at: now + RadioResetPolicy.liveness, peersVisible: true))	// silent: not alive
		now += RadioResetPolicy.healthyLinkAge
		_ = health.observe(.received(Data([1]), from: peerC), at: now)	// success
		_ = health.observe(.disconnected(peerC), at: now + .seconds(1))	// an old link: not a failure
		now += RadioResetPolicy.liveness + .seconds(1)
		#expect(!health.shouldReset(at: now, peersVisible: true))
		#expect(youngLink(Self.peerA))
		#expect(!health.shouldReset(at: now, peersVisible: true))	// history cleared by the success
	}

	/// Consecutive resets back off: 60 s, 120 s, …; a success resets the backoff.
	@Test func resetsBackOff() {
		var health = RadioHealth()
		var now = Duration.zero
		func failThrice() {
			for id in [Self.peerA, Self.peerB, Self.peerA] {
				_ = health.observe(.connecting(id), at: now)
				now += RadioResetPolicy.slowFailure
				_ = health.observe(.disconnected(id), at: now)
			}
		}
		failThrice()
		#expect(health.shouldReset(at: now, peersVisible: true))
		health.didReset(at: now)
		let first = now
		failThrice()
		#expect(now - first < .seconds(60) && !health.shouldReset(at: now, peersVisible: true))
		now = first + .seconds(60)
		failThrice()
		#expect(health.shouldReset(at: now, peersVisible: true))
		health.didReset(at: now)
		let second = now
		now += .seconds(70)
		failThrice()
		#expect(now - second < .seconds(120) && !health.shouldReset(at: now, peersVisible: true))
		now = second + .seconds(120)
		failThrice()
		#expect(health.shouldReset(at: now, peersVisible: true))
		#expect(RadioResetPolicy.backoff(resetsInRow: 9) == .seconds(300))
		#expect(health.resets == 2)
	}

	// MARK: - Simulated network

	/// 8 devices that all see each other, one of them with a wedged session from the start: every
	/// invitation from or to it hangs. It resets its radio once its attempts with two peers hung and
	/// joins; nobody else resets. Without the reset it never joins.
	@Test(arguments: [70, 71, 72] as [UInt64]) func wedgedDeviceRecovers(seed: UInt64) async {
		let net = SimNetwork(count: 8, seed: seed, config: LinkPolicyTests.coarse, wrap: SimNetwork.relay)
		net.fullMesh()
		net.wedge(3)
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(60)))
		#expect(net.now <= MPCPolicy.watchdogDelay * 2 + .seconds(10))
		#expect(net[3].link.radioResets == 1)
		#expect(net.devices.filter { $0.index != 3 }.allSatisfy { $0.link.radioResets == 0 })
		#expect(net.hungInvitations > 0)
		await net.run(for: .seconds(60))
		#expect(net.allConnected)
		#expect(net.totalCounters.radioResets == 1)
		#expect(net.capRefusals == 0)
		#expect(net.contractViolations.isEmpty)
	}

	/// The rig's heal scenario at cap 2: device 0's neighbours go dark, and the abrupt loss wedges its
	/// session (`wedgeOnAbruptLoss`). Isolated, with every attempt hanging, it resets its radio and
	/// everyone reaches everyone again within two minutes of the restart. Without the reset device 0
	/// stays alone.
	@Test(arguments: [80, 81, 82] as [UInt64]) func isolatedEndWedgesAtCapTwo(seed: UInt64) async throws {
		var config = LinkPolicyTests.coarse
		config.maxPeers = 2
		config.wedgeOnAbruptLoss = [0]
		let net = SimNetwork(count: 8, seed: seed, config: config, wrap: SimNetwork.relay)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(60)))
		await net.run(for: .seconds(30))
		let neighbours = net[0].relay.snapshot.neighbours.compactMap { net.index(of: $0) }
		try #require(!neighbours.isEmpty)
		for index in neighbours {
			net.vanish(index)
		}
		await net.run(for: .seconds(1))
		#expect(net.wedged == [0])
		await net.run(for: .seconds(20))
		for index in neighbours {
			net.reappear(index)
		}
		let restarted = net.now
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(120)))
		#expect(net.now - restarted <= .seconds(120))
		#expect(net[0].link.radioResets >= 1)
		#expect(net.wedged.isEmpty)
		await net.run(for: .seconds(60))
		#expect(net.allConnected)
		#expect(net.devices.filter { $0.index != 0 }.allSatisfy { $0.link.radioResets == 0 })
		#expect(net.maxLinks <= 2)
		#expect(net.capRefusals == 0)
		#expect(net.contractViolations.isEmpty)
	}

	/// A bare link transport (no relay) reports every peer gone on a reset and finds them again.
	@Test func bareTransportKeepsContract() async {
		let net = SimNetwork(count: 4, seed: 73)
		net.fullMesh()
		net.wedge(0)
		net.startAll()
		#expect(await net.run(until: { net[0].peers(.connected) == [1, 2, 3] }, limit: .seconds(60)))
		#expect(net[0].link.radioResets == 1)
		#expect(net.contractViolations.isEmpty)
	}
}
