//
//  RelayFrame.swift
//  BOMTalk
//

import Foundation

/// Wraps every frame between neighbours, hand-written binary format like `Frame`.
///
/// Header (37 bytes): magic `"BR"`, format version, type, hop limit, origin UUID, destination UUID,
/// followed by the payload: a Talk frame (`data`), a `RelayHello` (`hello`, destination all-zero) or
/// nothing (`unlink`, to a direct neighbour only).
struct RelayEnvelope: Sendable, Equatable {

	enum Kind: UInt8, Sendable {
		case data = 1, hello
		/// The sender drops the direct link on purpose (redundant): the receiver disconnects and
		/// neither side links again while they reach each other via relay.
		case unlink
	}

	let kind: Kind
	/// Hops this frame may still travel, including the one to the receiver.
	var hopLimit: UInt8
	let origin: UUID
	let destination: UUID
	let payload: Data

	static let version: UInt8 = 1
	static let headerSize = 2 + 1 + 1 + 1 + 16 + 16
	/// Destination of flooded frames.
	static let broadcast = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

	private static let magic: [UInt8] = [0x42, 0x52]	// "BR"

	init(kind: Kind, hopLimit: UInt8, origin: UUID, destination: UUID, payload: Data) {
		self.kind = kind
		self.hopLimit = hopLimit
		self.origin = origin
		self.destination = destination
		self.payload = payload
	}

	func encoded() -> Data {
		var writer = ByteWriter(capacity: Self.headerSize + payload.count)
		writer.bytes(Self.magic)
		writer.uint8(Self.version)
		writer.uint8(kind.rawValue)
		writer.uint8(hopLimit)
		writer.uuid(origin)
		writer.uuid(destination)
		writer.data(payload)
		return writer.data
	}

	/// Returns nil for malformed or unsupported data.
	init?(_ data: Data) {
		var reader = ByteReader(data)
		guard reader.bytes(2).map(Array.init) == Self.magic,
			reader.uint8() == Self.version,
			let kind = reader.uint8().flatMap(Kind.init(rawValue:)),
			let hopLimit = reader.uint8(),
			let origin = reader.uuid(),
			let destination = reader.uuid()
		else { return nil }
		self.init(kind: kind, hopLimit: hopLimit, origin: origin, destination: destination, payload: reader.rest())
	}

	/// The same frame one hop further.
	func forwarded() -> RelayEnvelope {
		var copy = self
		copy.hopLimit = hopLimit > 0 ? hopLimit - 1 : 0
		return copy
	}
}

/// A device's link state, flooded through the network: who it is and which devices it is directly
/// linked to.
///
/// Layout: epoch (UInt64), seq (UInt64), flags (UInt8), neighbour count (UInt8), neighbour UUIDs,
/// name (UInt16 length-prefixed UTF-8), info (binary property list, rest of the payload).
struct RelayHello: Sendable, Equatable {

	struct Flags: OptionSet, Sendable, Hashable {
		let rawValue: UInt8
		/// The device has its bridge slot free (diagnostics).
		static let bridgeSlotFree = Flags(rawValue: 1 << 0)
		/// The device has no regular slot free: reachable devices don't invite it (it would decline).
		/// Set rather than "free", so a device without a link policy is never taken for full.
		static let regularSlotsFull = Flags(rawValue: 1 << 1)
	}

	/// Orders the hellos of one origin: epoch first (set at each start), then seq.
	struct Version: Sendable, Hashable, Comparable {
		let epoch: UInt64
		let seq: UInt64

		static func < (lhs: Version, rhs: Version) -> Bool {
			(lhs.epoch, lhs.seq) < (rhs.epoch, rhs.seq)
		}
	}

	let name: String
	let info: [String: String]
	let version: Version
	/// Directly linked devices, sorted by UUID string.
	let neighbours: [UUID]
	let flags: Flags

	init(name: String, info: [String: String], version: Version, neighbours: [UUID], flags: Flags = []) {
		self.name = name
		self.info = info
		self.version = version
		self.neighbours = neighbours
		self.flags = flags
	}

	func encoded() -> Data {
		let name = Data(self.name.utf8.prefix(Int(UInt16.max)))
		let encoder = PropertyListEncoder()
		encoder.outputFormat = .binary
		// [String: String] always encodes
		let plist = (try? encoder.encode(info)) ?? Data()
		let neighbours = self.neighbours.prefix(Int(UInt8.max))
		var writer = ByteWriter(capacity: 8 + 8 + 1 + 1 + 16 * neighbours.count + 2 + name.count + plist.count)
		writer.uint64(version.epoch)
		writer.uint64(version.seq)
		writer.uint8(flags.rawValue)
		writer.uint8(UInt8(neighbours.count))
		neighbours.forEach { writer.uuid($0) }
		writer.uint16(UInt16(name.count))
		writer.data(name)
		writer.data(plist)
		return writer.data
	}

	/// The version of an encoded hello without decoding the rest; nil if too short.
	static func version(of data: Data) -> Version? {
		var reader = ByteReader(data)
		guard let epoch = reader.uint64(), let seq = reader.uint64() else { return nil }
		return Version(epoch: epoch, seq: seq)
	}

	/// Returns nil for malformed data.
	init?(_ data: Data) {
		var reader = ByteReader(data)
		guard let epoch = reader.uint64(),
			let seq = reader.uint64(),
			let flags = reader.uint8(),
			let count = reader.uint8()
		else { return nil }
		var neighbours: [UUID] = []
		for _ in 0 ..< count {
			guard let id = reader.uuid() else { return nil }
			neighbours.append(id)
		}
		guard let length = reader.uint16(),
			let nameData = reader.bytes(Int(length)),
			let name = String(data: nameData, encoding: .utf8),
			let info = try? PropertyListDecoder().decode([String: String].self, from: reader.rest())
		else { return nil }
		self.init(name: name, info: info, version: Version(epoch: epoch, seq: seq), neighbours: neighbours, flags: Flags(rawValue: flags))
	}
}
