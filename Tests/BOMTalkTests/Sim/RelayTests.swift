//
//  RelayTests.swift
//  BOMTalkTests
//

import Foundation
import Testing
@testable import BOMTalk

/// `RelayTransport` on the simulated radio network, on virtual time. Every scenario checks the
/// transport contract (`SimNetwork.contractViolations`, also recorded as issues).
@Suite @MainActor struct RelayTests {

	// MARK: - Wire

	@Test func envelopeRoundTrip() throws {
		let envelope = RelayEnvelope(kind: .data, hopLimit: 8, origin: UUID(), destination: UUID(), payload: Data([1, 2, 3]))
		let encoded = envelope.encoded()
		#expect(encoded.count == RelayEnvelope.headerSize + 3)
		#expect(RelayEnvelope(encoded) == envelope)
		#expect(RelayEnvelope(encoded)?.forwarded().hopLimit == 7)
		#expect(RelayEnvelope(Data(encoded.prefix(RelayEnvelope.headerSize - 1))) == nil)
		var badVersion = encoded
		badVersion[2] = 99
		#expect(RelayEnvelope(badVersion) == nil)
		#expect(RelayEnvelope(Frame.accept(UUID()).encoded()) == nil)	// a bare Talk frame
	}

	@Test func helloRoundTrip() throws {
		let record = RelayHello.Record(name: "Lobby iPad", info: ["role": "kiosk"])
		let full = RelayHello(version: .init(epoch: 1_700_000_000_000, seq: 42), neighbours: [UUID(), UUID()], flags: .bridgeSlotFree, interval: .seconds(4.2), infoVersion: 7, record: record)
		#expect(RelayHello(full.encoded()) == full)
		#expect(RelayHello.hasRecord(full.encoded()))
		let short = full.with(record: nil)
		#expect(RelayHello(short.encoded()) == short)
		#expect(!RelayHello.hasRecord(short.encoded()))
		#expect(short.encoded().count == 8 + 8 + 1 + 1 + 4 + 1 + 2 * 16)
		#expect(short.with(record: record) == full)
		#expect(full.recordKey == RelayHello.RecordKey(epoch: 1_700_000_000_000, infoVersion: 7))
		#expect(RelayHello(Data(full.encoded().prefix(20))) == nil)
		#expect(RelayHello(short.encoded() + Data([0])) == nil)	// trailing bytes without a record
		// whole 100 ms, 0.1 … 25.5 s
		#expect(RelayHello(version: .init(epoch: 1, seq: 1), neighbours: [], interval: .milliseconds(3_049), infoVersion: 1).interval == .milliseconds(3_000))
		#expect(RelayHello(version: .init(epoch: 1, seq: 1), neighbours: [], interval: .seconds(60), infoVersion: 1).interval == .milliseconds(25_500))
		// restart: a new epoch wins over any seq of the old one
		#expect(RelayHello.Version(epoch: 1, seq: 999) < RelayHello.Version(epoch: 2, seq: 1))
		#expect(RelayHello.Version(epoch: 2, seq: 1) < RelayHello.Version(epoch: 2, seq: 2))
	}

	@Test func helloIntervalScales() {
		#expect(RelayPolicy.helloInterval(devices: 1) == .seconds(3))
		#expect(RelayPolicy.helloInterval(devices: 30) == .seconds(3))
		#expect(RelayPolicy.helloInterval(devices: 50) == .seconds(5))
		#expect(RelayPolicy.helloInterval(devices: 100) == .seconds(10))
		#expect(RelayPolicy.helloInterval(devices: 500) == .seconds(15))
		#expect(RelayPolicy.expiry(interval: .seconds(3)) == RelayPolicy.helloExpiry)
		#expect(RelayPolicy.expiry(interval: .seconds(15)) == .seconds(50))
		// more than 2.75 intervals even with full jitter
		for interval in [Duration.seconds(3), .seconds(5), .seconds(15)] {
			#expect(RelayPolicy.expiry(interval: interval) >= interval * (1 + RelayPolicy.helloJitter) * 2.75)
		}
	}

