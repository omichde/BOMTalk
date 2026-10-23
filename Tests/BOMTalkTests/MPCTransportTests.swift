//
//  MPCTransportTests.swift
//  BOMTalk
//

import Foundation
import Testing
@testable import BOMTalk

@Suite struct MPCTransportTests {

	let appID = "de.werk01.test"

	// MARK: - Discovery info and invitations

	@Test func discoveryInfo() throws {
		let uuid = UUID()
		let encoded = DiscoveryInfo.encode(appID: appID, protocolVersion: 2, uuid: uuid, info: ["role": "controller"])
		let decoded = try #require(DiscoveryInfo.decode(encoded, appID: appID, protocolVersion: 2))
		#expect(decoded.id == uuid)
		#expect(decoded.info == ["role": "controller"])

		#expect(DiscoveryInfo.decode(encoded, appID: "other.app", protocolVersion: 2) == nil)
		#expect(DiscoveryInfo.decode(encoded, appID: appID, protocolVersion: 1) == nil)
		#expect(DiscoveryInfo.decode(nil, appID: appID, protocolVersion: 2) == nil)
		var badUUID = encoded
		badUUID["_u"] = "nope"
		#expect(DiscoveryInfo.decode(badUUID, appID: appID, protocolVersion: 2) == nil)
	}

	@Test func discoveryInfoTooLarge() throws {
		let uuid = UUID()
		let info = ["a": String(repeating: "x", count: 200), "b": String(repeating: "x", count: 200)]
		let encoded = DiscoveryInfo.encode(appID: appID, protocolVersion: 1, uuid: uuid, info: info)
		let decoded = try #require(DiscoveryInfo.decode(encoded, appID: appID, protocolVersion: 1))
		#expect(decoded.id == uuid)
		#expect(decoded.info.isEmpty)	// host info dropped, identity kept
	}

	@Test func invitationContextMismatch() {
		let uuid = UUID()
		let data = InvitationContext(appID: appID, version: 1, uuid: uuid).encoded()
		#expect(InvitationContext.decode(data, appID: appID, protocolVersion: 1) == uuid)
		#expect(InvitationContext.decode(data, appID: "other.app", protocolVersion: 1) == nil)
		#expect(InvitationContext.decode(data, appID: appID, protocolVersion: 2) == nil)
		#expect(InvitationContext.decode(Data("garbage".utf8), appID: appID, protocolVersion: 1) == nil)
	}

	@Test func startErrors() {
		let bonjour = "NSNetServicesErrorDomain"
		#expect(MPCPolicy.startError(NSError(domain: bonjour, code: -72008), serviceType: "bt") == .misconfigured("NSBonjourServices must list _bt._tcp and _bt._udp"))
		#expect(MPCPolicy.startError(NSError(domain: bonjour, code: -65570), serviceType: "bt") == .localNetworkDenied)
		let wrapped = NSError(domain: "MCErrorDomain", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: bonjour, code: -65570)])
		#expect(MPCPolicy.startError(wrapped, serviceType: "bt") == .localNetworkDenied)
		#expect(MPCPolicy.startError(NSError(domain: bonjour, code: -72000), serviceType: "bt") == nil)
	}

	// MARK: - Identity (in-memory UUID store, throwaway defaults suite)

	final class MemoryStore: MPCUUIDStore {
		var uuid: UUID?
		func read() throws -> UUID? { uuid }
		func write(_ uuid: UUID) throws { self.uuid = uuid }
	}

	private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
		let suite = "BOMTalkTests.\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		try body(defaults)
	}

	@Test func identityPersists() throws {
		try withDefaults { defaults in
			let store = MemoryStore()
			let first = MPCIdentity.load(appID: appID, displayName: "iPad", defaults: defaults, store: store)
			let second = MPCIdentity.load(appID: appID, displayName: "iPad", defaults: defaults, store: store)
			#expect(store.uuid == first.uuid)
			#expect(first.uuid == second.uuid)
			#expect(first.peerID == second.peerID)
		}
	}

	/// Restored / cloned device: UserDefaults came along, the device-only UUID store did not.
	@Test func identityRestoredBackup() throws {
		try withDefaults { defaults in
			let original = MPCIdentity.load(appID: appID, displayName: "iPad", defaults: defaults, store: MemoryStore())
			let store = MemoryStore()
			let restored = MPCIdentity.load(appID: appID, displayName: "iPad", defaults: defaults, store: store)
			#expect(restored.uuid != original.uuid)
			#expect(restored.peerID != original.peerID)
			#expect(MPCIdentity.load(appID: appID, displayName: "iPad", defaults: defaults, store: store).peerID == restored.peerID)
		}
	}
}
