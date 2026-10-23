//
//  Transfer.swift
//  BOMTalk
//

import Foundation
import Observation

/// A transfer in flight, observable for progress. Transfers are removed from `Talk.transfers` once
/// they finished or failed; the outcome is reported by `send` / the `messages` stream.
@MainActor
@Observable
public final class Transfer: Identifiable {

	public enum Direction: Sendable, Hashable {
		case outgoing
		case incoming
	}

	public let id: UUID
	public let peer: Peer.ID
	public let kind: String
	public let direction: Direction
	/// Payload size in bytes (compressed).
	public let totalBytes: Int
	/// Outgoing: bytes handed to the network (may run ahead of delivery). Incoming: bytes received.
	public internal(set) var completedBytes = 0

	/// 0…1
	public var fractionCompleted: Double {
		totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 1
	}

	init(id: UUID, peer: Peer.ID, kind: String, direction: Direction, totalBytes: Int) {
		self.id = id
		self.peer = peer
		self.kind = kind
		self.direction = direction
		self.totalBytes = totalBytes
	}
}
