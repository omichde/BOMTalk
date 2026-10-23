//
//  TalkTests.swift
//  BOMTalkTests
//

import Foundation
import Testing
@testable import BOMTalk

@Suite @MainActor struct TalkTests {

	@Test func connectsAndLists() async throws {
		let (_, a, b) = try await connectedPair()
		#expect(a.peer(b)?.name == "B")
		#expect(b.peer(a)?.state == .connected)
		b.stop()
		#expect(!b.isRunning && b.peers.isEmpty)
		#expect(await eventually { a.peers.isEmpty })
	}

	@Test func sendsSmallMessage() async throws {
		let (_, a, b) = try await connectedPair()
		let inbox = Inbox<Chat>(b)
		try await a.send(Chat(text: "Hi"), to: try #require(a.peer(b)))
		#expect(await eventually { inbox.messages == [Chat(text: "Hi")] })
		#expect(try inbox.results[0].get().peer.id == a.me.id)
	}

	@Test func largePayloadWithProgress() async throws {
		let (_, a, b) = try await connectedPair()
		let inbox = Inbox<Blob>(b)
		let blob = Blob(data: randomData(2 * 1024 * 1024))
		let peer = try #require(a.peer(b))
		let sending = Task { try await a.send(blob, to: peer) }
		#expect(await eventually { !a.transfers.isEmpty && !b.transfers.isEmpty })
		let outgoing = try #require(a.transfers.first), incoming = try #require(b.transfers.first)
		try await sending.value
		#expect(await eventually { inbox.messages == [blob] })
		#expect(outgoing.fractionCompleted == 1 && incoming.fractionCompleted == 1)
		#expect(a.transfers.isEmpty && b.transfers.isEmpty)
	}

	@Test func notWanted() async throws {
		let (_, a, b) = try await connectedPair()
		let peer = try #require(a.peer(b))
		await #expect(throws: TalkError.notWanted) { try await a.send(Chat(text: "nobody"), to: peer) }

		let inbox = Inbox<Chat>(b)
		try await a.send(Chat(text: "wanted"), to: peer)
		#expect(await eventually { inbox.messages.count == 1 })
		inbox.cancel()
		await #expect(throws: TalkError.notWanted) { try await a.send(Chat(text: "cancelled"), to: peer) }
	}

	@Test func offerTimeout() async {
		let hub = LoopbackHub()
		let a = hub.makeTalk(name: "A", offerTimeout: .milliseconds(200))
		_ = hub.makeRaw(name: "silent")
		a.start()
		#expect(await a.connected(1))
		await #expect(throws: TalkError.timeout) { try await a.send(Chat(text: "x"), to: a.peers[0]) }
	}

	@Test func disconnectMidTransfer() async throws {
		let (hub, a, b) = try await connectedPair()
		let inbox = Inbox<Blob>(b)
		let peer = try #require(a.peer(b))
		let sending = Task { try await a.send(Blob(data: randomData(4 * 1024 * 1024)), to: peer) }
		#expect(await eventually { (b.transfers.first?.completedBytes ?? 0) > 0 })
		hub.disconnect(a.me.id, b.me.id)

		await #expect(throws: TalkError.peerDisconnected) { try await sending.value }
		#expect(await eventually { inbox.errors == [.peerDisconnected] })
		#expect(a.transfers.isEmpty && b.transfers.isEmpty)
		#expect(a.peer(b)?.state == .discovered)
	}

	@Test func broadcast() async throws {
		let hub = LoopbackHub()
		let a = hub.makeTalk(name: "A"), b = hub.makeTalk(name: "B"), c = hub.makeTalk(name: "C")
		let inbox = Inbox<Chat>(b)	// C does not listen
		#expect(await connect([a, b, c]))
		let results = await a.send(Chat(text: "all"))
		#expect(results.count == 2)
		#expect((try? results[b.me.id]?.get()) != nil)
		guard case .failure(.notWanted) = results[c.me.id] else {
			Issue.record("expected notWanted for C")
			return
		}
		#expect(await eventually { inbox.messages == [Chat(text: "all")] })
	}

	@Test func interleaving() async throws {
		let (_, a, b) = try await connectedPair()
		var order: [String] = []
		let blobs = b.messages(Blob.self).sink { _ in order.append("blob") }
		let chats = b.messages(Chat.self).sink { _ in order.append("chat") }
		defer { blobs.cancel(); chats.cancel() }
		let peer = try #require(a.peer(b))
		let big = Task { try await a.send(Blob(data: randomData(4 * 1024 * 1024)), to: peer) }
		#expect(await eventually { !a.transfers.isEmpty })
		try await a.send(Chat(text: "quick"), to: peer)	// overtakes the blob
		try await big.value
		#expect(await eventually { order.count == 2 })
		#expect(order == ["chat", "blob"])
	}

	@Test func infoPropagation() async {
		let hub = LoopbackHub()
		let a = hub.makeTalk(name: "A"), b = hub.makeTalk(name: "B")
		a.info = ["role": "controller"]
		#expect(await connect([a, b]))
		#expect(await eventually { b.peer(a)?.info == ["role": "controller"] })
		a.info["role"] = "viewer"
		#expect(await eventually { b.peer(a)?.info == ["role": "viewer"] })
	}

	@Test func decodingFailed() async throws {
		let (_, a, b) = try await connectedPair()
		let inbox = Inbox<NotChat>(b)
		try await a.send(Chat(text: "x"), to: try #require(a.peer(b)))
		#expect(await eventually { inbox.errors == [.decodingFailed] })
		#expect(b.transfers.isEmpty)
	}

	/// Stopping fails an offer still waiting for an answer as well as a running transfer.
	@Test func stopFailsPendingSends() async throws {
		let hub = LoopbackHub()
		let a = hub.makeTalk(name: "A"), b = hub.makeTalk(name: "B")
		let inbox = Inbox<Blob>(b)
		let silent = hub.makeRaw(name: "silent")
		a.start()
		b.start()
		#expect(await a.connected(2))
		let silentPeer = try #require(a.peers.first { $0.id == silent.localPeer.id })
		let pending = Task { try await a.send(Chat(text: "x"), to: silentPeer) }
		let running = Task { try await a.send(Blob(data: randomData(4 * 1024 * 1024)), to: try #require(a.peer(b))) }
		#expect(await eventually { !silent.received.isEmpty && !b.transfers.isEmpty })
		a.stop()
		await #expect(throws: TalkError.notConnected) { try await pending.value }
		await #expect(throws: TalkError.notConnected) { try await running.value }
		#expect(a.peers.isEmpty && a.transfers.isEmpty)
		#expect(await eventually { inbox.errors == [.peerDisconnected] && b.transfers.isEmpty })
	}

	@Test func restartAndSendAgain() async throws {
		let (_, a, b) = try await connectedPair()
		let inbox = Inbox<Chat>(b)
		a.stop()
		#expect(await eventually { b.peers.isEmpty })
		#expect(await connect([a, b]))
		try await a.send(Chat(text: "again"), to: try #require(a.peer(b)))
		#expect(await eventually { inbox.messages == [Chat(text: "again")] })
	}

	@Test func releasedDuringIncomingTransfer() async throws {
		let hub = LoopbackHub()
		var b: Talk? = hub.makeTalk(name: "B", chunkTimeout: .milliseconds(100))
		weak let weakB = b
		let inbox = Inbox<Chat>(try #require(b))
		let raw = hub.makeRaw(name: "raw")
		b?.start()
		#expect(await b?.connected(1) == true)
		let target = try #require(b?.me.id)
		try raw.send(Frame.offer(.init(transferID: UUID(), kind: Chat.kind, totalBytes: 10, chunkCount: 1)).encoded(), to: target)
		#expect(await eventually { b?.transfers.count == 1 })
		b = nil
		#expect(await eventually { weakB == nil })
		try await Task.sleep(for: .milliseconds(300))	// well past the chunk timeout
		#expect(inbox.results.isEmpty)
	}

	@Test func offerValidation() async throws {
		let hub = LoopbackHub()
		let b = hub.makeTalk(name: "B")
		let raw = hub.makeRaw(name: "raw")
		b.start()
		#expect(await b.connected(1))
		let id = UUID()
		try raw.send(Frame.offer(.init(transferID: id, kind: Chat.kind, totalBytes: 10, chunkCount: 2)).encoded(), to: b.me.id)
		#expect(await eventually { raw.received.compactMap(Frame.init).contains(.reject(id)) })
		#expect(!raw.received.compactMap(Frame.init).contains(.accept(id)))
		#expect(b.transfers.isEmpty)
	}

	@Test func chunkFromOtherPeerIgnored() async throws {
		let hub = LoopbackHub()
		let b = hub.makeTalk(name: "B")
		let inbox = Inbox<Chat>(b)
		let sender = hub.makeRaw(name: "sender"), intruder = hub.makeRaw(name: "intruder")
		b.start()
		#expect(await b.connected(2))
		let payload = try await Codec.encode(Chat(text: "real"))
		let id = UUID()
		try sender.send(Frame.offer(.init(transferID: id, kind: Chat.kind, totalBytes: UInt64(payload.count), chunkCount: 1)).encoded(), to: b.me.id)
		#expect(await eventually { b.transfers.count == 1 })
		try intruder.send(Frame.chunk(transferID: id, index: 0, payload: Data(count: payload.count)).encoded(), to: b.me.id)
		try sender.send(Frame.chunk(transferID: id, index: 0, payload: payload).encoded(), to: b.me.id)
		#expect(await eventually { inbox.results.count == 1 })
		#expect(inbox.messages == [Chat(text: "real")])
	}
}
