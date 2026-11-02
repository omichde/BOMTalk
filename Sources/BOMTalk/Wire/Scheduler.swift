//
//  Scheduler.swift
//  BOMTalk
//

import Foundation

/// Sends the chunks of all outgoing transfers round-robin, so a small message is not stuck
/// behind a large one. Yields between chunks to keep the main actor responsive.
///
/// Flow control (`FlowControl`): each transfer keeps at most `window` unacknowledged bytes in
/// flight; round-robin skips transfers with a full window, and with every window full the pump
/// suspends until an ack arrives or a transfer is added or failed. A transfer succeeds once the
/// receiver acknowledged all bytes, and fails with `.timeout` when its acknowledged bytes do not
/// advance for `timeout` (receiver gone, data lost at a dead relay). Without a final ack the last
/// chunk is sent again every `FlowControl.finalAckProbe`, in case only the ack was lost.
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
		/// Next chunk to send.
		var next = 0
		/// Bytes handed to `send`.
		var sentBytes = 0
		/// Bytes the receiver acknowledged.
		var acknowledgedBytes = 0
		/// Last advance of `acknowledgedBytes` (or the start), on `timers`.
		var lastProgress: Duration
		/// Since `lastProgress`: the last final ack probe, or when the last chunk was handed off.
		var lastProbe: Duration?
		var watchdog: TimerToken?

		init(payload: Data, transfer: Transfer, continuation: CheckedContinuation<Result<Void, TalkError>, Never>, now: Duration) {
			self.id = transfer.id
			self.peer = transfer.peer
			self.payload = payload
			self.chunkCount = Scheduler.chunkCount(for: payload.count)
			self.transfer = transfer
			self.continuation = continuation
			self.lastProgress = now
		}

		var isFullySent: Bool { next == chunkCount }
	}

	private let send: Send
	private let timers: any Timers
	private let timeout: Duration
	private let window: Int
	private var jobs: [Job] = []
	private var cursor = 0
	private var pump: Task<Void, Never>?
	/// The pump waiting for a job to become ready.
	private var wakeup: CheckedContinuation<Void, Never>?

	/// - Parameters:
	///   - timeout: A transfer whose acknowledged bytes do not advance this long fails with `.timeout`.
	///   - window: Unacknowledged bytes per transfer, `FlowControl.window` (tests use others).
	init(timers: any Timers, timeout: Duration, window: Int = FlowControl.window, send: @escaping Send) {
		self.timers = timers
		self.timeout = timeout
		self.window = max(window, 1)
		self.send = send
	}

	isolated deinit {
		jobs.forEach { $0.watchdog?.cancel() }
	}

	/// At least one chunk, also for an empty payload. Overflow-free for any (hostile) size.
	nonisolated static func chunkCount(for byteCount: Int) -> Int {
		byteCount <= 0 ? 1 : (byteCount - 1) / Frame.maxChunkPayload + 1
	}

	/// Returns once the receiver acknowledged all bytes.
	func transmit(_ payload: Data, to transfer: Transfer) async throws(TalkError) {
		let result = await withCheckedContinuation { continuation in
			let job = Job(payload: payload, transfer: transfer, continuation: continuation, now: timers.now)
			jobs.append(job)
			watch(job)
			if pump == nil {
				pump = Task { [weak self] in await self?.drain() }
			} else {
				wake()
			}
		}
		try result.get()
	}

	/// An ack from `peer`: the receiver has the first `receivedBytes` of the transfer. Ignored for
	/// unknown or finished transfers, another peer, more bytes than sent, or fewer than acknowledged
	/// before.
	func acknowledge(_ id: UUID, receivedBytes: UInt64, from peer: UUID) {
		guard let job = jobs.first(where: { $0.id == id && $0.peer == peer }),
			let bytes = Int(exactly: receivedBytes),
			bytes <= job.sentBytes,
			bytes >= job.acknowledgedBytes
		else { return }
		if bytes > job.acknowledgedBytes {
			job.acknowledgedBytes = bytes
			job.lastProgress = timers.now
			job.lastProbe = nil
			job.transfer.completedBytes = bytes
		}
		// the final ack also completes an empty payload, where no byte ever advances
		if job.isFullySent && bytes == job.payload.count {
			finish(job, .success(()))
		} else {
			wake()
		}
	}

	/// Fails all jobs matching `predicate` (single failure path, also the future cancel hook).
	func fail(_ error: TalkError, where predicate: (_ id: UUID, _ peer: UUID) -> Bool) {
		for job in jobs where predicate(job.id, job.peer) {
			finish(job, .failure(error))
		}
	}

	private func drain() async {
		while !jobs.isEmpty {
			guard let job = nextReady() else {
				// every job waits for acks; `wake()` resumes on an ack, a new job or a failure
				await withCheckedContinuation { wakeup = $0 }
				continue
			}
			step(job)
			await Task.yield()
		}
		pump = nil
	}

	/// Round-robin from the cursor: the first job with chunks left and room in its window.
	private func nextReady() -> Job? {
		for offset in 0 ..< jobs.count {
			let index = (cursor + offset) % jobs.count
			let job = jobs[index]
			let chunk = min(Frame.maxChunkPayload, job.payload.count - job.sentBytes)
			// an empty window always admits one chunk, whatever the window size
			if !job.isFullySent && (job.sentBytes == job.acknowledgedBytes || job.sentBytes + chunk - job.acknowledgedBytes <= window) {
				cursor = index
				return job
			}
		}
		return nil
	}

	private func step(_ job: Job) {
		do {
			job.sentBytes = try sendChunk(job.next, of: job)
		} catch {
			finish(job, .failure(error))
			return
		}
		job.next += 1
		cursor += 1
		if job.isFullySent {
			job.lastProbe = timers.now
			job.watchdog?.cancel()
			watch(job)	// the first probe is due before the timeout
		}
	}

	/// Returns the end offset of the chunk.
	private func sendChunk(_ index: Int, of job: Job) throws(TalkError) -> Int {
		let start = index * Frame.maxChunkPayload
		let end = min(start + Frame.maxChunkPayload, job.payload.count)
		let range = job.payload.startIndex + start ..< job.payload.startIndex + end
		let frame = Frame.chunk(transferID: job.id, index: UInt32(index), payload: job.payload[range])
		try send(frame.encoded(), job.peer)
		return end
	}

	private func wake() {
		let wakeup = wakeup
		self.wakeup = nil
		wakeup?.resume()
	}

	/// One timer per job: at the timeout (re-armed when acks arrived meanwhile) or the next final
	/// ack probe, whichever comes first.
	private func watch(_ job: Job) {
		let now = timers.now
		var due = job.lastProgress + timeout
		if job.isFullySent {
			due = min(due, (job.lastProbe ?? job.lastProgress) + FlowControl.finalAckProbe)
		}
		job.watchdog = timers.schedule(after: max(due - now, .zero)) { [weak self, weak job] in
			guard let self, let job, jobs.contains(where: { $0 === job }) else { return }
			let now = timers.now
			guard now - job.lastProgress < timeout else { return finish(job, .failure(.timeout)) }
			if job.isFullySent && now - (job.lastProbe ?? job.lastProgress) >= FlowControl.finalAckProbe {
				job.lastProbe = now
				// a failed probe changes nothing, the timeout decides
				_ = try? sendChunk(job.chunkCount - 1, of: job)
			}
			watch(job)
		}
	}

	private func finish(_ job: Job, _ result: Result<Void, TalkError>) {
		guard let index = jobs.firstIndex(where: { $0 === job }) else { return }
		jobs.remove(at: index)
		if index < cursor {
			cursor -= 1
		}
		job.watchdog?.cancel()
		job.continuation.resume(returning: result)
		wake()	// the pump ends if this was the last job
	}
}
