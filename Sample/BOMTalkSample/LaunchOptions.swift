//
//  LaunchOptions.swift
//  BOMTalkSample
//

import Foundation

/// Launch arguments for scripted runs (`simctl launch … -autostart YES -controlPort 8101`), read from
/// `UserDefaults`' argument domain. Without any of them the Sample behaves as always.
///
/// | argument | meaning |
/// |---|---|
/// | `-autostart YES` | start `Talk` right away |
/// | `-controlPort <n>` | HTTP control layer on that port (`GET /state`, `POST /command`) |
/// | `-linkCap <n>` | link cap 1…7 (2 = 1 regular + 1 bridge) |
/// | `-ephemeral YES` | random identity, nothing stored (several instances on one Mac) |
/// | `-block "<a>,<b>"` | display names to ignore |
/// | `-label <name>` | display name, instead of the stored or generated one |
/// | `-runID <id>` | tags the event log and `/state` |
/// | `-soak YES` | broadcast a numbered ping every 3 s, track what arrives |
/// | `-soakBlobMB <n>` | with `-soak`: a blob of n MB to a random reachable peer every 30 s |
/// | `-acceptBlobs YES` | accept incoming blobs from the start (implied by `-soak`) |
struct LaunchOptions: Sendable, Equatable {

	var autostart = false
	var controlPort: UInt16?
	var linkCap: Int?
	var ephemeral = false
	var blocked: Set<String> = []
	var label: String?
	var runID = ""
	var soak = false
	var soakBlobMB: Int?
	var acceptBlobs = false

	static let current = LaunchOptions(defaults: .standard)

	init() {}

	init(defaults: UserDefaults) {
		autostart = defaults.bool(forKey: "autostart")
		controlPort = Self.integer("controlPort", in: 1 ... Int(UInt16.max), defaults).map { UInt16($0) }
		linkCap = Self.integer("linkCap", in: 1 ... 7, defaults)
		ephemeral = defaults.bool(forKey: "ephemeral")
		blocked = Self.names(defaults.string(forKey: "block"))
		label = defaults.string(forKey: "label").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
		runID = defaults.string(forKey: "runID") ?? UUID().uuidString.prefix(8).lowercased()
		soak = defaults.bool(forKey: "soak")
		soakBlobMB = Self.integer("soakBlobMB", in: 1 ... 500, defaults)
		acceptBlobs = defaults.bool(forKey: "acceptBlobs") || soak
	}

	/// Any option that needs the debug SPI at creation.
	var needsDebugTalk: Bool { linkCap != nil || ephemeral || !blocked.isEmpty }
	/// Control layer, event log, soak: anything beyond the plain demo.
	var hasControl: Bool { controlPort != nil || soak }

	static func names(_ list: String?) -> Set<String> {
		Set((list ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
	}

	private static func integer(_ key: String, in range: ClosedRange<Int>, _ defaults: UserDefaults) -> Int? {
		guard let text = defaults.string(forKey: key), let value = Int(text.trimmingCharacters(in: .whitespaces)), range.contains(value) else { return nil }
		return value
	}
}
