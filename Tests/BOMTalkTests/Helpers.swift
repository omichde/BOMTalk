//
//  Helpers.swift
//  BOMTalkTests
//

import Foundation
@preconcurrency import Combine
import Testing
@testable import BOMTalk

struct Chat: TalkMessage, Equatable {
	static let kind = "chat"
	var text: String
}

struct Blob: TalkMessage, Equatable {
	static let kind = "blob"
	var data: Data
}

/// Same kind as `Chat`, incompatible layout.
struct NotChat: TalkMessage {
	static let kind = "chat"
	var number: Int
}

/// Incompressible data, so payloads really span many chunks.
func randomData(_ count: Int) -> Data {
	var generator = SystemRandomNumberGenerator()
	let words = (0 ..< (count + 7) / 8).map { _ in generator.next() as UInt64 }
	return words.withUnsafeBytes { Data($0.prefix(count)) }
}

/// Spins the main actor until `condition` holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
	let deadline = ContinuousClock.now + timeout
	while !condition() {
		guard ContinuousClock.now < deadline else { return false }
		await Task.yield()
	}
	return true
}

/// Collects a typed stream.
@MainActor
final class Inbox<Message: TalkMessage> {
	private(set) var results: [Result<Received<Message>, TalkError>] = []
	private var cancellable: AnyCancellable?

	init(_ talk: Talk) {
		cancellable = talk.messages(Message.self).sink { [weak self] in self?.results.append($0) }
	}

	var messages: [Message] { results.compactMap { try? $0.get().message } }
	var errors: [TalkError] {
		results.compactMap {
			guard case .failure(let error) = $0 else { return nil }
			return error
		}
	}

	func cancel() {
		cancellable = nil
	}
}

/// Starts talks on one hub and waits until all are connected to each other.
@MainActor
func connect(_ talks: [Talk]) async -> Bool {
	talks.forEach { $0.start() }
	return await eventually { talks.allSatisfy { $0.connectedCount == talks.count - 1 } }
}

/// Two talks "A" and "B" on a fresh hub, connected to each other.
@MainActor
func connectedPair() async throws -> (hub: LoopbackHub, a: Talk, b: Talk) {
	let hub = LoopbackHub()
	let a = hub.makeTalk(name: "A"), b = hub.makeTalk(name: "B")
	try #require(await connect([a, b]))
	return (hub, a, b)
}

extension Talk {
	func peer(_ other: Talk) -> Peer? {
		peers.first { $0.id == other.me.id }
	}

	var connectedCount: Int { peers.filter { $0.state == .connected }.count }

	/// Waits until `count` peers are connected (for raw transports without a Talk).
	func connected(_ count: Int) async -> Bool {
		await eventually { connectedCount == count }
	}
}
