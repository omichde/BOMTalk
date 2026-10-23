//
//  Transport.swift
//  BOMTalk
//

import Foundation

/// A peer as seen by the transport: already filtered to the same app id and protocol version.
struct TransportPeer: Sendable, Hashable {
	let id: UUID
	let name: String
	/// Host info from discovery, reserved internal keys stripped.
	var info: [String: String]
}

/// Ordering: `connecting` / `connected` may arrive without a prior `found` (peer invited us before our
/// browser saw it). A peer's `received` data is always preceded by its `connected`. After `lost`
/// no further events for that peer arrive until it is `found` or `connecting` again.
enum TransportEvent: Sendable {
	/// A compatible peer became visible.
	case found(TransportPeer)
	/// A previously found peer is no longer visible (and not connected).
	case lost(UUID)
	case connecting(UUID)
	case connected(TransportPeer)
	/// Connection dropped; the peer may still be visible (then it stays `found`).
	case disconnected(UUID)
	/// Data received from a connected peer, delivered in the order it arrived.
	case received(Data, from: UUID)
	/// General failure not bound to a peer.
	case failed(TalkError)
}

/// Moves opaque data between connected peers, handles discovery, connecting and reconnecting.
/// All calls and all events happen on the main actor; events are delivered in order.
@MainActor
protocol Transport: AnyObject {
	var onEvent: (@MainActor (TransportEvent) -> Void)? { get set }

	/// Identity of this device.
	var localPeer: TransportPeer { get }

	/// Starts advertising, browsing and auto-connecting. Idempotent.
	func start(info: [String: String])
	/// Disconnects all peers and stops advertising and browsing. Idempotent.
	func stop()
	/// Updates the advertised host info (restarts advertising if running).
	func update(info: [String: String])
	/// Sends data reliably to a connected peer. Data is at most one chunk frame (header + `Frame.maxChunkPayload`).
	func send(_ data: Data, to peer: UUID) throws(TalkError)
}
