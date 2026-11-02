//
//  RelayPolicy.swift
//  BOMTalk
//

import Foundation

/// Relay rules: hello timing, expiry, hop limit, buffer limits. See `RelayTransport`.
enum RelayPolicy {

	/// Advertised in discovery and invitations; devices of another generation never connect.
	/// 3: the first relay build (BOMTalk v2 had none).
	static let generation = 3
	/// Hops a frame may travel, also the maximum route length.
	static let hopLimit: UInt8 = 8
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

	/// Delay until the next periodic hello: `helloInterval` ± `helloJitter`.
	static func helloDelay(using random: inout some RandomNumberGenerator) -> Duration {
		helloInterval * Double.random(in: (1 - helloJitter) ... (1 + helloJitter), using: &random)
	}
}
