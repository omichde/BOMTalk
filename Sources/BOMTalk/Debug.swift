//
//  Debug.swift
//  BOMTalk
//

import Foundation

/// Debug configuration for `Talk`, creation time. Not part of the normal API: `@_spi(Debug) import BOMTalk`.
@_spi(Debug)
public struct TalkDebugOptions: Sendable, Codable, Equatable {

	/// Peer cap of the link layer instead of the 7 of `MCSession`: 2 = 1 regular + 1 bridge link,
	/// which forces chains, rings and multi-hop routes with a handful of devices.
	public var linkCap: Int?
	/// A random device UUID and peer id per instance; nothing is read from or written to the Keychain
	/// or `UserDefaults`. Several instances on one Mac would otherwise share one identity.
	public var ephemeralIdentity: Bool
	/// Display names of devices to ignore from the start, see `Talk.debugSetBlocked(_:)`.
	public var blockedNames: Set<String>

	public init(linkCap: Int? = nil, ephemeralIdentity: Bool = false, blockedNames: Set<String> = []) {
		self.linkCap = linkCap
		self.ephemeralIdentity = ephemeralIdentity
		self.blockedNames = blockedNames
	}
}

/// Everything about a `Talk` and its relay worth looking at while debugging, as plain values (JSON
/// friendly: UUIDs, strings, seconds as `Double`). Times are seconds on the transport's own clock
/// (`clock`); `map[].age` and `linkActions[].at` relate to it.
@_spi(Debug)
public struct TalkDebugSnapshot: Sendable, Codable, Equatable {

	public struct Device: Sendable, Codable, Equatable {
		public let id: UUID
		public let name: String
	}

	/// What `Talk` reports about a peer (all reachable devices, direct or relayed).
	public struct PeerState: Sendable, Codable, Equatable {
		public let id: UUID
		public let name: String
		/// `discovered`, `connecting` or `connected`.
		public let state: String
	}

	/// A reachable device: shortest path length and the direct neighbour to send to.
	public struct Route: Sendable, Codable, Equatable {
		public let id: UUID
		public let name: String
		public let hops: Int
		public let nextHop: UUID
	}

	/// The latest hello of a device in the link map.
	public struct MapEntry: Sendable, Codable, Equatable {
		public let id: UUID
		public let name: String
		public let neighbours: [UUID]
		/// Seconds since its last fresher hello.
		public let age: Double
	}

	public struct Counters: Sendable, Codable, Equatable {
		public let hellosSent: Int
		public let hellosReceived: Int
		public let hellosForwarded: Int
		public let dataForwarded: Int
		/// Map entries removed without a fresh hello.
		public let entriesExpired: Int
		/// Data frames dropped, by reason (`noRoute`, `hopLimit`, `malformed`, `bufferOverflow`,
		/// `bufferTimeout`, `sendFailed`); every reason is present.
		public let drops: [String: Int]
		/// Redundant links this device unlinked.
		public let voluntaryDrops: Int
		public let stalledDisconnects: Int
		public let bridgeConnects: Int
		public let unlinksSent: Int
		public let unlinksReceived: Int
	}

	/// Lower links in use per slot kind, and the capacity of each.
	public struct Slots: Sendable, Codable, Equatable {
		public let regular: Int
		public let bridge: Int
		public let regularCapacity: Int
		public let bridgeCapacity: Int
	}

	/// A link policy decision: `bridge`, `drop`, `unlinked` or `stalled`.
	public struct LinkAction: Sendable, Codable, Equatable {
		public let at: Double
		public let kind: String
		public let neighbour: UUID
		/// Seconds since the link connected, nil if it never did.
		public let linkAge: Double?
	}

	public struct TransferInfo: Sendable, Codable, Equatable {
		public let id: UUID
		public let peer: UUID
		public let kind: String
		/// `outgoing` or `incoming`.
		public let direction: String
		public let completedBytes: Int
		public let totalBytes: Int
	}

	public let me: Device
	public let isRunning: Bool
	/// `Talk.issue`, if any.
	public let issue: String?
	public let clock: Double
	public let peers: [PeerState]
	/// Direct neighbours counted as linked, sorted by UUID.
	public let neighbours: [Device]
	/// Reachable devices, direct ones included, sorted by UUID.
	public let reachable: [Route]
	public let map: [MapEntry]
	public let counters: Counters
	/// Nil when the transport has no link policy (no slots).
	public let slots: Slots?
	/// Devices unlinked on purpose and not linked again for now.
	public let suppressed: [UUID]
	/// Visible but unreachable devices that may take the bridge slot.
	public let bridgeCandidates: [UUID]
	/// Flags of this device's latest hello: `bridgeSlotFree`, `regularSlotsFull`.
	public let flags: [String]
	/// Data frames held for origins that are not reachable yet.
	public let bufferedFrames: Int
	/// The latest link policy decisions, oldest first.
	public let linkActions: [LinkAction]
	/// Debug block list, see `Talk.debugSetBlocked(_:)`.
	public let blocked: [String]
	public let transfers: [TransferInfo]
}

