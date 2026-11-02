//
//  LinkPolicyTests.swift
//  BOMTalkTests
//

import Foundation
import Testing
@testable import BOMTalk

/// The relay's link policy (6 + 1) on the simulated radio network, on virtual time: bridges between
/// partitions, redundant drops with the unlink handshake, stability precautions, stalled links.
/// Every scenario checks the transport contract and the session cap (`capRefusals`), and the drop
/// timing rules (`checkDropTiming`).
@Suite(.serialized) @MainActor struct LinkPolicyTests {

	/// Long runs: timers still fire at their exact deadlines, only `run(until:)` checks less often.
	static var coarse: SimConfig {
		var config = SimConfig()
		config.step = .milliseconds(100)
		return config
	}

	/// 16 devices that all see each other: everyone reaches everyone, nobody ever holds more than
	/// 7 links, the radio never has to refuse a link.
	@Test func sixteenFullyVisible() async {
		let net = SimNetwork(count: 16, seed: 31, config: Self.coarse, wrap: SimNetwork.relay)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(30)))
		for _ in 0 ..< 60 {
			await net.run(for: .seconds(1))
			#expect(net.maxLinks <= MPCPolicy.maxRemotePeers)
		}
		#expect(net.allConnected)
		#expect(net.capRefusals == 0)
		net.checkDropTiming()
		#expect(net.contractViolations.isEmpty)
	}

	/// Two cliques of 8 that converged on their own, then see each other through two cross pairs of
	/// devices whose regular slots are all taken: they merge through bridge slots, and afterwards
	/// the bridge slots are freed by dropping redundant neighbours.
	@Test func twoCliquesMergeThroughBridges() async throws {
		let net = try await Self.mergedCliques(seed: 32)
		let counters = net.devices.map(\.relay.snapshot.counters)
		#expect(counters.map(\.bridgeConnects).reduce(0, +) >= 2)
		#expect(counters.map(\.voluntaryDrops).reduce(0, +) >= 1)
		#expect(counters.map(\.unlinksSent) == counters.map(\.voluntaryDrops))
		#expect(counters.map(\.unlinksReceived).reduce(0, +) == counters.map(\.unlinksSent).reduce(0, +))
		#expect(net.allConnected)
		// every bridge slot is free again: a cross link became regular, a clique link went
		#expect(net.devices.allSatisfy { $0.relay.snapshot.slots?.bridge == 0 })
		#expect(net.devices.allSatisfy { $0.relay.snapshot.flags.contains(.bridgeSlotFree) })
		#expect(net.maxLinks <= LinkSlots(maxPeers: MPCPolicy.maxRemotePeers).regular)
		#expect(net.capRefusals == 0)
		net.checkDropTiming()
		#expect(net.contractViolations.isEmpty)
	}

	/// After a deliberate drop, neither side invites the other while they reach each other via relay.
	@Test func unlinkSuppressesReinvites() async throws {
		let net = SimNetwork(count: 16, seed: 33, config: Self.coarse, wrap: SimNetwork.relay)
		try await Self.prepareCliques(net)
		var dropped: [(a: Int, b: Int, invitations: Int)] = []
		var seen = 0
		for _ in 0 ..< 240 {
			await net.run(for: .seconds(1))
			let drops = net.drops
			for drop in drops.dropFirst(seen) {
				dropped.append((drop.device, drop.neighbour, net.invitations(drop.device, drop.neighbour)))
			}
			seen = drops.count
		}
		try #require(!dropped.isEmpty)
		for pair in dropped {
			#expect(net.hops(pair.a, pair.b) ?? 0 > 1)	// reachable, not linked
			#expect(net.invitations(pair.a, pair.b) == pair.invitations)
			#expect(net[pair.a].relay.snapshot.suppressed.contains(net[pair.b].id))
			#expect(net[pair.b].relay.snapshot.suppressed.contains(net[pair.a].id))
		}
		#expect(net.allConnected)
		#expect(net.capRefusals == 0)
		#expect(net.contractViolations.isEmpty)
	}

	/// 30 devices that all see each other, 10 virtual minutes: everyone reaches everyone, and the
	/// links settle: no voluntary drop and no link change at all in the last 5 minutes.
	@Test func thirtyNoFlapping() async {
		let net = SimNetwork(count: 30, seed: 34, config: Self.coarse, wrap: SimNetwork.relay)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(30)))
		await net.run(for: .seconds(5 * 60) - net.now)
		let drops = net.totalCounters.voluntaryDrops, changes = net.linkChanges.count
		await net.run(for: .seconds(5 * 60))
		#expect(net.allConnected)
		#expect(net.totalCounters.voluntaryDrops == drops)
		#expect(net.linkChanges.count == changes)
		#expect(changes <= 4 * net.devices.count)
		#expect(net.maxLinks <= MPCPolicy.maxRemotePeers)
		#expect(net.capRefusals == 0)
		net.checkDropTiming()
		#expect(net.contractViolations.isEmpty)
	}

	/// 40 devices, each pair visible with probability 0.4: connected.
	@Test func fortyDenseRandom() async throws {
		let net = SimNetwork(count: 40, seed: 35, config: Self.coarse, wrap: SimNetwork.relay)
		net.random(probability: 0.4)
		try #require(net.isVisibilityConnected)
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(60)))
		await net.run(for: .seconds(60))
		#expect(net.allConnected)
		#expect(net.maxLinks <= MPCPolicy.maxRemotePeers)
		#expect(net.capRefusals == 0)
		net.checkDropTiming()
		#expect(net.contractViolations.isEmpty)
	}

	/// 20 devices, dense random visibility; for 5 minutes a random device vanishes or comes back
	/// about every 20 s. Then everyone is back and quiet: everyone reaches everyone within a minute,
	/// links settle within 3 more minutes, then nothing changes for the rest of the run.
	@Test func churnThenQuiet() async throws {
		let net = SimNetwork(count: 20, seed: 36, config: Self.coarse, wrap: SimNetwork.relay)
		net.random(probability: 0.6)
		try #require(net.isVisibilityConnected)
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(30)))
		var rng = SeededGenerator(seed: 36)
		var gone: Set<Int> = []
		let churnEnd = net.now + .seconds(5 * 60)
		while net.now < churnEnd {
			await net.run(for: .seconds(Double.random(in: 15 ... 25, using: &rng)))
			let index = Int.random(in: net.devices.indices, using: &rng)
			if gone.contains(index) {
				net.reappear(index)
				gone.remove(index)
			} else if gone.count < 3 {
				net.vanish(index)
				gone.insert(index)
			}
		}
		for index in gone.sorted() {
			net.reappear(index)
		}
		let quiet = net.now
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(60)))
		#expect(await net.run(until: { net.linkChanges.last.map { net.now - $0.at >= .seconds(60) } ?? true }, limit: .seconds(3 * 60)))
		let settled = net.now, changes = net.linkChanges.count, drops = net.totalCounters.voluntaryDrops
		await net.run(for: .seconds(3 * 60))
		#expect(net.linkChanges.count == changes)
		#expect(net.totalCounters.voluntaryDrops == drops)
		#expect(net.allConnected)
		#expect(settled - quiet <= .seconds(4 * 60))
		#expect(net.maxLinks <= MPCPolicy.maxRemotePeers)
		#expect(net.capRefusals == 0)
		net.checkDropTiming()
		#expect(net.contractViolations.isEmpty)
	}

	/// A device with every slot in use never drops a link that carries a long transfer: two cliques
	/// of 4 with cap 3 (2 + 1); one device receives over one of its links and sends over the other
	/// while its bridge forms. Both transfers complete before either link goes.
	@Test func busyLinkNotDropped() async throws {
		var config = SimConfig()
		config.maxPeers = 3
		config.bandwidth = 100_000
		let net = SimNetwork(count: 8, seed: 37, config: config, talk: true, wrap: SimNetwork.relay)
		net.fullMesh(Array(0 ..< 4))
		net.fullMesh(Array(4 ..< 8))
		net.startAll()
		#expect(await net.run(until: { (0 ..< 8).allSatisfy { net[$0].peers(.connected).count == 3 } }, limit: .seconds(30)))
		await net.run(for: RelayPolicy.minLinkAge)
		let a = try #require((0 ..< 4).first { net.sessionPeers($0).count == 2 })
		let b = try #require((4 ..< 8).first { net.sessionPeers($0).count == 2 })
		let neighbours = net.sessionPeers(a)
		try #require(neighbours.count == 2)
		let incoming = neighbours[0], outgoing = neighbours[1]
		let talkA = try #require(net[a].talk), talkIn = try #require(net[incoming].talk), talkOut = try #require(net[outgoing].talk)
		let inboxA = Inbox<Blob>(talkA), inboxOut = Inbox<Blob>(talkOut)
		let size = 3_000_000	// 30 s at 100 kB/s
		let peerA = try #require(talkIn.peer(talkA)), peerOut = try #require(talkA.peer(talkOut))
		var sent: [Result<Void, TalkError>] = []
		for (talk, peer) in [(talkIn, peerA), (talkA, peerOut)] {
			Task {
				do throws(TalkError) {
					try await talk.send(Blob(data: randomData(size)), to: peer)
					sent.append(.success(()))
				} catch {
					sent.append(.failure(error))
				}
			}
		}
		// encoding runs off the main actor in real time; virtual time passes meanwhile
		let flowing = { (talk: Talk) in (talk.transfers.first { $0.direction == .incoming }?.completedBytes ?? 0) > 0 }
		#expect(await net.run(until: { flowing(talkA) && flowing(talkOut) }, limit: .seconds(60)))
		let started = net.now
		net.see(a, b)
		#expect(await net.run(until: { net.isConnected(a, b) }, limit: .seconds(15)))
		#expect(net[a].relay.snapshot.slots?.bridge == 1)
		#expect(await net.run(until: { inboxA.results.count == 1 && inboxOut.results.count == 1 }, limit: .seconds(60)))
		let done = net.now
		#expect(done - started >= .seconds(25))
		#expect(inboxA.messages.count == 1 && inboxOut.messages.count == 1)
		let busy = [Set([a, incoming]), Set([a, outgoing])]
		#expect(!net.linkChanges.contains { !$0.up && $0.at < done && busy.contains(Set([$0.a, $0.b])) })
		// a received over `incoming` and sent over `outgoing` all along: neither picked while data
		// flowed (flow control keeps the sender's queue short, so it sends until the transfer ends)
		#expect(!net.drops.contains { $0.device == a && [incoming, outgoing].contains($0.neighbour) && $0.at < done - RelayPolicy.dataQuiet })
		await net.run(for: .seconds(60))
		#expect(net.allConnected)
		#expect(net.maxLinks <= 3)
		#expect(net.capRefusals == 0)
		net.checkDropTiming()
		#expect(net.contractViolations.isEmpty)
	}

	/// Link cap 2 (1 regular + 1 bridge): a line of 5 and a ring of 6 still connect everyone, as
	/// chains through relays.
	@Test(arguments: [false, true]) func smallCapChains(ring: Bool) async {
		var config = Self.coarse
		config.maxPeers = 2
		let net = SimNetwork(count: ring ? 6 : 5, seed: 38, config: config, wrap: SimNetwork.relay)
		ring ? net.ring() : net.line()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(60)))
		await net.run(for: .seconds(120))
		#expect(net.allConnected)
		#expect(net.maxLinks <= 2)
		#expect(net.capRefusals == 0)
		net.checkDropTiming()
		#expect(net.contractViolations.isEmpty)
	}

	/// A link that goes silent (blackholed session) is disconnected after `stalledDisconnect`, and
	/// its slot is used again by a fresh link.
	@Test func stalledLinkDisconnected() async {
		let net = SimNetwork(count: 4, seed: 39, wrap: SimNetwork.relay)
		net.ring()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(10)))
		await net.run(for: .seconds(5))
		net.blackhole(0, 1)
		let start = net.now
		#expect(await net.run(until: { !net.isConnected(0, 1) }, limit: RelayPolicy.stalledDisconnect + .seconds(2)))
		// silent since the last hello before the blackhole
		#expect(net.now - start >= RelayPolicy.stalledDisconnect - RelayPolicy.helloInterval * (1 + RelayPolicy.helloJitter))
		#expect((1 ... 2).contains(net[0].relay.snapshot.counters.stalledDisconnects + net[1].relay.snapshot.counters.stalledDisconnects))
		#expect(net.allConnected)	// around the ring meanwhile
		#expect(await net.run(until: { net.isConnected(0, 1) && net.hops(0, 1) == 1 }, limit: .seconds(10)))
		await net.run(for: .seconds(20))
		#expect(net.isConnected(0, 1))
		#expect(net.devices.allSatisfy { $0.relay.snapshot.counters.stalledDisconnects <= 1 })
		#expect(net.contractViolations.isEmpty)
	}

	/// Same seed, same bridges, drops and events.
	@Test func deterministic() async throws {
		func scenario() async throws -> ([String], [SimNetwork.LinkChange], [RelayCounters]) {
			let net = try await Self.mergedCliques(seed: 40)
			return (net.log, net.linkChanges, net.devices.map(\.relay.snapshot.counters))
		}
		let first = try await scenario(), second = try await scenario()
		#expect(first.0.count > 500)
		#expect(first.2.map(\.voluntaryDrops).reduce(0, +) > 0)
		#expect(first.0 == second.0)
		#expect(first.1 == second.1)
		#expect(first.2 == second.2)
	}

	// MARK: - Scenarios

	/// Two cliques of 8 converge on their own, then two pairs of full devices see each other.
	static func prepareCliques(_ net: SimNetwork) async throws {
		let first = Array(0 ..< 8), second = Array(8 ..< 16)
		net.fullMesh(first)
		net.fullMesh(second)
		net.startAll()
		let converged = { (group: [Int]) in group.allSatisfy { net[$0].peers(.connected).count == group.count - 1 } }
		#expect(await net.run(until: { converged(first) && converged(second) }, limit: .seconds(20)))
		await net.run(for: RelayPolicy.minLinkAge)
		let regular = LinkSlots(maxPeers: MPCPolicy.maxRemotePeers).regular
		let fullFirst = first.filter { net.sessionPeers($0).count == regular }
		let fullSecond = second.filter { net.sessionPeers($0).count == regular }
		try #require(fullFirst.count >= 2 && fullSecond.count >= 2)
		net.see(fullFirst[0], fullSecond[0])
		net.see(fullFirst[1], fullSecond[1])
	}

	/// `prepareCliques`, merged, then 2 minutes for the bridge slots to free up.
	static func mergedCliques(seed: UInt64) async throws -> SimNetwork {
		let net = SimNetwork(count: 16, seed: seed, config: coarse, wrap: SimNetwork.relay)
		try await prepareCliques(net)
		let joined = net.now
		#expect(await net.run(until: { net.allConnected }, limit: RelayPolicy.bridgeDelay * 2 + .seconds(10)))
		#expect(net.now - joined >= RelayPolicy.bridgeDelay * (1 - RelayPolicy.decisionJitter))	// grace
		await net.run(for: .seconds(120))
		return net
	}
}

