//
//  SubscriberRegistry.swift
//  BOMTalk
//

import Foundation
import os
@preconcurrency import Combine

/// One channel per message kind: a refcount of its subscribers (decides offer / accept) and a
/// type-erased decode + deliver path feeding a single subject, so a payload is decoded once.
@MainActor
final class SubscriberRegistry {

	private struct Channel {
		/// The typed publisher handed out to subscribers.
		let publisher: Any
		let deliver: @MainActor (Data, Peer) async -> Void
		let fail: @MainActor (TalkError) -> Void
	}

	/// Subscriber counts per kind. Combine may call subscription / cancel handlers off main.
	private nonisolated let counts = OSAllocatedUnfairLock(initialState: [String: Int]())
	private var channels: [String: Channel] = [:]

	nonisolated func count(_ kind: String) -> Int {
		counts.withLock { $0[kind, default: 0] }
	}

	func publisher<Message: TalkMessage>(for type: Message.Type) -> AnyPublisher<Result<Received<Message>, TalkError>, Never> {
		let kind = Message.kind
		if let channel = channels[kind] {
			guard let publisher = channel.publisher as? AnyPublisher<Result<Received<Message>, TalkError>, Never> else {
				log.fault("kind \(kind, privacy: .public) already registered for another type, ignoring \(String(describing: Message.self), privacy: .public)")
				return Empty(completeImmediately: false).eraseToAnyPublisher()
			}
			return publisher
		}

		let subject = PassthroughSubject<Result<Received<Message>, TalkError>, Never>()
		let counts = counts
		let publisher = subject
			.handleEvents(
				receiveSubscription: { @Sendable _ in counts.withLock { $0[kind, default: 0] += 1 } },
				receiveCancel: { @Sendable in counts.withLock { $0[kind, default: 0] -= 1 } }
			)
			.eraseToAnyPublisher()
		channels[kind] = Channel(
			publisher: publisher,
			deliver: { payload, peer in
				do throws(TalkError) {
					let message = try await Codec.decode(Message.self, from: payload)
					subject.send(.success(Received(message: message, peer: peer)))
				} catch {
					subject.send(.failure(error))
				}
			},
			fail: { subject.send(.failure($0)) }
		)
		return publisher
	}

	/// Decodes and delivers to all subscribers of `kind`; dropped if nobody listens anymore.
	func deliver(_ payload: Data, kind: String, from peer: Peer) async {
		guard let channel = channels[kind], count(kind) > 0 else { return }
		await channel.deliver(payload, peer)
	}

	func fail(_ error: TalkError, kind: String) {
		channels[kind]?.fail(error)
	}
}

private let log = Logger.bomtalk("registry")
