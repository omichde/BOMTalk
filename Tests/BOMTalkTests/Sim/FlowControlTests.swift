//
//  FlowControlTests.swift
//  BOMTalkTests
//

import Foundation
import Testing
@testable import BOMTalk

/// End-to-end flow control (`FlowControl`): acks, the sender window, the stall timeout and final ack
/// probes, on the scheduler alone and on the simulated network (virtual time, bandwidth-limited
/// links with one FIFO queue per direction).
@Suite @MainActor struct FlowControlTests {

	static let chunk = Frame.maxChunkPayload

	// MARK: - Scheduler

	/// The window holds 8 chunks; acks from another peer, for another transfer, beyond what was sent
	/// or going backwards change nothing; the stall timeout counts from the last ack progress.
	@Test func schedulerWindowAndAcks() async throws {
		let timers = ManualTimers()
		var sent: [Data] = []
		let scheduler = Scheduler(timers: timers, timeout: .seconds(5)) { data, _ throws(TalkError) in sent.append(data) }
		let peer = UUID(), id = UUID()
		let transfer = Transfer(id: id, peer: peer, kind: "blob", direction: .outgoing, totalBytes: 20 * Self.chunk)
		var result: Finished?
		Task {
			do throws(TalkError) {
				try await scheduler.transmit(Data(count: 20 * Self.chunk), to: transfer)
				result = .success
			} catch {
				result = .failure(error)
			}
		}
		func spin() async {
			for _ in 0 ..< 50 {
				await Task.yield()
			}
		}
		func acknowledge(_ chunks: Int, from sender: UUID? = nil, transfer: UUID? = nil) async {
			scheduler.acknowledge(transfer ?? id, receivedBytes: UInt64(chunks * Self.chunk), from: sender ?? peer)
			await spin()
		}
		await spin()
		#expect(sent.count == FlowControl.window / Self.chunk)
		await acknowledge(4, from: UUID())
		await acknowledge(4, transfer: UUID())
		await acknowledge(9)	// more than sent
		#expect(sent.count == 8 && transfer.completedBytes == 0)
		await acknowledge(4)
		#expect(sent.count == 12 && transfer.completedBytes == 4 * Self.chunk)
		await acknowledge(2)	// backwards
		#expect(sent.count == 12 && transfer.completedBytes == 4 * Self.chunk)

		timers.advance(by: .seconds(4))
		await acknowledge(8)
		#expect(sent.count == 16)
		timers.advance(by: .seconds(4))	// 8 s since the start, 4 s since the last progress
		await spin()
		#expect(result == nil)
		timers.advance(by: .seconds(1))
		await spin()
		#expect(result == .failure(.timeout))
		#expect(Frame(try #require(sent.last)).map { if case .chunk(_, 15, _) = $0 { true } else { false } } == true)
	}

	/// Success only with the final ack; an empty payload completes with an ack of 0 bytes.
	@Test func schedulerCompletesOnFinalAck() async {
		let timers = ManualTimers()
		var sent = 0
		let scheduler = Scheduler(timers: timers, timeout: .seconds(5)) { _, _ throws(TalkError) in sent += 1 }
		let peer = UUID()
		for size in [0, 3 * Self.chunk - 1] {
			let transfer = Transfer(id: UUID(), peer: peer, kind: "blob", direction: .outgoing, totalBytes: size)
			var done = false
			Task {
				try? await scheduler.transmit(Data(count: size), to: transfer)
				done = true
			}
			for _ in 0 ..< 50 {
				await Task.yield()
			}
			#expect(!done)
			scheduler.acknowledge(transfer.id, receivedBytes: UInt64(size), from: peer)
			for _ in 0 ..< 10 {
				await Task.yield()
			}
			#expect(done && transfer.completedBytes == size)
		}
		#expect(sent == 1 + 3)
	}

