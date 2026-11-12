//
//  TransportContract.swift
//  BOMTalkTests
//

import Foundation
@testable import BOMTalk

/// Checks the ordering rules of `TransportEvent` (see Transport.swift) for the events one device's
/// top transport emits, per remote peer:
///
/// - `connected` needs a prior `found` or `connecting`; `connecting` and `connected` don't repeat
///   without a `disconnected` in between
/// - `disconnected` only while connecting or connected
/// - `received` only while connected
/// - `lost` only while found and not connected (connected peers are `disconnected` first); after
///   `lost` nothing but `found` or `connecting`
struct TransportContract {

	private enum State {
		case found, connecting, connected
	}

	private var states: [UUID: State] = [:]

	/// Forgets everything, like a stopped transport.
	mutating func reset() {
		states = [:]
	}

	/// Applies the event; returns a description of the violated rule, nil if the event is allowed.
	mutating func check(_ event: TransportEvent) -> String? {
		switch event {
		case let .found(peer):
			if states[peer.id] == nil {
				states[peer.id] = .found
			}
			return nil
		case let .connecting(id):
			guard states[id] == nil || states[id] == .found else { return "connecting while \(describe(id))" }
			states[id] = .connecting
			return nil
		case let .connected(peer):
			guard states[peer.id] == .found || states[peer.id] == .connecting else { return "connected while \(describe(peer.id))" }
			states[peer.id] = .connected
			return nil
		case let .disconnected(id):
			guard states[id] == .connecting || states[id] == .connected else { return "disconnected while \(describe(id))" }
			states[id] = .found
			return nil
		case let .lost(id):
			guard states[id] == .found else { return "lost while \(describe(id))" }
			states[id] = nil
			return nil
		case let .received(_, id):
			guard states[id] == .connected else { return "received while \(describe(id))" }
			return nil
		case .failed:
			return nil
		}
	}

	private func describe(_ id: UUID) -> String {
		states[id].map { "\($0)" } ?? "unknown"
	}
}
