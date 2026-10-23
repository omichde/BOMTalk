//
//  TalkError.swift
//  BOMTalk
//

import Foundation

public enum TalkError: Error, Sendable, Hashable {
	/// The peer has no subscriber for this message kind and rejected the offer.
	case notWanted
	/// The peer did not answer an offer or stopped sending chunks in time.
	case timeout
	/// The peer disconnected during the transfer.
	case peerDisconnected
	/// The peer is unknown or not connected.
	case notConnected
	case encodingFailed
	case decodingFailed
	/// Local network access was denied by the user. Note: MultipeerConnectivity does not always
	/// report a denial, nearby peers may simply never show up.
	case localNetworkDenied
	/// The app is set up incorrectly, e.g. `NSBonjourServices` misses `_<serviceType>._tcp` / `._udp`.
	case misconfigured(String)
	case advertiserFailed(String)
	case browserFailed(String)
	case sendFailed(String)
}