	/// Several transfers to one peer share `peerWindow`: together never more unacknowledged bytes than
	/// that, whatever their number; a transfer to another peer has its own budget. Acks free room for
	/// the others in turn, and all complete.
	@Test func schedulerPeerWindowAcrossTransfers() async throws {
		let timers = ManualTimers()
		var sent: [UUID: Int] = [:]	// chunks per peer
		let scheduler = Scheduler(timers: timers, timeout: .seconds(30)) { _, peer throws(TalkError) in sent[peer, default: 0] += 1 }
		let peer = UUID(), other = UUID()
		let cap = FlowControl.peerWindow / Self.chunk
		func spin() async {
			for _ in 0 ..< 50 {
				await Task.yield()
			}
		}
		var transfers: [Transfer] = []
		var results: [Finished?] = []
		for target in [peer, peer, peer, peer, other] {
			let transfer = Transfer(id: UUID(), peer: target, kind: "blob", direction: .outgoing, totalBytes: 12 * Self.chunk)
			let index = results.count
			transfers.append(transfer)
			results.append(nil)
			Task {
				do throws(TalkError) {
					try await scheduler.transmit(Data(count: 12 * Self.chunk), to: transfer)
					results[index] = .success
				} catch {
					results[index] = .failure(error)
				}
			}
		}
		await spin()
		#expect(sent[peer] == cap)	// 4 windows of 8 would be 32
		#expect(sent[other] == FlowControl.window / Self.chunk)
		#expect(scheduler.unacknowledgedBytes(for: peer) == FlowControl.peerWindow)
		#expect(scheduler.unacknowledgedBytes(for: other) == FlowControl.window)

		// the receiver acknowledges whatever was sent, step by step: the cap holds at every point
		var peakPeer = 0
		var acknowledged = [Int](repeating: 0, count: transfers.count)
		for _ in 0 ..< 200 where results.contains(where: { $0 == nil }) {
			for (index, transfer) in transfers.enumerated() where results[index] == nil {
				acknowledged[index] = min(acknowledged[index] + 2 * Self.chunk, 12 * Self.chunk)
				scheduler.acknowledge(transfer.id, receivedBytes: UInt64(acknowledged[index]), from: transfer.peer)
				await spin()
				peakPeer = max(peakPeer, scheduler.unacknowledgedBytes(for: peer))
			}
		}
		#expect(peakPeer <= FlowControl.peerWindow)
		#expect(results.allSatisfy { $0 == .success })
		#expect(sent[peer] == 4 * 12 && sent[other] == 12)
	}

	/// Concurrent blobs to one peer over a slow link all complete without timeouts, and relay hellos
	/// keep flowing meanwhile (nobody expires from anybody's map): 1 MB queue = 5 s on the link.
	@Test func manyConcurrentTransfersOverSlowLink() async throws {
		var config = SimConfig()
		config.bandwidth = 200_000	// slow link: 6 windows of 512 KB would queue 15 s
		config.chunkTimeout = .seconds(30)
		let net = SimNetwork(count: 3, seed: 58, config: config, talk: true, wrap: SimNetwork.relay)
		net.line()
		net.startAll()
		let a = try #require(net[0].talk), c = try #require(net[2].talk)
		#expect(await net.run(until: { a.connectedCount == 2 && c.connectedCount == 2 }, limit: .seconds(60)))
		let inbox = Inbox<Blob>(c)
		let peerC = try #require(a.peer(c))
		let sends = (0 ..< 6).map { _ in Self.send(Blob(data: randomData(512 * 1024)), from: a, to: peerC) }
		#expect(await net.run(until: { sends.allSatisfy { $0.result != nil } }, limit: .seconds(120)))
		#expect(sends.allSatisfy { $0.result == .success })
		#expect(await net.run(until: { inbox.messages.count == 6 }))
		#expect(net.devices.allSatisfy { $0.relay.snapshot.counters.entriesExpired == 0 })
		#expect(net.contractViolations.isEmpty)
	}

	// MARK: - Simulated network

	/// Each link direction is one FIFO: a small frame waits behind a large one sent before it, the
	/// other direction is not affected.
	@Test func bandwidthIsLinkFIFO() async throws {
		var config = SimConfig()
		config.bandwidth = 100_000
		let net = SimNetwork(count: 2, seed: 50, config: config)
		net.fullMesh()
		net.startAll()
		#expect(await net.run(until: { net[0].peers(.connected) == [1] && net[1].peers(.connected) == [0] }))
		let start = SimNetwork.milliseconds(net.now)
		try net[0].transport.send(Data(count: 50_000), to: net[1].id)
		try net[0].transport.send(Data(count: 10), to: net[1].id)
		try net[1].transport.send(Data(count: 20), to: net[0].id)
		await net.run(for: .seconds(1))
		func arrival(_ line: String) throws -> Int64 {
			let entry = try #require(net.log.first { $0.hasSuffix(line) })
			return try #require(Int64(entry.prefix { $0 != " " })) - start
		}
		let large = try arrival("d1 received 50000 d0"), small = try arrival("d1 received 10 d0"), back = try arrival("d0 received 20 d1")
		#expect(large >= 500 && small >= large)	// 50 kB at 100 kB/s, then the small one
		#expect(back < 50)
	}

