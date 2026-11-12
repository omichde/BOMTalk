//
//  LinkRadio.swift
//  BOMTalk
//

import Foundation
import MultipeerConnectivity

/// Callbacks of a `LinkRadio`, delivered on the main actor in arrival order.
enum LinkRadioEvent<Handle: Hashable> {
	/// The browser found a peer, or its discovery info changed.
	case found(Handle, discoveryInfo: [String: String]?)
	case lost(Handle)
	/// A peer invites us into our session. `reply` must be called exactly once.
	case invitation(Handle, context: Data?, reply: @MainActor (_ accept: Bool) -> Void)
	/// Session state of a peer: `connecting` after an accepted invitation, then `connected` or `notConnected`.
	case state(Handle, MCSessionState)
	case data(Data, from: Handle)
	/// Advertiser or browser could not start.
	case failed(TalkError)
}

/// The radio below `LinkTransport`: one session (at most 8 peers including this device) plus an
/// advertiser and a browser. Owns all MultipeerConnectivity objects in production (`MPCRadio`);
/// tests plug in a simulated one.
///
/// After `stop()` no callbacks of that run arrive; invitations reaching a stopped radio are declined
/// by the radio itself.
@MainActor
protocol LinkRadio: AnyObject {
	/// Identifies a peer on the radio (`MCPeerID` in production). One device may use several.
	associatedtype Handle: Hashable

	var onEvent: (@MainActor (LinkRadioEvent<Handle>) -> Void)? { get set }

	/// This device in the current run; the browser may report it, too. May change on every start.
	var localHandle: Handle { get }

	func displayName(of handle: Handle) -> String

	/// Starts advertising with `discoveryInfo` and browsing, with a fresh session (and, in production, a
	/// fresh local handle). Idempotent.
	func start(discoveryInfo: [String: String])
	/// Disconnects the session and stops advertising and browsing. Idempotent.
	func stop()
	/// Advertises new discovery info; the session stays.
	func restartAdvertiser(discoveryInfo: [String: String])
	/// Invites a found peer into the session.
	func invite(_ handle: Handle, context: Data?, timeout: TimeInterval)
	/// Cancels a pending or established session link.
	func cancel(_ handle: Handle)
	/// Sends reliably to a peer of the session.
	func send(_ data: Data, to handle: Handle) throws
}