	@Test func protocolVersionFiltersDiscoveryAndInvitations() {
		let uuid = UUID()
		let info = DiscoveryInfo.encode(appID: "app", protocolVersion: 1, uuid: uuid, info: ["role": "kiosk"])
		#expect(info[DiscoveryInfo.versionKey] == "\(BOMTalkProtocol.version):1")
		#expect(info.keys.sorted() == ["_a", "_u", "_v", "role"])
		#expect(DiscoveryInfo.decode(info, appID: "app", protocolVersion: 1)?.id == uuid)
		#expect(DiscoveryInfo.decode(info, appID: "app", protocolVersion: 1)?.info == ["role": "kiosk"])
		#expect(DiscoveryInfo.decode(info, appID: "app", protocolVersion: 2) == nil)
		#expect(DiscoveryInfo.decode(info, appID: "app", protocolVersion: 1, bomtalkVersion: BOMTalkProtocol.version + 1) == nil)
		var swapped = info	// app version 3 of BOMTalk 1 is not BOMTalk 3 of app version 1
		swapped[DiscoveryInfo.versionKey] = "1:\(BOMTalkProtocol.version)"
		#expect(DiscoveryInfo.decode(swapped, appID: "app", protocolVersion: 1) == nil)

		let context = InvitationContext(appID: "app", appVersion: 1, uuid: uuid).encoded()
		#expect(InvitationContext.decode(context, appID: "app", protocolVersion: 1) == uuid)
		#expect(InvitationContext.decode(context, appID: "app", protocolVersion: 2) == nil)
		#expect(InvitationContext.decode(context, appID: "other", protocolVersion: 1) == nil)
		#expect(InvitationContext.decode(context, appID: "app", protocolVersion: 1, bomtalkVersion: BOMTalkProtocol.version + 1) == nil)
	}

