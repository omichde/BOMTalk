//
//  Scheduler.swift
//  BOMTalk
//

import Foundation

/// Sends the chunks of all outgoing transfers round-robin, so a small message is not stuck
/// behind a large one. Yields between chunks to keep the main actor responsive.
@MainActor
final class Scheduler {

	typealias Send = @MainActor (Data, UUID) throws(TalkError) -> Void

	private final class Job {
		let id: UUID
		let peer: UUID
		let payload: Data
		let chunkCount: Int
		let transfer: Transfer
		let continuation: CheckedContinuation<Result<Void, TalkError>, Never>
		var next = 0

		init(payload: Data, transfer: Transfer, continuation: CheckedContinuation<Result<Void, TalkError>, Never>) {
			self.id = transfer.id
			self.peer = transfer.peer
			self.payload = payload
			self.chunkCount = Scheduler.chunkCount(for: payload.count)
			self.transfer = transfer
			self.continuation = continuation
		}
	}

	private let send: Send
	private var jobs: [Job] = []
	private var cursor = 0
	private var pump: Task<Void, Never>?

	init(send: @escaping Send) {
		self.send = send
	}

	/// At least one chunk, also for an empty payload. Overflow-free for any (hostile) size.
	nonisolated static func chunkCount(for byteCount: Int) -> Int {
		byteCount <= 0 ? 1 : (byteCount - 1) / Frame.maxChunkPayload + 1
	}

	/// Returns once the last chunk was handed to `send`.
	func transmit(_ payload: Data, to transfer: Transfer) async throws(TalkError) {
		let result = await withCheckedContinuation { continuation in
			jobs.append(Job(payload: payload, transfer: transfer, continuation: continuation))
			if pump == nil {
				pump = Task { [weak self] in await self?.drain() }
			}
		}
		try result.get()
	}

	/// Fails all jobs matching `predicate` (single failure path, also the future cancel hook).
	func fail(_ error: TalkError, where predicate: (_ id: UUID, _ peer: UUID) -> Bool) {
		for job in jobs where predicate(job.id, job.peer) {
			finish(job, .failure(error))
		}
	}

	private func drain() async {
		while !jobs.isEmpty {
			cursor %= jobs.count
			step(jobs[cursor])
			await Task.yield()
		}
		pump = nil
	}

	private func step(_ job: Job) {
		let start = job.next * Frame.maxChunkPayload
		let end = min(start + Frame.maxChunkPayload, job.payload.count)
		let range = job.payload.startIndex + start ..< job.payload.startIndex + end
		let frame = Frame.chunk(transferID: job.id, index: UInt32(job.next), payload: job.payload[range])
		do {
			try send(frame.encoded(), job.peer)
		} catch {
			finish(job, .failure(error))
			return
		}
		job.next += 1
		job.transfer.completedBytes += end - start
		if job.next == job.chunkCount {
			finish(job, .success(()))
		} else {
			cursor += 1
		}
	}

	private func finish(_ job: Job, _ result: Result<Void, TalkError>) {
		guard let index = jobs.firstIndex(where: { $0 === job }) else { return }
		jobs.remove(at: index)
		if index < cursor {
			cursor -= 1
		}
		job.continuation.resume(returning: result)
	}
}
