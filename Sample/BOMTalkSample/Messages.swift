//
//  Messages.swift
//  BOMTalkSample
//

import Foundation
import BOMTalk

/// A short text, broadcast to all peers.
struct Chat: TalkMessage {
	static let kind = "chat"
	var text: String
	var date: Date
}

/// A big chunk of random data, sent to one peer to show transfer progress.
struct Blob: TalkMessage {
	static let kind = "blob"
	var data: Data

	/// Random bytes do not compress, so the full size goes over the wire.
	static func random(megabytes: Int) async -> Blob {
		await Task.detached(priority: .userInitiated) {
			let count = megabytes * 1_000_000
			var data = Data(count: count)
			data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
			return Blob(data: data)
		}.value
	}
}

/// Numbered ping of a soak run, broadcast to all peers: receivers track what arrives per origin.
struct SoakPing: TalkMessage {
	static let kind = "soak-ping"
	/// Label of the sending instance.
	var origin: String
	var seq: Int
	/// Seconds since 1970 at the sender (simulators and instances on one Mac share the clock).
	var sentAt: Double
}
