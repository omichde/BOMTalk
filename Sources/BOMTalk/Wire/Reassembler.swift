//
//  Reassembler.swift
//  BOMTalk
//

import Foundation

/// Collects the chunks of incoming transfers, in any order, and fails transfers that stall.
/// Transfers are keyed per (peer, transfer id): chunks from any other peer are ignored.
/// Says when to acknowledge (`FlowControl.ackInterval`, and repeated while no chunk arrives,
/// `FlowControl.ackRepeat`); the caller sends the acks. Acks cover the contiguous prefix of chunks
/// only: a chunk lost on the way (no retransmission) freezes them, so the sender's window fills and
/// both ends time out, instead of the transfer creeping on with a hole it can never fill.
@MainActor
final class Reassembler {

	enum Outcome {
		/// Unknown transfer, wrong peer, duplicate, out of range index or too many bytes.
		case ignored
		/// Stored; `acknowledge` is the prefix byte count to acknowledge now, if an ack is due.
		case progressed(acknowledge: UInt64?)
		/// All chunks arrived, the transfer was removed. Acknowledge `totalBytes`.
		case completed(Transfer, payload: Data)
		/// A chunk of a transfer completed within the timeout: the sender probes for a lost final ack,
		/// acknowledge `totalBytes` again.
		case repeated(acknowledge: UInt64)
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
		/// Chunks 0 ..< `prefixChunks` all arrived, `prefixBytes` in total.
		var prefixChunks = 0
		var prefixBytes = 0
		var acknowledgedBytes = 0
		/// Last chunk (or the start), on `timers`.
		var lastChunk: Duration
		var watchdog: TimerToken?
	}

	/// Called when a transfer did not receive a chunk within `timeout`, the transfer was removed.
	var onTimeout: ((Transfer) -> Void)?
	/// Called when a transfer received no chunk for `FlowControl.ackRepeat`: acknowledge the prefix
	/// again (the last ack may have been lost).
	var onRepeatAck: ((Transfer, _ prefixBytes: UInt64) -> Void)?
	private let timeout: Duration
	private let timers: any Timers
	private var entries: [Key: Entry] = [:]
	/// Completed transfers, their size and when, kept for `timeout` to answer final ack probes.
	private var completed: [Key: (totalBytes: Int, at: Duration)] = [:]

	init(timeout: Duration, timers: any Timers) {
		self.timeout = timeout
		self.timers = timers
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
		entries[key] = Entry(transfer: transfer, chunkCount: chunkCount, totalBytes: totalBytes, lastChunk: timers.now)
		watch(key)
	}

	func add(_ payload: Data, index: Int, to id: UUID, from peer: UUID) -> Outcome {
		let key = Key(peer: peer, id: id)
		if entries[key] == nil, let done = completed[key], timers.now - done.at < timeout {
			return .repeated(acknowledge: UInt64(done.totalBytes))
		}
		guard var entry = entries[key],
			0 ..< entry.chunkCount ~= index,
			entry.chunks[index] == nil,
			entry.receivedBytes + payload.count <= entry.totalBytes
		else { return .ignored }
		entry.chunks[index] = payload
		entry.receivedBytes += payload.count
		while let chunk = entry.chunks[entry.prefixChunks] {
			entry.prefixChunks += 1
			entry.prefixBytes += chunk.count
		}
		entry.lastChunk = timers.now
		entry.transfer.completedBytes += payload.count
		guard entry.chunks.count == entry.chunkCount else {
			var acknowledge: UInt64?
			if entry.prefixBytes - entry.acknowledgedBytes >= FlowControl.ackInterval {
				entry.acknowledgedBytes = entry.prefixBytes
				acknowledge = UInt64(entry.prefixBytes)
			}
			entries[key] = entry
			return .progressed(acknowledge: acknowledge)
		}
		entry.watchdog?.cancel()
		entries[key] = nil
		let now = timers.now
		completed = completed.filter { now - $0.value.at < timeout }
		guard entry.receivedBytes == entry.totalBytes else {
			return .failed(entry.transfer, .decodingFailed)
		}
		completed[key] = (entry.totalBytes, now)
		var data = Data(capacity: entry.receivedBytes)
		for index in 0 ..< entry.chunkCount {
			data.append(entry.chunks[index] ?? Data())	// all present, see the count check above
		}
		return .completed(entry.transfer, payload: data)
	}

	/// Drops all transfers from a peer, partial data is discarded.
	func drop(peer: UUID) -> [Transfer] {
		completed = completed.filter { $0.key.peer != peer }
		return entries.keys.filter { $0.peer == peer }.compactMap(drop)
	}

	/// Drops all transfers, partial data is discarded.
	func dropAll() -> [Transfer] {
		completed = [:]
		return entries.keys.compactMap(drop)
	}

	private func drop(_ key: Key) -> Transfer? {
		guard let entry = entries.removeValue(forKey: key) else { return nil }
		entry.watchdog?.cancel()
		return entry.transfer
	}

	/// One timer per transfer, ticking every `ackRepeat` and exactly at the timeout.
	private func watch(_ key: Key) {
		let delay = min(FlowControl.ackRepeat, timeout - (entries[key].map { timers.now - $0.lastChunk } ?? .zero))
		entries[key]?.watchdog = timers.schedule(after: delay) { [weak self] in
			guard let self, let entry = entries[key] else { return }
			let silent = timers.now - entry.lastChunk
			guard silent < timeout else { return expire(key) }
			if silent >= FlowControl.ackRepeat && entry.prefixBytes > 0 {
				entries[key]?.acknowledgedBytes = entry.prefixBytes
				onRepeatAck?(entry.transfer, UInt64(entry.prefixBytes))
			}
			watch(key)
		}
	}

	private func expire(_ key: Key) {
		guard let transfer = drop(key) else { return }
		onTimeout?(transfer)
	}
}