	/// v2 (branch `master`) advertises `_a`, `_v` = bare app version, `_u`, and invites with
	/// `{"appID", "version", "uuid"}`: this build ignores both. v2's own checks, copied literally
	/// below, ignore this build's discovery info and decline its invitations.
	@Test func v2AndV3IgnoreEachOther() {
		let uuid = UUID()
		// as v2's `DiscoveryInfo.encode` / `InvitationContext.encoded` produce them
		let v2Info = ["_a": "app", "_v": "1", "_u": uuid.uuidString, "role": "kiosk"]
		let v2Context = Data(#"{"appID":"app","version":1,"uuid":"\#(uuid.uuidString)"}"#.utf8)
		#expect(DiscoveryInfo.decode(v2Info, appID: "app", protocolVersion: 1) == nil)
		#expect(InvitationContext.decode(v2Context, appID: "app", protocolVersion: 1) == nil)

		// v2's decode rules
		func v2Decode(_ info: [String: String]?, appID: String, protocolVersion: Int) -> (id: UUID, info: [String: String])? {
			guard let info,
				info["_a"] == appID,
				info["_v"] == String(protocolVersion),
				let id = info["_u"].flatMap(UUID.init(uuidString:))
			else { return nil }
			return (id, info.filter { !["_a", "_v", "_u"].contains($0.key) })
		}
		struct V2InvitationContext: Codable {
			let appID: String
			let version: Int
			let uuid: UUID

			static func decode(_ data: Data?, appID: String, protocolVersion: Int) -> UUID? {
				guard let data,
					let context = try? JSONDecoder().decode(V2InvitationContext.self, from: data),
					context.appID == appID,
					context.version == protocolVersion
				else { return nil }
				return context.uuid
			}
		}
		// the copies accept v2's own formats …
		#expect(v2Decode(v2Info, appID: "app", protocolVersion: 1)?.id == uuid)
		#expect(V2InvitationContext.decode(v2Context, appID: "app", protocolVersion: 1) == uuid)
		// … but not this build's, whatever app version v2 runs
		let v3Info = DiscoveryInfo.encode(appID: "app", protocolVersion: 1, uuid: uuid, info: ["role": "kiosk"])
		let v3Context = InvitationContext(appID: "app", appVersion: 1, uuid: uuid).encoded()
		for version in [1, 3, BOMTalkProtocol.version] {
			#expect(v2Decode(v3Info, appID: "app", protocolVersion: version) == nil)
			#expect(V2InvitationContext.decode(v3Context, appID: "app", protocolVersion: version) == nil)
		}
	}

	/// The reserved keys leave the documented ~300 bytes of the 400 byte TXT record for host info.
	@Test func discoveryInfoBudget() throws {
		let appID = "de.werk01.exhibition"
		let reserved = DiscoveryInfo.encode(appID: appID, protocolVersion: 12, uuid: UUID(), info: [:])
		let reservedBytes = DiscoveryInfo.totalBytes(reserved)
		#expect(reservedBytes == (1 + 3 + appID.utf8.count) + (1 + 3 + 4) + (1 + 3 + 36))
		let budget = DiscoveryInfo.maxTotalBytes - reservedBytes
		#expect(budget >= 300)
		// two pairs (at most 255 bytes each) filling the budget exactly: length byte, "k=", value
		let first = String(repeating: "x", count: 200)
		let fits = ["k": first, "l": String(repeating: "x", count: budget - (3 + 200) - 3)]
		#expect(DiscoveryInfo.encode(appID: appID, protocolVersion: 12, uuid: UUID(), info: fits).count == 5)
		let tooLarge = ["k": first, "l": String(repeating: "x", count: budget - (3 + 200) - 2)]
		#expect(DiscoveryInfo.encode(appID: appID, protocolVersion: 12, uuid: UUID(), info: tooLarge).count == 3)
	}

	// MARK: - Scenarios

	/// Line 0 – 1 – 2 – 3 – 4: everyone reaches everyone with the right hop counts; a message and a
	/// 1 MB blob (16 chunks) cross 4 hops.
	@Test func lineOfFive() async throws {
		var config = SimConfig()
		config.bandwidth = 2_000_000
		let net = SimNetwork(count: 5, seed: 11, config: config, talk: true, wrap: SimNetwork.relay)
		net.line()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(10)))
		for a in net.devices.indices {
			for b in net.devices.indices where b != a {
				#expect(net.hops(a, b) == abs(a - b))
			}
		}

		let a = try #require(net[0].talk), e = try #require(net[4].talk)
		let chats = Inbox<Chat>(e)
		let peer = try #require(a.peer(e))
		#expect(peer.state == .connected && peer.name == "d4")
		let sending = Task { try await a.send(Chat(text: "over 4 hops"), to: peer) }
		#expect(await net.run(until: { chats.messages.count == 1 }, limit: .seconds(5)))
		try await net.value(of: sending)
		#expect(try chats.results[0].get().peer.id == a.me.id)

