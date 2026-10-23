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
