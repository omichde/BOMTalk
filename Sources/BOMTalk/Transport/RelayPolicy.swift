//
//  RelayPolicy.swift
//  BOMTalk
//

import Foundation

/// Relay rules: hello timing, expiry, hop limit, buffer limits, link policy. See `RelayTransport`.
enum RelayPolicy {

	/// Hops a frame may travel, also the maximum route length. Bridge merges stretch the diameter.
	static let hopLimit: UInt8 = 16
	/// Periodic hello, ± `helloJitter`.
	static let helloInterval: Duration = .seconds(3)
	static let helloJitter = 0.2
	/// Triggered hellos (own neighbours or info changed) are coalesced to at most one per gap.
	static let helloMinGap: Duration = .milliseconds(500)
	/// A map entry without a fresher hello for this long is removed. A direct neighbour that sent
	/// nothing for this long no longer counts as linked (stalled link).
	static let helloExpiry: Duration = .seconds(10)
	/// After expiry, the last version of an origin stays known this long, so old copies of its hello
	/// (map sync from a neighbour that expires a bit later) cannot bring the entry back.
	static let tombstoneDuration: Duration = .seconds(30)
	/// Expiry, liveness and buffer timeouts are checked at this interval.
	static let sweepInterval: Duration = .seconds(1)
	/// Data from origins not reachable yet (hello still on its way) is held this long at most …
	static let bufferMaxAge: Duration = .seconds(5)
	/// … and up to this many frames per origin …
	static let bufferMaxFrames = 64
	/// … and this many bytes in total.
	static let bufferMaxBytes = 1024 * 1024

	// MARK: Link policy (6 + 1, slot split in `LinkSlots`)

	/// A visible device must stay unreachable this long (± `decisionJitter`) before it becomes a
	/// bridge candidate: more than one hello interval, so a fresh joiner's hello can arrive first.
	static let bridgeDelay: Duration = .seconds(5)
	/// With every slot in use, a redundant neighbour is dropped once the map has been stable and a
	/// redundant neighbour existed this long (± `decisionJitter`).
	static let dropDelay: Duration = .seconds(5)
	static let decisionJitter = 0.2
	/// Links younger than this are never dropped as redundant.
	static let minLinkAge: Duration = .seconds(30)
	/// Links that carried data (own or forwarded, either direction) this recently are never dropped.
	static let dataQuiet: Duration = .seconds(5)
	/// At most one voluntary drop per device per interval.
	static let dropInterval: Duration = .seconds(10)
	/// The receiver of an `unlink` disconnects this long after it, once the link carried no data for
	/// `dataQuiet`.
	static let unlinkDelay: Duration = .milliseconds(500)
	/// The sender of an `unlink` that is still linked this long after uses the link again.
	static let unlinkTimeout: Duration = .seconds(60)
	/// Unlinked devices are not linked again while reachable, at most this long.
	static let suppressionTimeout: Duration = .seconds(5 * 60)
	/// A connected neighbour that sent nothing this long is disconnected, freeing its slot.
	static let stalledDisconnect: Duration = .seconds(15)
	/// Link policy actions kept for the snapshot.
	static let linkActionHistory = 64

	/// Delay until the next periodic hello: `helloInterval` ± `helloJitter`.
	static func helloDelay(using random: inout some RandomNumberGenerator) -> Duration {
		helloInterval * Double.random(in: (1 - helloJitter) ... (1 + helloJitter), using: &random)
	}

	/// `delay` ± `decisionJitter`, for bridge and drop decisions.
	static func jittered(_ delay: Duration, using random: inout some RandomNumberGenerator) -> Duration {
		delay * Double.random(in: (1 - decisionJitter) ... (1 + decisionJitter), using: &random)
	}
}
