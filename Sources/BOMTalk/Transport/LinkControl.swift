//
//  LinkControl.swift
//  BOMTalk
//

import Foundation

/// Who the lower transport may link to, decided by `RelayTransport` from its link map (6 + 1).
///
/// Without a policy the peer machine connects first come, first served up to its cap. With one, the
/// cap splits into `LinkSlots`: regular slots stay first come, first served, the bridge slot only
/// admits bridge candidates. Applies to inviting and to accepting invitations alike.
struct LinkPolicy: Sendable, Equatable {
	/// Visible but unreachable devices (another partition), after a grace period: may take the bridge
	/// slot, and are preferred when slots free up.
	var bridgeCandidates: Set<UUID> = []
	/// Deliberately unlinked devices, still reachable via relay: neither invited nor accepted.
	var suppressed: Set<UUID> = []
	/// Reachable devices without a free regular slot (per their hello): not invited, because they
	/// would decline. Their invitations are still accepted.
	var full: Set<UUID> = []
}

/// Control of a link transport by the decorator above it. `RelayTransport` uses it when its lower
/// transport conforms (`LinkTransport` does); `Transport` itself stays policy-free.
///
/// Calls may come from within the transport's own `onEvent`; the resulting actions run after the
/// event being delivered, in order.
@MainActor
protocol LinkControl: AnyObject {
	/// Peer cap of the link transport, split by `LinkSlots` once a policy is set.
	var linkCap: Int { get }
	/// Replaces the policy; waiting peers are reconsidered, bridge candidates first.
	func setLinkPolicy(_ policy: LinkPolicy)
	/// Drops the link to a peer, pending or connected: `disconnected` follows like for any drop.
	func disconnect(_ id: UUID)
}

/// Debug controls of a link transport (`Talk`'s Debug SPI, simulator rigs): ignore devices by name.
@MainActor
protocol LinkDebugControl: AnyObject {
	/// Display names of devices that are treated as invisible: not found, not invited, their
	/// invitations declined, existing links dropped. An empty set unblocks them again.
	var blockedNames: Set<String> { get }
	func setBlockedNames(_ names: Set<String>)
}
