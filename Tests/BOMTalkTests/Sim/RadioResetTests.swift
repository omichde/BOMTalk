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

	/// Cut off from devices it sees: a live link no longer blocks the reset once attempts with two of
	/// them hung, at once on the smaller side, otherwise after `isolationLimit`. Failures with other
	/// peers don't count, and data on the old link clears nothing meanwhile.
	@Test func wedgedApartWhileLinked() {
		var health = RadioHealth()
		var now = Duration.zero
		let mate = UUID()
		_ = health.observe(.connected(TransportPeer(id: mate, name: "", info: [:])), at: now)
		now += RadioResetPolicy.healthyLinkAge
		func attempt(_ id: UUID) {
			_ = health.observe(.connecting(id), at: now)
			now += RadioResetPolicy.slowFailure
			_ = health.observe(.disconnected(id), at: now)
			_ = health.observe(.received(Data([1]), from: mate), at: now)	// the old link works all along
		}
		health.observe(LinkPolicy(bridgeCandidates: [Self.peerA, Self.peerB], outnumbered: false), at: now)
		let isolated = now
		attempt(Self.peerA)
		attempt(UUID())	// not a candidate
		attempt(Self.peerB)
		#expect(!health.shouldReset(at: now, peersVisible: true))	// not a candidate: two failures only
		attempt(Self.peerA)
		#expect(!health.shouldReset(at: now, peersVisible: true))	// the larger side waits
		health.observe(LinkPolicy(bridgeCandidates: [Self.peerA, Self.peerB], outnumbered: true), at: now)
		#expect(health.shouldReset(at: now, peersVisible: true))
		health.observe(LinkPolicy(bridgeCandidates: [Self.peerA, Self.peerB], outnumbered: false), at: now)
		#expect(!health.shouldReset(at: now, peersVisible: true))
		while now - isolated < RadioResetPolicy.isolationLimit {
			attempt(Self.peerB)
			attempt(Self.peerA)
			#expect(health.shouldReset(at: now, peersVisible: true) == (now - isolated >= RadioResetPolicy.isolationLimit))
		}
		health.observe(LinkPolicy(), at: now)	// merged
		#expect(!health.shouldReset(at: now, peersVisible: true))
		_ = health.observe(.received(Data([1]), from: mate), at: now)	// a success again: history cleared
		health.observe(LinkPolicy(bridgeCandidates: [Self.peerA, Self.peerB], outnumbered: true), at: now)
		#expect(!health.shouldReset(at: now, peersVisible: true))
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

	/// The rig's heal run at cap 2 (third round): the busiest relay went dark, and the pair that
	/// reached the others only through it was left with wedged sessions, still linked to each other.
	/// Every accepted attempt between the pair and the others hung (declines still came back), the
	/// working link kept both from resetting, and the pair never rejoined. Here: a line of outsiders,
	/// the relay, then the group; the group's sessions wedge, everyone sees everyone, the relay goes
	/// dark for 25 s. Without the reset while linked the group never rejoins (150 s limit, all cases).
	/// With it the outnumbered group resets, member by member (an interior member at cap 2 has no
	/// free slot to fail with, it follows once its links went), and everyone reaches everyone within
	/// the rig's 150 s; the outsiders never reset. A group of 4 at cap 2 is not the smaller side
	/// (4 against 3 during the dark, then a tie): it resets only after `isolationLimit`, and the
	/// outsiders, outnumbered during the dark, may reset in vain meanwhile; still within 5 minutes.
	/// Afterwards nothing resets or flaps.
	@Test(arguments: [(2, 2, 90), (2, 2, 91), (2, 3, 92), (3, 2, 93), (3, 3, 94), (2, 4, 95)] as [(Int, Int, UInt64)])
	func isolatedGroupRejoins(cap: Int, group size: Int, seed: UInt64) async throws {
		var config = LinkPolicyTests.coarse
		config.maxPeers = cap
		config.wedgeAnswersDeclines = true
		let net = SimNetwork(count: 8, seed: seed, config: config, wrap: SimNetwork.relay)
		let relay = 7 - size, group = Array(relay + 1 ..< 8), outsiders = Array(0 ..< relay)
		let smaller = size < outsiders.count
		net.line()	// outsiders …, relay, group …
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(90)))
		await net.run(for: .seconds(30))
		try #require(net.isConnected(relay, group[0]))
		for index in group {
			net.wedge(index)
		}
		net.fullMesh()
		await net.run(for: .seconds(30))
		try #require(net.allConnected)
		net.vanish(relay)
		await net.run(for: .seconds(25))
		#expect(Set(group.flatMap { net[$0].relay.snapshot.reachable.compactMap { net.index(of: $0.id) } }) == Set(group))
		net.reappear(relay)
		let bound: Duration = smaller ? .seconds(150) : .seconds(300)	// after the restart
		#expect(await net.run(until: { net.allConnected }, limit: bound))
		#expect(net.wedged.isEmpty)
		#expect(group.allSatisfy { net[$0].link.radioResets >= 1 })
		if smaller {
			#expect(outsiders.allSatisfy { net[$0].link.radioResets == 0 })
		}
		#expect(net[relay].link.radioResets == 0)
		let resets = net.totalCounters.radioResets, changes = net.linkChanges.count
		await net.run(for: .seconds(120))
		#expect(net.allConnected)
		#expect(net.totalCounters.radioResets == resets)
		#expect(net.linkChanges.count - changes <= 4)	// at most a drop and its replacement or two
		#expect(net.maxLinks <= cap)
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
