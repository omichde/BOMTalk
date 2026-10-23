//
//  MPCPolicy.swift
//  BOMTalk
//

import Foundation
import os

/// Discovery info as advertised via Bonjour: host info plus reserved internal keys.
enum DiscoveryInfo {

	static let appKey = "_a"
	static let versionKey = "_v"
	static let uuidKey = "_u"
	static let reservedKeys: Set<String> = [appKey, versionKey, uuidKey]

	/// Bonjour TXT record limits: 255 bytes per `key=value`, about 400 bytes in total.
	static let maxPairBytes = 255
	static let maxTotalBytes = 400

	private static let logger = Logger.bomtalk("transport")

	/// Reserved keys always win. Invalid host pairs are dropped; if the host info doesn't fit, only the
	/// reserved keys are advertised (connected peers still get the info via Talk's info frame).
	static func encode(appID: String, protocolVersion: Int, uuid: UUID, info: [String: String]) -> [String: String] {
		let reserved = [appKey: appID, versionKey: String(protocolVersion), uuidKey: uuid.uuidString]
		var result = reserved
		for (key, value) in info {
			guard !reservedKeys.contains(key), isValidKey(key), pairBytes(key, value) <= maxPairBytes else {
				logger.error("dropping discovery info key \(key, privacy: .public)")
				continue
			}
			result[key] = value
		}
		guard result.reduce(0, { $0 + 1 + pairBytes($1.key, $1.value) }) <= maxTotalBytes else {
			logger.error("discovery info exceeds \(maxTotalBytes) bytes, advertising without host info")
			return reserved
		}
		return result
	}

	/// Non-empty printable ASCII without `=`.
	static func isValidKey(_ key: String) -> Bool {
		!key.isEmpty && key.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) && $0 != "=" }
	}

	/// Size of `key=value` in the TXT record (without its length byte).
	private static func pairBytes(_ key: String, _ value: String) -> Int {
		key.utf8.count + 1 + value.utf8.count
	}

	/// Returns the peer's UUID and host info, or nil for foreign / incompatible / invalid peers.
	static func decode(_ info: [String: String]?, appID: String, protocolVersion: Int) -> (id: UUID, info: [String: String])? {
		guard let info,
			info[appKey] == appID,
			info[versionKey] == String(protocolVersion),
			let id = info[uuidKey].flatMap(UUID.init(uuidString:))
		else { return nil }
		return (id, info.filter { !reservedKeys.contains($0.key) })
	}
}

/// Sent as invitation context, checked by the invitee before accepting.
struct InvitationContext: Codable, Equatable {
	let appID: String
	let version: Int
	let uuid: UUID

	func encoded() -> Data? {
		try? JSONEncoder().encode(self)
	}

	/// Returns the inviter's UUID if the context matches this app id and version.
	static func decode(_ data: Data?, appID: String, protocolVersion: Int) -> UUID? {
		guard let data,
			let context = try? JSONDecoder().decode(InvitationContext.self, from: data),
			context.appID == appID,
			context.version == protocolVersion
		else { return nil }
		return context.uuid
	}
}

/// Connection rules: peer cap, tie-break, reconnect backoff, error mapping.
enum MPCPolicy {

	/// 8 peers per `MCSession` in total, including this device.
	static let maxRemotePeers = 7
	/// Handshakes on a LAN take < 2 s; an unanswered invitation must not block the peer for long.
	static let inviteTimeout: TimeInterval = 10
	/// A peer stuck in connecting this long is cancelled and counts as failed attempt.
	static let watchdogDelay: Duration = .seconds(inviteTimeout + 10)
	/// The side not inviting waits this long before inviting anyway.
	static let fallbackDelay: Duration = .seconds(5)
	/// Our own invitation younger than this makes an incoming one simultaneous (declined by the
	/// designated inviter); an older one is stale and gives way to the incoming invitation.
	static let simultaneousInviteWindow: Duration = .seconds(3)
	/// Starts at 2 s: right after a disconnect the remote may still be stopping (backgrounded).
	static let backoff: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
	/// At most one advertiser restart (info update) per interval.
	static let advertiserRestartDelay: Duration = .milliseconds(500)

	/// The side with the lower UUID invites.
	static func invitesFirst(local: UUID, remote: UUID) -> Bool {
		local.uuidString < remote.uuidString
	}

	/// Delay before inviting a visible idle peer after `failures` consecutive failed or dropped
	/// connections: backoff (30 s cap) plus the tie-break fallback for the side not inviting first.
	static func delay(failures: Int, invitesFirst: Bool) -> Duration {
		let backoff = failures <= 0 ? .zero : backoff[min(failures, backoff.count) - 1]
		return backoff + (invitesFirst ? .zero : fallbackDelay)
	}

	static let policyDeniedCode = -65570	// kDNSServiceErr_PolicyDenied
	static let missingConfigurationCode = -72008	// NSNetServicesMissingRequiredConfigurationError

	/// Maps an advertiser / browser start error; nil if it is neither a denial nor a misconfiguration.
	static func startError(_ error: any Error, serviceType: String) -> TalkError? {
		let codes = errorCodes(error)
		if codes.contains(missingConfigurationCode) {
			return .misconfigured("NSBonjourServices must list _\(serviceType)._tcp and _\(serviceType)._udp")
		}
		return codes.contains(policyDeniedCode) ? .localNetworkDenied : nil
	}

	/// Codes of the error itself (incl. NetService's error code) and of its underlying error.
	private static func errorCodes(_ error: any Error) -> [Int] {
		let error = error as NSError
		let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
		return [error.code, error.userInfo["NSNetServicesErrorCode"] as? Int, underlying?.code].compactMap(\.self)
	}
}
