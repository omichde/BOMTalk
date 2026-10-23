//
//  Codec.swift
//  BOMTalk
//

import Foundation

/// Message ⇄ payload: binary property list, always lzfse compressed.
///
/// The functions are `@concurrent`, so they always run on the global executor, off the main actor.
enum Codec {

	@concurrent static func encode<Message: Encodable & Sendable>(_ message: Message) async throws(TalkError) -> Data {
		do {
			let encoder = PropertyListEncoder()
			encoder.outputFormat = .binary
			let plist = try encoder.encode(message)
			return try (plist as NSData).compressed(using: .lzfse) as Data
		} catch {
			throw .encodingFailed
		}
	}

	@concurrent static func decode<Message: Decodable & Sendable>(_ type: Message.Type, from payload: Data) async throws(TalkError) -> Message {
		do {
			let plist = try (payload as NSData).decompressed(using: .lzfse) as Data
			return try PropertyListDecoder().decode(type, from: plist)
		} catch {
			throw .decodingFailed
		}
	}
}
