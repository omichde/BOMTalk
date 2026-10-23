//
//  TalkMessage.swift
//  BOMTalk
//

import Foundation

/// A message that can be sent to and received from peers.
///
/// `kind` identifies the message type on the wire and must be stable across app versions
/// (renaming the Swift type must not change it).
///
/// ```swift
/// struct Chat: TalkMessage {
/// 	static let kind = "chat"
/// 	var text: String
/// }
/// ```
public protocol TalkMessage: Codable, Sendable {
	static var kind: String { get }
}

/// A received message together with a snapshot of its sender at arrival time.
public struct Received<Message: TalkMessage>: Sendable {
	public let message: Message
	public let peer: Peer

	public init(message: Message, peer: Peer) {
		self.message = message
		self.peer = peer
	}
}