	/// The audit scenario: a 20 MB transfer along a line of 5 relays with 1 MB/s links (20 s of data,
	/// twice the hello expiry). With flow control it completes, nobody sees a `disconnected` or `lost`,
	/// no map entry expires, and small messages between other pairs get through meanwhile.
	@Test func largeTransferAlongLine() async throws {
		let outcome = try await Self.lineTransfer(window: FlowControl.window)
		#expect(outcome.received == .success)
		#expect(outcome.sent == .success)
		#expect(outcome.peerLosses == [])
		#expect(outcome.entriesExpired == 0)
		#expect(outcome.chatsSent > 5 && outcome.chatsDelivered == outcome.chatsSent)
		#expect(outcome.maxChatDelay < .seconds(2))
		#expect(outcome.duration >= .seconds(20) && outcome.duration < .seconds(30))
	}

	/// The same scenario without flow control (window unlimited): the sender queues all 20 MB on its
	/// first link at once, its hellos wait behind them, the far devices expire its entry and report it
	/// `disconnected`, and the receiver fails the transfer.
	@Test func largeTransferAlongLineWithoutFlowControl() async throws {
		let outcome = try await Self.lineTransfer(window: .max)
		#expect(outcome.received == .failure(.peerDisconnected))
		#expect(outcome.sent != .success)
		#expect(!outcome.peerLosses.isEmpty)
		#expect(outcome.entriesExpired > 0)
	}

