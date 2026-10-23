//
//  Peer.swift
//  BOMTalk
//

import Foundation

/// A device running the same app (same app id and protocol version) in the local network.
public struct Peer: Identifiable, Hashable, Sendable {

	public enum State: Sendable, Hashable {
		case discovered
		case connecting
		case connected
	}

	/// Stable identity, persisted across launches.
	public let id: UUID
	/// Display name as passed by the host app on the other device.
	public let name: String
	public var state: State
	/// Custom host info as set via `Talk.info` on the other device.
	public var info: [String: String]

	public init(id: UUID, name: String, state: State, info: [String: String] = [:]) {
		self.id = id
		self.name = name
		self.state = state
		self.info = info
	}
}
