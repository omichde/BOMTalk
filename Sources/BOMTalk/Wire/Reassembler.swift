//
//  Reassembler.swift
//  BOMTalk
//

import Foundation

/// Collects the chunks of incoming transfers, in any order, and fails transfers that stall.
/// Transfers are keyed per (peer, transfer id): chunks from any other peer are ignored.
@MainActor
final class Reassembler {

	enum Outcome {
		/// Unknown transfer, wrong peer, duplicate, out of range index or too many bytes.
		case ignored
		case progressed
		/// All chunks arrived, the transfer was removed.
		case completed(Transfer, payload: Data)
		/// All chunks arrived but the size does not match the offer, the transfer was removed.
		case failed(Transfer, TalkError)
	}

	private struct Key: Hashable {
		let peer: UUID
		let id: UUID
	}

	private struct Entry {
		let transfer: Transfer
		let chunkCount: Int
		let totalBytes: Int
		/// Only received chunks are stored, so memory grows with the data actually received.
		var chunks: [Int: Data] = [:]
		var receivedBytes = 0
		var deadline: ContinuousClock.Instant
		var watchdog: Task<Void, Never>?
	}

	/// Called when a transfer did not receive a chunk within `timeout`, the transfer was removed.
	var onTimeout: ((Transfer) -> Void)?
	private let timeout: Duration
	private var entries: [Key: Entry] = [:]

	init(timeout: Duration) {
		self.timeout = timeout
	}

	isolated deinit {
		entries.values.forEach { $0.watchdog?.cancel() }
	}

	func contains(_ id: UUID, from peer: UUID) -> Bool {
		entries[Key(peer: peer, id: id)] != nil
	}

	/// `chunkCount` and `totalBytes` must already be validated against each other.
	func begin(_ transfer: Transfer, chunkCount: Int, totalBytes: Int) {
		let key = Key(peer: transfer.peer, id: transfer.id)
		guard entries[key] == nil else { return }
		entries[key] = Entry(transfer: transfer, chunkCount: chunkCount, totalBytes: totalBytes, deadline: .now + timeout)
		// `self` is only borrowed between sleeps, so the reassembler may go away meanwhile
		entries[key]?.watchdog = Task { [weak self] in
			while let deadline = self?.entries[key]?.deadline {
				guard ContinuousClock.now < deadline else {
					self?.expire(key)
					return
				}
				guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
			}
		}
	}

	func add(_ payload: Data, index: Int, to id: UUID, from peer: UUID) -> Outcome {
		let key = Key(peer: peer, id: id)
		guard var entry = entries[key],
			0 ..< entry.chunkCount ~= index,
			entry.chunks[index] == nil,
			entry.receivedBytes + payload.count <= entry.totalBytes
		else { return .ignored }
		entry.chunks[index] = payload
		entry.receivedBytes += payload.count
		entry.deadline = .now + timeout
		entry.transfer.completedBytes += payload.count
		guard entry.chunks.count == entry.chunkCount else {
			entries[key] = entry
			return .progressed
		}
		entry.watchdog?.cancel()
		entries[key] = nil
		guard entry.receivedBytes == entry.totalBytes else {
			return .failed(entry.transfer, .decodingFailed)
		}
		var data = Data(capacity: entry.receivedBytes)
		for index in 0 ..< entry.chunkCount {
			data.append(entry.chunks[index]!)
		}
		return .completed(entry.transfer, payload: data)
	}

	/// Drops all transfers from a peer, partial data is discarded.
	func drop(peer: UUID) -> [Transfer] {
		entries.keys.filter { $0.peer == peer }.compactMap(drop)
	}

	/// Drops all transfers, partial data is discarded.
	func dropAll() -> [Transfer] {
		entries.keys.compactMap(drop)
	}

	private func drop(_ key: Key) -> Transfer? {
		guard let entry = entries.removeValue(forKey: key) else { return nil }
		entry.watchdog?.cancel()
		return entry.transfer
	}

	private func expire(_ key: Key) {
		guard let transfer = drop(key) else { return }
		onTimeout?(transfer)
	}
}