	/// A stalled link to the receiver: the sender fails with `.timeout` once acks stop for the chunk
	/// timeout (before flow control it reported success, the data having been handed off).
	@Test func blackholedReceiverTimesOut() async throws {
		var config = SimConfig()
		config.bandwidth = 1_000_000
		config.chunkTimeout = .seconds(5)
		let net = SimNetwork(count: 2, seed: 51, config: config, talk: true)
		net.fullMesh()
		net.startAll()
		let a = try #require(net[0].talk), b = try #require(net[1].talk)
		#expect(await net.run(until: { a.connectedCount == 1 && b.connectedCount == 1 }))
		let blobs = Inbox<Blob>(b)
		let sending = Self.send(Blob(data: randomData(4 * 1024 * 1024)), from: a, to: try #require(a.peer(b)))
		#expect(await net.run(until: { (b.transfers.first?.completedBytes ?? 0) > 0 }, limit: .seconds(60)))
		net.blackhole(0, 1)
		let stalled = net.now
		#expect(await net.run(until: { sending.result != nil && !blobs.results.isEmpty }, limit: .seconds(10)))
		let elapsed = net.now - stalled
		#expect(elapsed <= config.chunkTimeout + .milliseconds(500))
		#expect(elapsed >= config.chunkTimeout - .seconds(1))
		#expect(sending.result == .failure(.timeout))
		#expect(blobs.errors == [.timeout])
		#expect(a.transfers.isEmpty && b.transfers.isEmpty)
	}

	/// Lost acks with a full window: the receiver repeats its ack while no chunk arrives, the transfer
	/// recovers.
	@Test func lostAcksRecover() async throws {
		var config = SimConfig()
		config.bandwidth = 1_000_000
		let net = SimNetwork(count: 3, seed: 52, config: config, talk: true, wrap: SimNetwork.relay)
		net.line()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(10)))
		var lost = 0
		net.loses = { data, from, _ in
			guard from == 2, lost < 3, case .ack = SimNetwork.talkFrame(data) else { return false }
			lost += 1
			return true
		}
		let a = try #require(net[0].talk), c = try #require(net[2].talk)
		let blobs = Inbox<Blob>(c)
		let blob = Blob(data: randomData(2 * 1024 * 1024))
		let sending = Task { try await a.send(blob, to: try #require(a.peer(c))) }
		try await net.value(of: sending, limit: .seconds(60))
		#expect(lost == 3)
		#expect(await net.run(until: { blobs.results.count == 1 }, limit: .seconds(1)))
		#expect(blobs.messages == [blob])
	}

	/// The final ack is lost: the sender probes with the last chunk, the receiver acknowledges the
	/// completed transfer again, `send` succeeds instead of timing out.
	@Test func lostFinalAckProbed() async throws {
		let net = SimNetwork(count: 2, seed: 53, talk: true)
		net.fullMesh()
		net.startAll()
		let a = try #require(net[0].talk), b = try #require(net[1].talk)
		#expect(await net.run(until: { a.connectedCount == 1 && b.connectedCount == 1 }))
		let chats = Inbox<Chat>(b)
		var lost = 0
		net.loses = { data, from, _ in
			guard from == 1, lost == 0, case .ack = SimNetwork.talkFrame(data) else { return false }
			lost += 1
			return true
		}
		let sending = Self.send(Chat(text: "ack me"), from: a, to: try #require(a.peer(b)))
		#expect(await net.run(until: { chats.messages.count == 1 }))
		let delivered = net.now
		#expect(await net.run(until: { sending.result != nil }, limit: .seconds(20)))
		#expect(sending.result == .success)
		#expect(lost == 1)
		#expect(net.now - delivered >= FlowControl.finalAckProbe - .milliseconds(100))
		#expect(chats.results.count == 1)	// the probe is not delivered twice
	}

	/// A link on the route drops mid-transfer (chunks and acks on it are lost, traffic reroutes round
	/// the ring): no deadlock, both ends finish within the chunk timeout, and they agree.
	@Test func routeChangeMidTransfer() async throws {
		var config = SimConfig()
		config.bandwidth = 1_000_000
		config.chunkTimeout = .seconds(5)
		let net = SimNetwork(count: 6, seed: 54, config: config, talk: true, wrap: SimNetwork.relay)
		net.ring()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(10)))
		let a = try #require(net[0].talk), d = try #require(net[3].talk)
		let blobs = Inbox<Blob>(d)
		let sending = Self.send(Blob(data: randomData(3 * 1024 * 1024)), from: a, to: try #require(a.peer(d)))
		#expect(await net.run(until: { (d.transfers.first?.completedBytes ?? 0) > 1024 * 1024 }, limit: .seconds(60)))
		let first = try #require(net.route(0, 3))
		net.drop(0, first)
		let dropped = net.now
		#expect(await net.run(until: { sending.result != nil && !blobs.results.isEmpty }, limit: .seconds(30)))
		// the last progress may be a repeated ack over the new route, up to two repeat intervals later
		#expect(net.now - dropped <= config.chunkTimeout + FlowControl.ackRepeat * 2 + .seconds(1))
		switch try #require(blobs.results.first) {
		case .success:
			#expect(sending.result == .success)
		case let .failure(error):
			#expect(error == .timeout)
			#expect(sending.result == .failure(.timeout))
		}
		#expect(a.peer(d)?.state == .connected)
		#expect(net.contractViolations.isEmpty)
	}