@_spi(Debug)
extension Talk {

	/// Creates a `Talk` with debug configuration, otherwise like `init(serviceType:appID:displayName:protocolVersion:)`.
	public convenience init(serviceType: String, appID: String, displayName: String, protocolVersion: Int = 1, debug: TalkDebugOptions) {
		let cap = min(max(debug.linkCap ?? MPCPolicy.maxRemotePeers, 1), MPCPolicy.maxRemotePeers)
		let lower = MPCTransport(serviceType: serviceType, appID: appID, displayName: displayName, protocolVersion: protocolVersion, maxPeers: cap, ephemeral: debug.ephemeralIdentity)
		self.init(transport: RelayTransport(lower: lower, timers: TaskTimers()))
		debugSetBlocked(debug.blockedNames)
	}

	/// The current state of this device and its relay, see `TalkDebugSnapshot`.
	public func debugSnapshot() -> TalkDebugSnapshot {
		let relay = transport as? RelayTransport
		let snapshot = relay?.snapshot
		let names = Dictionary(snapshot?.reachable.map { ($0.id, $0.name) } ?? [], uniquingKeysWith: { first, _ in first })
		let counters = snapshot?.counters ?? RelayCounters()
		return TalkDebugSnapshot(
			me: .init(id: me.id, name: me.name),
			isRunning: isRunning,
			issue: issue.map { String(describing: $0) },
			clock: snapshot?.now.seconds ?? 0,
			peers: peers.map { .init(id: $0.id, name: $0.name, state: $0.state.debugName) },
			neighbours: (snapshot?.neighbours ?? []).map { id in .init(id: id, name: names[id] ?? peers.first { $0.id == id }?.name ?? "") },
			reachable: (snapshot?.reachable ?? []).map { .init(id: $0.id, name: $0.name, hops: $0.hops, nextHop: $0.nextHop) },
			map: (snapshot?.map ?? []).map { .init(id: $0.id, name: $0.name, neighbours: $0.neighbours, age: $0.age.seconds) },
			counters: .init(
				hellosSent: counters.hellosSent,
				hellosReceived: counters.hellosReceived,
				hellosForwarded: counters.hellosForwarded,
				dataForwarded: counters.dataForwarded,
				entriesExpired: counters.entriesExpired,
				drops: Dictionary(uniqueKeysWithValues: RelayCounters.Drop.allCases.map { ($0.rawValue, counters[$0]) }),
				voluntaryDrops: counters.voluntaryDrops,
				stalledDisconnects: counters.stalledDisconnects,
				bridgeConnects: counters.bridgeConnects,
				unlinksSent: counters.unlinksSent,
				unlinksReceived: counters.unlinksReceived
			),
			slots: snapshot?.slots.map { .init(regular: $0.regular, bridge: $0.bridge, regularCapacity: $0.capacity.regular, bridgeCapacity: $0.capacity.bridge) },
			suppressed: snapshot?.suppressed ?? [],
			bridgeCandidates: snapshot?.bridgeCandidates ?? [],
			flags: (snapshot?.flags).map { flags in
				[flags.contains(.bridgeSlotFree) ? "bridgeSlotFree" : nil, flags.contains(.regularSlotsFull) ? "regularSlotsFull" : nil].compactMap(\.self)
			} ?? [],
			bufferedFrames: snapshot?.bufferedFrames ?? 0,
			linkActions: (snapshot?.linkActions ?? []).map { .init(at: $0.at.seconds, kind: $0.kind.rawValue, neighbour: $0.neighbour, linkAge: $0.linkAge?.seconds) },
			blocked: (relay?.debugBlocked ?? []).sorted(),
			transfers: transfers.map { .init(id: $0.id, peer: $0.peer, kind: $0.kind, direction: $0.direction == .outgoing ? "outgoing" : "incoming", completedBytes: $0.completedBytes, totalBytes: $0.totalBytes) }
		)
	}

	/// Devices with these display names become invisible to the link layer: not found, not invited,
	/// their invitations declined, existing links dropped. Relayed paths through other devices stay.
	/// An empty set (or a smaller one) lets them back in. Survives `stop()` / `start()`.
	public func debugSetBlocked(_ names: Set<String>) {
		(transport as? RelayTransport)?.debugBlocked = names
	}

	/// Drops the direct link to `peer`; false if it is not a direct neighbour. The link layer
	/// connects again after its usual backoff (unless the relay's link policy suppresses the pair).
	@discardableResult
	public func debugDisconnect(_ peer: Peer.ID) -> Bool {
		(transport as? RelayTransport)?.debugDisconnect(peer) ?? false
	}
}

private extension Duration {
	var seconds: Double {
		Double(components.seconds) + Double(components.attoseconds) / 1e18
	}
}

private extension Peer.State {
	var debugName: String {
		switch self {
		case .discovered: "discovered"
		case .connecting: "connecting"
		case .connected: "connected"
		}
	}
}