		let blobs = Inbox<Blob>(e)
		let blob = Blob(data: randomData(1024 * 1024))
		let blobSending = Task { try await a.send(blob, to: peer) }
		var progress: Set<Int> = []
		#expect(await net.run(until: {
			if let incoming = e.transfers.first {
				progress.insert(incoming.completedBytes)
			}
			return blobs.results.count == 1
		}, limit: .seconds(60)))	// includes encoding in real time
		try await net.value(of: blobSending)
		#expect(blobs.messages == [blob])
		#expect(progress.count >= 3)	// observed in between, not just at 0 and done
		#expect(net[2].relay.snapshot.counters.dataForwarded >= 16)
		#expect(net.contractViolations.isEmpty)
	}

	/// `Talk.send(_:)` in a line of 6 reaches every device exactly once; a device without a subscriber
	/// answers `.notWanted` across 3 hops.
	@Test func broadcastLineOfSix() async throws {
		let net = SimNetwork(count: 6, seed: 12, talk: true, wrap: SimNetwork.relay)
		net.line()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(10)))
		let sender = try #require(net[0].talk)
		var inboxes: [Int: Inbox<Chat>] = [:]
		for index in [1, 2, 4, 5] {
			inboxes[index] = Inbox<Chat>(try #require(net[index].talk))
		}
		var results: [Peer.ID: Result<Void, TalkError>]?
		Task { results = await sender.send(Chat(text: "all")) }
		#expect(await net.run(until: { results != nil }, limit: .seconds(10)))
		await net.run(for: .seconds(5))	// nothing arrives twice
		let all = try #require(results)
		#expect(all.count == 5)
		for index in 1 ..< 6 {
			let result = try #require(all[net[index].id])
			if index == 3 {
				#expect(throws: TalkError.notWanted) { try result.get() }
			} else {
				#expect(throws: Never.self) { try result.get() }
				#expect(inboxes[index]?.messages == [Chat(text: "all")])
			}
		}
		#expect(net.contractViolations.isEmpty)
	}

	/// Ring of 10, one link drops: the long way round (9 hops) keeps everyone connected, nobody sees
	/// a `disconnected` or `lost`.
	@Test func ringSurvivesLinkDrop() async {
		let net = SimNetwork(count: 10, seed: 13, wrap: SimNetwork.relay)
		net.ring()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(15)))
		await net.run(for: .seconds(5))
		let mark = net.log.count
		net.drop(0, 1)
		await net.settle()
		#expect(net.hops(0, 1) == 9)	// rerouted at once
		await net.run(for: .seconds(30))
		let after = net.log[mark...]
		#expect(!after.contains { $0.contains(" disconnected ") || $0.contains(" lost ") })
		#expect(net.allConnected)
		#expect(net.hops(0, 1) == 1)	// link back after backoff
		#expect(net.contractViolations.isEmpty)
	}

	/// Line of 5, the middle device vanishes: each half sees the other half `disconnected`, then
	/// `lost` once the map entries expire. Back with a new epoch (seq starting over), it reconnects.
	@Test func lineSplitsAndRejoins() async {
		let net = SimNetwork(count: 5, seed: 14, wrap: SimNetwork.relay)
		net.line()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(10)))
		await net.run(for: .seconds(5))
		let left = [0, 1], right = [3, 4]
		net.vanish(2)
		let vanished = net.now
		let slack: Duration = .seconds(2)
		let split = {
			left.allSatisfy { a in right.allSatisfy { b in net[a].peers[net[b].id]?.state != .connected && net[b].peers[net[a].id]?.state != .connected } }
		}
		#expect(await net.run(until: split, limit: RelayPolicy.helloExpiry + slack))
		let gone = {
			(left + right).allSatisfy { a in (left.contains(a) ? right : left).allSatisfy { b in net[a].peers[net[b].id] == nil } && net[a].peers[net[2].id] == nil }
		}
		#expect(await net.run(until: gone, limit: RelayPolicy.helloExpiry + RelayPolicy.sweepInterval + slack))
		// lost only on expiry, at most one hello interval after the last hello before the vanish
		#expect(net.now - vanished >= RelayPolicy.helloExpiry - RelayPolicy.minHelloInterval * (1 + RelayPolicy.helloJitter))
		#expect(net[0].peers(.connected) == [1] && net[1].peers(.connected) == [0])
		#expect(net[3].peers(.connected) == [4] && net[4].peers(.connected) == [3])
		#expect(net.log.contains { $0.hasSuffix("d0 disconnected d4") })
		#expect(net.log.contains { $0.hasSuffix("d0 lost d4") })

		net.reappear(2)
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(10)))
		#expect(net.hops(0, 4) == 4)
		#expect(net.contractViolations.isEmpty)
	}

	/// 30 devices, sparse random visibility (degree ≤ 7, connected, diameter ≤ hop limit).
	@Test func randomSparseConverges() async throws {
		let net = SimNetwork(count: 30, seed: 15, wrap: SimNetwork.relay)
		net.randomConnected(maxDegree: 5, extraEdges: 20)
		try #require(net.isVisibilityConnected)
		try #require(net.devices.indices.allSatisfy { net.degree($0) <= MPCPolicy.maxRemotePeers })
		try #require(net.diameter <= Int(RelayPolicy.hopLimit))
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(20)))
		await net.run(for: .seconds(5))
		// routes are shortest paths, once all links are up and in the map
		for a in [0, 7, 29] {
			for b in net.devices.indices where b != a {
				#expect(net.hops(a, b) == net.distance(a, b))
			}
		}
		#expect(net.contractViolations.isEmpty)
	}

	/// A relay link stalls mid-transfer: both ends fail with `.timeout` once the chunk timeout passes
	/// without progress (the sender no longer reports success for data the receiver never got), and
	/// once the link counts as dead, traffic takes the other way round the ring.
	@Test func blackholeMidTransfer() async throws {
		var config = SimConfig()
		config.bandwidth = 1_000_000
		config.chunkTimeout = .seconds(1)
		let net = SimNetwork(count: 6, seed: 16, config: config, talk: true, wrap: SimNetwork.relay)
		net.ring()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(10)))
		let a = try #require(net[0].talk), d = try #require(net[3].talk)
		let blobs = Inbox<Blob>(d)
		let peer = try #require(a.peer(d))
		var sent: Result<Void, TalkError>?
		Task {
			do throws(TalkError) {
				try await a.send(Blob(data: randomData(1024 * 1024)), to: peer)
				sent = .success(())
			} catch {
				sent = .failure(error)
			}
		}
		// encoding runs off the main actor in real time, virtual time passes meanwhile
		#expect(await net.run(until: { (d.transfers.first?.completedBytes ?? 0) > 0 }, limit: .seconds(60)))
		let first = try #require(net.route(0, 3))
		net.blackhole(0, first)
		let blackholed = net.now

		// within the window at most half the blob passed the link: no progress, both ends time out
		#expect(await net.run(until: { sent != nil && !blobs.results.isEmpty }, limit: .seconds(5)))
		#expect(net.now - blackholed <= config.chunkTimeout + .milliseconds(500))
		#expect(sent.map { if case .failure(.timeout) = $0 { true } else { false } } == true)
		#expect(blobs.errors == [.timeout])
		#expect(a.transfers.isEmpty && d.transfers.isEmpty)

		// silent for `helloExpiry`: routed around; for `stalledDisconnect`: replaced by a fresh link
		await net.run(for: RelayPolicy.helloExpiry + .seconds(2))
		let second = try #require(net.route(0, 3))
		#expect(second != first || net[0].relay.snapshot.counters.stalledDisconnects == 1)
		let chats = Inbox<Chat>(d)
		let sending = Task { try await a.send(Chat(text: "around"), to: try #require(a.peer(d))) }
		#expect(await net.run(until: { chats.messages.count == 1 }, limit: .seconds(5)))
		try await net.value(of: sending)
		#expect(net.contractViolations.isEmpty)
	}

	/// Hellos travel at most `hopLimit` hops, data frames die at the limit or without a route, and
	/// nothing keeps circulating once traffic stops.
	@Test func hopLimit() async throws {
		let limit = Int(RelayPolicy.hopLimit), last = limit + 1
		let net = SimNetwork(count: limit + 2, seed: 17, wrap: SimNetwork.relay)
		net.line()
		net.startAll()
		#expect(await net.run(until: { net[0].peers(.connected) == Array(1 ... limit) && net[last].peers(.connected) == Array(1 ... limit) }, limit: .seconds(20)))
		await net.run(for: .seconds(5))
		#expect(net.hops(0, limit) == limit)
		#expect(net[0].peers[net[last].id] == nil)	// one hop too far: never heard of
		#expect(throws: TalkError.notConnected) { try net[0].transport.send(Data([1]), to: net[last].id) }

		// injected from 4's lower link into 5
		let exhausted = RelayEnvelope(kind: .data, hopLimit: 1, origin: net[4].id, destination: net[last].id, payload: Data([1]))
		let nowhere = RelayEnvelope(kind: .data, hopLimit: 8, origin: net[4].id, destination: UUID(), payload: Data([2]))
		try net[4].link.send(exhausted.encoded(), to: net[5].id)
		try net[4].link.send(nowhere.encoded(), to: net[5].id)
		try net[4].link.send(Data("garbage".utf8), to: net[5].id)
		await net.run(for: .seconds(1))
		let counters = net[5].relay.snapshot.counters
		#expect(counters[.hopLimit] == 1)
		#expect(counters[.noRoute] == 1)
		#expect(counters[.malformed] == 1)

		// quiet network: data counters freeze, hellos only at their periodic rate, timers bounded
		let before = net.devices.map(\.relay.snapshot.counters)
		let window: Duration = .seconds(20)
		await net.run(for: window)
		let after = net.devices.map(\.relay.snapshot.counters)
		let hellosPerOrigin = Int(window / (RelayPolicy.minHelloInterval * (1 - RelayPolicy.helloJitter))) + 1
		for (old, new) in zip(before, after) {
			#expect(new.dataForwarded == old.dataForwarded)
			#expect(new.drops == old.drops)
			#expect(new.hellosForwarded - old.hellosForwarded <= net.devices.count * hellosPerOrigin * 2)
		}
		#expect(net.timers.pendingCount <= net.devices.count * 8)
		#expect(net.contractViolations.isEmpty)
	}

	/// Data overtaking its origin's hello is held and delivered in order right after `connected`;
	/// beyond the limits or too old, it is dropped and counted.
	@Test func unknownOriginBuffer() async throws {
		let net = SimNetwork(count: 3, seed: 18, wrap: SimNetwork.relay)
		net.line()	// 0 – 1 – 2, 2 starts later
		net[0].start()
		net[1].start()
		#expect(await net.run(until: { net[0].peers(.connected) == [1] }, limit: .seconds(5)))
		for byte: UInt8 in 1 ... 3 {
			let envelope = RelayEnvelope(kind: .data, hopLimit: 7, origin: net[2].id, destination: net[0].id, payload: Data([byte]))
			try net[1].link.send(envelope.encoded(), to: net[0].id)
		}
		await net.run(for: .milliseconds(100))
		#expect(net[0].relay.snapshot.bufferedFrames == 3)
		#expect(!net.log.contains { $0.contains("d0 received") })

		net[2].start()
		#expect(await net.run(until: { net[0].peers(.connected) == [1, 2] }, limit: .seconds(RelayPolicy.bufferMaxAge.components.seconds - 1)))
		let events = net[0].events.compactMap { event -> String? in
			switch event {
			case let .connected(peer) where peer.id == net[2].id: "connected"
			case let .received(data, from) where from == net[2].id: "\(data.first ?? 0)"
			default: nil
			}
		}
		#expect(events.prefix(4) == ["connected", "1", "2", "3"])
		#expect(net[0].relay.snapshot.bufferedFrames == 0)

		// a stranger that never says hello
		let stranger = UUID()
		for _ in 0 ..< RelayPolicy.bufferMaxFrames + 6 {
			let envelope = RelayEnvelope(kind: .data, hopLimit: 7, origin: stranger, destination: net[0].id, payload: Data([0]))
			try net[1].link.send(envelope.encoded(), to: net[0].id)
		}
		await net.run(for: .milliseconds(100))
		#expect(net[0].relay.snapshot.counters[.bufferOverflow] == 6)
		#expect(net[0].relay.snapshot.bufferedFrames == RelayPolicy.bufferMaxFrames)
		await net.run(for: RelayPolicy.bufferMaxAge + RelayPolicy.sweepInterval)
		#expect(net[0].relay.snapshot.counters[.bufferTimeout] == RelayPolicy.bufferMaxFrames)
		#expect(net[0].relay.snapshot.bufferedFrames == 0)
		#expect(net.contractViolations.isEmpty)
	}

	@Test func deterministic() async {
		func scenario() async -> ([String], [RelayCounters]) {
			let net = SimNetwork(count: 15, seed: 19, wrap: SimNetwork.relay)
			net.randomConnected(maxDegree: 4, extraEdges: 6)
			net.startAll()
			await net.run(for: .seconds(15))
			net.drop(0, net.sessionPeers(0).first ?? 1)
			net.vanish(3)
			await net.run(for: .seconds(15))
			net.reappear(3)
			await net.run(for: .seconds(20))
			return (net.log, net.devices.map(\.relay.snapshot.counters))
		}
		let first = await scenario(), second = await scenario()
		#expect(first.0.count > 500)
		#expect(first.0 == second.0)
		#expect(first.1 == second.1)
	}

	/// Devices of another BOMTalk version or app version are never listed, and list nobody.
	@Test(arguments: [false, true]) func mixedVersions(appVersion: Bool) async {
		var config = SimConfig()
		if appVersion {
			config.appVersions = [4: 2]
		} else {
			config.bomtalkVersions = [4: BOMTalkProtocol.version + 1]
		}
		let net = SimNetwork(count: 5, seed: 20, config: config, wrap: SimNetwork.relay)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { (0 ..< 4).allSatisfy { a in net[a].peers(.connected) == (0 ..< 4).filter { $0 != a } } }, limit: .seconds(10)))
		await net.run(for: .seconds(20))
		#expect(!net.log.contains { $0.contains("d4") })
		#expect(net[4].peers.isEmpty)
		#expect(net.sessionPeers(4).isEmpty)
		#expect(net.invitations(4, 0) == 0)
		#expect(net.contractViolations.isEmpty)
	}
}

