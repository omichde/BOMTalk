//
//  MPCIdentity.swift
//  BOMTalk
//

import Foundation
import MultipeerConnectivity
import os
import Security

/// Persistent identity of this device: a UUID kept in the Keychain (not part of backups, so restored or
/// cloned devices get their own), mirrored in `UserDefaults` as a fallback if the Keychain fails, plus
/// the display name for MPC.
///
/// The `MCPeerID` is not part of it: `MPCRadio` creates a fresh one on every start. Remote MPC stacks
/// notice an abrupt loss late and keep the old session for that peer id meanwhile; invitations with
/// a reused one hung until they cleaned up (simulator rig runs, 2026-11). Devices are identified
/// by the UUID in the discovery info, so a new peer id per start costs nothing.
struct MPCIdentity {

	let uuid: UUID
	let displayName: String

	/// `MCPeerID` display names are limited to 63 bytes UTF-8.
	static let maxNameBytes = 63

	static func key(appID: String) -> String { "BOMTalk.\(appID).identity" }

	/// Truncates on character boundaries to fit `maxNameBytes`; empty names get a fallback.
	static func peerName(_ name: String) -> String {
		var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
		while name.utf8.count > maxNameBytes {
			name.removeLast()
		}
		return name.isEmpty ? "Peer" : name
	}

	/// A random identity that touches neither Keychain nor UserDefaults: for several instances on one
	/// Mac (debug rigs), which would otherwise share one stored identity and look cloned.
	static func ephemeral(displayName: String) -> MPCIdentity {
		MPCIdentity(uuid: UUID(), displayName: peerName(displayName))
	}

	/// Loads the stored identity, creating it as needed.
	static func load(appID: String, displayName: String, defaults: UserDefaults, store: any MPCUUIDStore) -> MPCIdentity {
		let key = key(appID: appID)
		let stored = defaults.dictionary(forKey: key)
		let storedUUID = (stored?["uuid"] as? String).flatMap(UUID.init(uuidString:))

		var uuid: UUID
		do {
			if let existing = try store.read() {
				uuid = existing
			} else {
				uuid = UUID()	// first launch, restored backup or cloned device
				try store.write(uuid)
			}
		} catch {
			Logger.bomtalk("transport").error("keychain failed, identity only in UserDefaults: \(error, privacy: .public)")
			uuid = storedUUID ?? UUID()
		}

		if uuid != storedUUID || stored?["peerID"] != nil {	// earlier builds archived a peer id here
			defaults.set(["uuid": uuid.uuidString], forKey: key)
		}
		return MPCIdentity(uuid: uuid, displayName: peerName(displayName))
	}
}

/// Storage of the device UUID, injectable for tests.
protocol MPCUUIDStore {
	func read() throws -> UUID?
	func write(_ uuid: UUID) throws
}

/// Generic password item, this device only (excluded from backups and device migration). Uses the
/// data protection keychain; macOS builds without the entitlement fall back to the login keychain.
struct KeychainUUIDStore: MPCUUIDStore {

	let service: String

	func read() throws -> UUID? {
		var result: CFTypeRef?
		let status = run { query in
			var query = query
			query[kSecReturnData] = true
			query[kSecMatchLimit] = kSecMatchLimitOne
			return SecItemCopyMatching(query as CFDictionary, &result)
		}
		if status == errSecItemNotFound { return nil }
		guard status == errSecSuccess, let data = result as? Data else { throw Self.error(status) }
		return UUID(uuidString: String(decoding: data, as: UTF8.self))
	}

	func write(_ uuid: UUID) throws {
		let status = run { query in
			SecItemDelete(query as CFDictionary)
			var query = query
			query[kSecValueData] = Data(uuid.uuidString.utf8)
			query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
			return SecItemAdd(query as CFDictionary, nil)
		}
		guard status == errSecSuccess else { throw Self.error(status) }
	}

	/// Runs on the data protection keychain, then on the login keychain if unavailable there
	/// (reads report "not found" in that case, writes "missing entitlement"; on iOS both are the same).
	private func run(_ operation: ([CFString: Any]) -> OSStatus) -> OSStatus {
		var query: [CFString: Any] = [
			kSecClass: kSecClassGenericPassword,
			kSecAttrService: service,
			kSecAttrAccount: "uuid",
			kSecUseDataProtectionKeychain: true,
		]
		let status = operation(query)
		guard status == errSecMissingEntitlement || status == errSecItemNotFound else { return status }
		query[kSecUseDataProtectionKeychain] = false
		return operation(query)
	}

	private static func error(_ status: OSStatus) -> NSError {
		NSError(domain: NSOSStatusErrorDomain, code: Int(status))
	}
}
