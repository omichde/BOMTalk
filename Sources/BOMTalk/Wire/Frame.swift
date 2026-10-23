//
//  Frame.swift
//  BOMTalk
//

import Foundation

/// A single unit on the wire, hand-written binary format.
///
/// Header: magic `"BT"`, format version, frame type, followed by type specific fields.
/// Integers are big-endian, UUIDs are 16 raw bytes, strings are UInt16 length-prefixed UTF-8.
enum Frame: Sendable, Equatable {

	struct Offer: Sendable, Equatable {
		let transferID: UUID
		let kind: String
		/// Compressed payload size in bytes.
		let totalBytes: UInt64
		let chunkCount: UInt32
	}

	case offer(Offer)
	case accept(UUID)
	case reject(UUID)
	case chunk(transferID: UUID, index: UInt32, payload: Data)
	case info([String: String])

	static let version: UInt8 = 1
	/// Maximum payload bytes per chunk frame.
	static let maxChunkPayload = 64 * 1024
	static let headerSize = 4

	fileprivate static let magic: [UInt8] = [0x42, 0x54]	// "BT"

	fileprivate enum TypeCode: UInt8 {
		case offer = 1, accept, reject, chunk, info
	}

	// MARK: encoding

	func encoded() -> Data {
		switch self {
		case .offer(let offer):
			let kind = Data(offer.kind.utf8.prefix(Int(UInt16.max)))
			var writer = Writer(.offer, capacity: 16 + 2 + kind.count + 8 + 4)
			writer.uuid(offer.transferID)
			writer.uint16(UInt16(kind.count))
			writer.data(kind)
			writer.uint64(offer.totalBytes)
			writer.uint32(offer.chunkCount)
			return writer.data
		case .accept(let id):
			var writer = Writer(.accept, capacity: 16)
			writer.uuid(id)
			return writer.data
		case .reject(let id):
			var writer = Writer(.reject, capacity: 16)
			writer.uuid(id)
			return writer.data
		case .chunk(let id, let index, let payload):
			var writer = Writer(.chunk, capacity: 16 + 4 + payload.count)
			writer.uuid(id)
			writer.uint32(index)
			writer.data(payload)
			return writer.data
		case .info(let info):
			let encoder = PropertyListEncoder()
			encoder.outputFormat = .binary
			// [String: String] always encodes
			let plist = (try? encoder.encode(info)) ?? Data()
			var writer = Writer(.info, capacity: plist.count)
			writer.data(plist)
			return writer.data
		}
	}

	// MARK: decoding

	/// Returns nil for malformed or unsupported data.
	init?(_ data: Data) {
		var reader = Reader(data)
		guard reader.bytes(2).map(Array.init) == Self.magic,
			reader.uint8() == Self.version,
			let code = reader.uint8().flatMap(TypeCode.init(rawValue:))
		else { return nil }

		switch code {
		case .offer:
			guard let id = reader.uuid(),
				let length = reader.uint16(),
				let kindData = reader.bytes(Int(length)),
				let kind = String(data: kindData, encoding: .utf8),
				let totalBytes = reader.uint64(),
				let chunkCount = reader.uint32(),
				reader.isAtEnd
			else { return nil }
			self = .offer(Offer(transferID: id, kind: kind, totalBytes: totalBytes, chunkCount: chunkCount))
		case .accept:
			guard let id = reader.uuid(), reader.isAtEnd else { return nil }
			self = .accept(id)
		case .reject:
			guard let id = reader.uuid(), reader.isAtEnd else { return nil }
			self = .reject(id)
		case .chunk:
			guard let id = reader.uuid(), let index = reader.uint32() else { return nil }
			let payload = reader.rest()
			guard payload.count <= Self.maxChunkPayload else { return nil }
			self = .chunk(transferID: id, index: index, payload: payload)
		case .info:
			guard let info = try? PropertyListDecoder().decode([String: String].self, from: reader.rest()) else { return nil }
			self = .info(info)
		}
	}
}

// MARK: - byte helpers

private struct Writer {
	private(set) var data: Data

	/// Writes the header; `capacity` is the size of the fields following it.
	init(_ type: Frame.TypeCode, capacity: Int) {
		data = Data(capacity: Frame.headerSize + capacity)
		bytes(Frame.magic)
		uint8(Frame.version)
		uint8(type.rawValue)
	}

	mutating func bytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
	mutating func data(_ other: Data) { data.append(other) }
	mutating func uint8(_ value: UInt8) { data.append(value) }
	mutating func uint16(_ value: UInt16) { integer(value) }
	mutating func uint32(_ value: UInt32) { integer(value) }
	mutating func uint64(_ value: UInt64) { integer(value) }
	mutating func uuid(_ value: UUID) { withUnsafeBytes(of: value.uuid) { data.append(contentsOf: $0) } }

	private mutating func integer<T: FixedWidthInteger>(_ value: T) {
		withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
	}
}

private struct Reader {
	private let data: Data
	private var offset: Data.Index

	init(_ data: Data) {
		self.data = data
		offset = data.startIndex
	}

	var isAtEnd: Bool { offset == data.endIndex }

	mutating func bytes(_ count: Int) -> Data? {
		guard count >= 0, data.endIndex - offset >= count else { return nil }
		defer { offset += count }
		return data[offset ..< offset + count]
	}

	mutating func rest() -> Data {
		defer { offset = data.endIndex }
		return Data(data[offset...])
	}

	mutating func uint8() -> UInt8? { bytes(1)?.first }
	mutating func uint16() -> UInt16? { integer() }
	mutating func uint32() -> UInt32? { integer() }
	mutating func uint64() -> UInt64? { integer() }

	mutating func uuid() -> UUID? {
		bytes(16).map { bytes in UUID(uuid: bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }) }
	}

	private mutating func integer<T: FixedWidthInteger>() -> T? {
		bytes(MemoryLayout<T>.size).map { $0.reduce(T.zero) { $0 << 8 | T($1) } }
	}
}