// MARK: - Helpers

extension SimDevice {
	var relay: RelayTransport { transport as! RelayTransport }
}

extension SimNetwork {

	/// Everyone reports everyone else connected.
	var allConnected: Bool {
		devices.allSatisfy { $0.peers(.connected).count == devices.count - 1 }
	}

	/// Hop count of `a`'s route to `b`, nil without a route.
	func hops(_ a: Int, _ b: Int) -> Int? {
		self[a].relay.snapshot.reachable.first { $0.id == self[b].id }?.hops
	}

	/// Index of `a`'s next hop towards `b`.
	func route(_ a: Int, _ b: Int) -> Int? {
		self[a].relay.snapshot.reachable.first { $0.id == self[b].id }.flatMap { index(of: $0.nextHop) }
	}

	/// Shortest path length over visible pairs, nil if unreachable.
	func distance(_ a: Int, _ b: Int) -> Int? {
		distances(from: a)[b]
	}

	/// Shortest path lengths from `a` to every device it reaches over visible pairs.
	func distances(from a: Int) -> [Int: Int] {
		var distances = [a: 0], queue = [a], next = 0
		while next < queue.count {
			let x = queue[next]
			next += 1
			for y in devices.indices where distances[y] == nil && isVisible(x, y) {
				distances[y] = (distances[x] ?? 0) + 1
				queue.append(y)
			}
		}
		return distances
	}

	var diameter: Int {
		devices.indices.map { a in
			let distances = distances(from: a)
			return distances.count == devices.count ? distances.values.max() ?? 0 : .max
		}.max() ?? 0
	}
}