	/// Two transfers to the same peer and one to another start together: the two to the same peer
	/// share its link evenly (round-robin, one window each); a stalled peer with a full window does
	/// not hold up a transfer to another.
	@Test func concurrentTransfersFairAndIndependent() async throws {
		var config = SimConfig()
		config.bandwidth = 1_000_000
		config.chunkTimeout = .seconds(20)
		let net = SimNetwork(count: 3, seed: 55, config: config, talk: true)
		net.fullMesh()
		net.startAll()
		let a = try #require(net[0].talk), b = try #require(net[1].talk), c = try #require(net[2].talk)
		#expect(await net.run(until: { a.connectedCount == 2 }))
		let blobsB = Inbox<Blob>(b), blobsC = Inbox<Blob>(c)
		let peerB = try #require(a.peer(b)), peerC = try #require(a.peer(c))
		let size = 2 * 1024 * 1024
		let sends = [Self.send(Blob(data: randomData(size)), from: a, to: peerB), Self.send(Blob(data: randomData(size)), from: a, to: peerB), Self.send(Blob(data: randomData(size)), from: a, to: peerC)]
		var finished: [Int: Duration] = [:]
		#expect(await net.run(until: {
			for (index, send) in sends.enumerated() where send.result != nil && finished[index] == nil {
				finished[index] = net.now
			}
			return finished.count == 3
		}, limit: .seconds(60)))
		#expect(sends.allSatisfy { $0.result == .success })
		#expect(await net.run(until: { blobsB.messages.count == 2 && blobsC.messages.count == 1 }))	// decoding in real time
		let first = try #require(finished[0]), second = try #require(finished[1]), other = try #require(finished[2])
		// 4 MB over a–b take 4 s, interleaved both end near the end; a–c runs in parallel (2 s)
		#expect(abs(SimNetwork.milliseconds(first - second)) < 500)
		#expect(other < min(first, second))

		// a–c stalls with its window full: the transfer to b completes meanwhile, then c's times out
		let stalled = Self.send(Blob(data: randomData(size)), from: a, to: peerC)
		#expect(await net.run(until: { (c.transfers.first?.completedBytes ?? 0) > 0 }, limit: .seconds(60)))
		net.blackhole(0, 2)
		let unaffected = Self.send(Blob(data: randomData(size)), from: a, to: peerB)
		#expect(await net.run(until: { unaffected.result != nil }, limit: .seconds(60)))
		#expect(unaffected.result == .success && stalled.result == nil)
		#expect(await net.run(until: { stalled.result != nil }, limit: config.chunkTimeout + .seconds(1)))
		#expect(stalled.result == .failure(.timeout))
	}

	/// A broadcast blob to 5 peers: one window per peer, all complete; with one peer stalled the
	/// other 4 still complete and only that one times out.
	@Test func broadcastBlob() async throws {
		var config = SimConfig()
		config.bandwidth = 1_000_000
		config.chunkTimeout = .seconds(5)
		let net = SimNetwork(count: 6, seed: 56, config: config, talk: true)
		net.fullMesh()
		net.startAll()
		let sender = try #require(net[0].talk)
		#expect(await net.run(until: { sender.connectedCount == 5 }))
		let inboxes = try (1 ..< 6).map { Inbox<Blob>(try #require(net[$0].talk)) }
		let blob = Blob(data: randomData(1024 * 1024))
		var results: [Peer.ID: Finished]?
		var concurrent = 0
		Task { results = await sender.send(blob).mapValues(Finished.init) }
		#expect(await net.run(until: {
			concurrent = max(concurrent, sender.transfers.count { $0.direction == .outgoing && $0.completedBytes > 0 })
			return results != nil
		}, limit: .seconds(60)))
		#expect(concurrent == 5)
		#expect(try #require(results).values.allSatisfy { $0 == .success })
		#expect(await net.run(until: { inboxes.allSatisfy { $0.messages == [blob] } }))	// decoding in real time

		results = nil
		let stalled = try #require(net[5].talk)
		Task { results = await sender.send(blob).mapValues(Finished.init) }
		#expect(await net.run(until: { (stalled.transfers.first?.completedBytes ?? 0) > 0 }, limit: .seconds(60)))
		net.blackhole(0, 5)
		#expect(await net.run(until: { results != nil }, limit: .seconds(10)))
		let second = try #require(results)
		#expect(second[net[5].id] == .failure(.timeout))
		#expect((1 ..< 5).allSatisfy { second[net[$0].id] == .success })
		#expect(await net.run(until: { inboxes.prefix(4).allSatisfy { $0.messages.count == 2 } }))
	}

	// MARK: - Scenario

	struct LineOutcome {
		var received: Finished?
		var sent: Finished?
		/// `disconnected` / `lost` events of any device during the transfer, `"d<i> -> d<j>"`.
		var peerLosses: [String] = []
		var entriesExpired = 0
		var chatsSent = 0
		var chatsDelivered = 0
		var maxChatDelay: Duration = .zero
		/// From the first received byte to the end of the transfer.
		var duration: Duration = .zero
	}

	/// Line of 5 relays, 1 MB/s per link and direction; 20 MB from d0 to d4 while d1 → d3 and
	/// d2 → d4 exchange a chat every 2 s.
	static func lineTransfer(window: Int) async throws -> LineOutcome {
		var config = SimConfig()
		config.bandwidth = 1_000_000
		config.window = window
		config.peerWindow = window
		let net = SimNetwork(count: 5, seed: 57, config: config, talk: true, wrap: SimNetwork.relay)
		net.line()
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(10)))
		let talks = try net.devices.map { try #require($0.talk) }
		let blobs = Inbox<Blob>(talks[4])
		var chatsAt: [String: Duration] = [:]
		var outcome = LineOutcome()
		let chats3 = Inbox<Chat>(talks[3]), chats4 = Inbox<Chat>(talks[4])
		let sending = send(Blob(data: randomData(20 * 1024 * 1024)), from: talks[0], to: try #require(talks[0].peer(talks[4])))
		let incoming = { talks[4].transfers.first { $0.direction == .incoming } }
		// encoding runs off the main actor in real time; virtual time passes meanwhile
		#expect(await net.run(until: { (incoming()?.completedBytes ?? 0) > 0 }, limit: .seconds(600)))
		let started = net.now
		let events = net.devices.map(\.events.count)
		let expired = net.devices.map(\.relay.snapshot.counters.entriesExpired)
		var nextChat = net.now
		var chatSends: [ScheduledSend] = []
		#expect(await net.run(until: {
			if net.now >= nextChat && sending.result == nil {
				nextChat = net.now + .seconds(2)
				for (from, to) in [(1, 3), (2, 4)] {
					let text = "\(from)→\(to) at \(SimNetwork.milliseconds(net.now))"
					chatsAt[text] = net.now
					if let peer = talks[from].peer(talks[to]) {
						chatSends.append(send(Chat(text: text), from: talks[from], to: peer))
					}
				}
			}
			for chat in chats3.messages + chats4.messages {
				if let at = chatsAt.removeValue(forKey: chat.text) {
					outcome.chatsDelivered += 1
					outcome.maxChatDelay = max(outcome.maxChatDelay, net.now - at)
				}
			}
			return sending.result != nil && !blobs.results.isEmpty
		}, limit: .seconds(120)))
		outcome.duration = net.now - started
		await net.run(for: .seconds(2))	// the last chats
		for chat in chats3.messages + chats4.messages {
			if let at = chatsAt.removeValue(forKey: chat.text) {
				outcome.chatsDelivered += 1
				outcome.maxChatDelay = max(outcome.maxChatDelay, net.now - at)
			}
		}
		outcome.chatsSent = chatSends.count
		outcome.sent = sending.result
		outcome.received = blobs.results.first.map(Finished.init)
		for device in net.devices {
			for event in device.events.dropFirst(events[device.index]) {
				switch event {
				case let .disconnected(id), let .lost(id):
					outcome.peerLosses.append("d\(device.index) -> d\(net.index(of: id) ?? -1)")
				default:
					break
				}
			}
			outcome.entriesExpired += device.relay.snapshot.counters.entriesExpired - expired[device.index]
		}
		#expect(net.contractViolations.isEmpty)
		return outcome
	}

	/// A `Talk.send` running in its own task; `result` is set once it returns.
	@MainActor
	final class ScheduledSend {
		var result: Finished?
	}

	static func send<Message: TalkMessage>(_ message: Message, from talk: Talk, to peer: Peer) -> ScheduledSend {
		let scheduled = ScheduledSend()
		Task {
			do throws(TalkError) {
				try await talk.send(message, to: peer)
				scheduled.result = .success
			} catch {
				scheduled.result = .failure(error)
			}
		}
		return scheduled
	}
}

/// A finished send or receive, comparable in expectations (`Result<Void, _>` is not `Equatable`).
enum Finished: Equatable {
	case success
	case failure(TalkError)

	init<Success>(_ result: Result<Success, TalkError>) {
		switch result {
		case .success:
			self = .success
		case let .failure(error):
			self = .failure(error)
		}
	}
}

extension SimNetwork {

	/// The `Talk` frame in data on a link, bare or inside a relay data envelope.
	static func talkFrame(_ data: Data) -> Frame? {
		if let envelope = RelayEnvelope(data) {
			return envelope.kind == .data ? Frame(envelope.payload) : nil
		}
		return Frame(data)
	}
}
