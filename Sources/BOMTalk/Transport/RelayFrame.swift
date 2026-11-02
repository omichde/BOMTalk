//
//  RelayFrame.swift
//  BOMTalk
//

import Foundation

/// Wraps every frame between neighbours, hand-written binary format like `Frame`.
///
/// Header (37 bytes): magic `"BR"`, format version, type, hop limit, origin UUID, destination UUID,
/// followed by the payload: a Talk frame (`data`), a `RelayHello` (`hello`, destination all-zero) or
/// nothing (`unlink` and `keepalive` to a direct neighbour, `recordRequest` routed to the origin of
/// the hello whose record is missing).
struct RelayEnvelope: Sendable, Equatable {

	enum Kind: UInt8, Sendable {
		case data = 1, hello
		/// The sender drops the direct link on purpose (redundant): the receiver disconnects and
		/// neither side links again while they reach each other via relay.
		case unlink
		/// Sent to a direct neighbour that got nothing else for `RelayPolicy.keepaliveInterval`, so
		/// link liveness does not depend on the hello interval.
		case keepalive
		/// Asks the destination for a hello with its name and info (`RelayHello.Record`): the sender
		/// knows a hello of it whose record it does not have.
		case recordRequest
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

/// A device's link state, flooded through the network: which devices it is directly linked to and,
/// only when needed, who it is (name and info).
///
/// Layout: epoch (UInt64), seq (UInt64), flags (UInt8, bit 7: a record follows), interval (UInt8,
/// 100 ms units), info version (UInt32), neighbour count (UInt8), neighbour UUIDs; with a record: name
/// (UInt16 length-prefixed UTF-8), info (binary property list, rest of the payload).
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

	/// Who the device is. Travels only when it changed, on request and in map sync.
	struct Record: Sendable, Equatable {
		let name: String
		let info: [String: String]
	}

	/// Identifies a record: the info version counts per run, so the epoch is part of it.
	struct RecordKey: Sendable, Hashable {
		let epoch: UInt64
		let infoVersion: UInt32
	}

	let version: Version
	/// Directly linked devices, sorted by UUID string.
	let neighbours: [UUID]
	let flags: Flags
	/// Base interval until the origin's next periodic hello (jitter on top), whole 100 ms; receivers
	/// expire the entry after `RelayPolicy.expiry(interval:)`.
	let interval: Duration
	/// Changes whenever the origin's name or info change.
	let infoVersion: UInt32
	/// Name and info, nil in most periodic hellos.
	let record: Record?

	private static let recordBit: UInt8 = 1 << 7
	private static let intervalUnit: Duration = .milliseconds(100)
	/// Offset of the flags byte.
	private static let flagsOffset = 16

	init(version: Version, neighbours: [UUID], flags: Flags = [], interval: Duration, infoVersion: UInt32, record: Record? = nil) {
		self.version = version
		self.neighbours = neighbours
		self.flags = flags
		self.interval = Self.intervalUnit * Int(Self.units(of: interval))
		self.infoVersion = infoVersion
		self.record = record
	}

	var recordKey: RecordKey {
		RecordKey(epoch: version.epoch, infoVersion: infoVersion)
	}

	/// The same hello with or without its record.
	func with(record: Record?) -> RelayHello {
		RelayHello(version: version, neighbours: neighbours, flags: flags, interval: interval, infoVersion: infoVersion, record: record)
	}

	func encoded() -> Data {
		let neighbours = self.neighbours.prefix(Int(UInt8.max))
		var name = Data(), plist = Data()
		if let record {
			name = Data(record.name.utf8.prefix(Int(UInt16.max)))
			let encoder = PropertyListEncoder()
			encoder.outputFormat = .binary
			// [String: String] always encodes
			plist = (try? encoder.encode(record.info)) ?? Data()
		}
		var writer = ByteWriter(capacity: 8 + 8 + 1 + 1 + 4 + 1 + 16 * neighbours.count + (record == nil ? 0 : 2 + name.count + plist.count))
		writer.uint64(version.epoch)
		writer.uint64(version.seq)
		writer.uint8(flags.rawValue & ~Self.recordBit | (record == nil ? 0 : Self.recordBit))
		writer.uint8(Self.units(of: interval))
		writer.uint32(infoVersion)
		writer.uint8(UInt8(neighbours.count))
		neighbours.forEach { writer.uuid($0) }
		if record != nil {
			writer.uint16(UInt16(name.count))
			writer.data(name)
			writer.data(plist)
		}
		return writer.data
	}

	/// The version of an encoded hello without decoding the rest; nil if too short.
	static func version(of data: Data) -> Version? {
		var reader = ByteReader(data)
		guard let epoch = reader.uint64(), let seq = reader.uint64() else { return nil }
		return Version(epoch: epoch, seq: seq)
	}

	/// Whether an encoded hello carries a record, without decoding it.
	static func hasRecord(_ data: Data) -> Bool {
		data.count > flagsOffset && data[data.startIndex + flagsOffset] & recordBit != 0
	}

	/// Returns nil for malformed data.
	init?(_ data: Data) {
		var reader = ByteReader(data)
		guard let epoch = reader.uint64(),
			let seq = reader.uint64(),
			let flags = reader.uint8(),
			let units = reader.uint8(), units > 0,
			let infoVersion = reader.uint32(),
			let count = reader.uint8()
		else { return nil }
		var neighbours: [UUID] = []
		for _ in 0 ..< count {
			guard let id = reader.uuid() else { return nil }
			neighbours.append(id)
		}
		var record: Record?
		if flags & Self.recordBit != 0 {
			guard let length = reader.uint16(),
				let nameData = reader.bytes(Int(length)),
				let name = String(data: nameData, encoding: .utf8),
				let info = try? PropertyListDecoder().decode([String: String].self, from: reader.rest())
			else { return nil }
			record = Record(name: name, info: info)
		} else {
			guard reader.rest().isEmpty else { return nil }
		}
		self.init(version: Version(epoch: epoch, seq: seq), neighbours: neighbours, flags: Flags(rawValue: flags & ~Self.recordBit), interval: Self.intervalUnit * Int(units), infoVersion: infoVersion, record: record)
	}

	/// The interval in whole units, 1 … 255.
	private static func units(of interval: Duration) -> UInt8 {
		UInt8(min(255, max(1, (interval / intervalUnit).rounded())))
	}
}