// MARK: - Helpers

extension SimNetwork {

	struct DropRecord {
		let device: Int
		let neighbour: Int
		let at: Duration
		let linkAge: Duration?
	}

	/// Voluntary drops of all devices, as recorded in their snapshots, by time.
	var drops: [DropRecord] {
		devices.flatMap { device in
			device.relay.snapshot.linkActions.filter { $0.kind == .drop }.compactMap { action in
				index(of: action.neighbour).map { DropRecord(device: device.index, neighbour: $0, at: action.at, linkAge: action.linkAge) }
			}
		}.sorted { ($0.at, $0.device) < ($1.at, $1.device) }
	}

	var totalCounters: RelayCounters {
		devices.map(\.relay.snapshot.counters).reduce(into: RelayCounters()) { total, counters in
			total.voluntaryDrops += counters.voluntaryDrops
			total.stalledDisconnects += counters.stalledDisconnects
			total.bridgeConnects += counters.bridgeConnects
			total.unlinksSent += counters.unlinksSent
			total.unlinksReceived += counters.unlinksReceived
		}
	}

	/// Session links of the busiest device.
	var maxLinks: Int {
		devices.indices.map { sessionPeers($0).count }.max() ?? 0
	}

	/// Minimum link age and drop rate limit, per device.
	func checkDropTiming() {
		let drops = self.drops
		for drop in drops {
			#expect((drop.linkAge ?? .zero) >= RelayPolicy.minLinkAge)
		}
		for device in devices.indices {
			let times = drops.filter { $0.device == device }.map(\.at)
			for (earlier, later) in zip(times, times.dropFirst()) {
				#expect(later - earlier >= RelayPolicy.dropInterval)
			}
		}
	}
}
