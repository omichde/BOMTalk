//
//  ManualTimers.swift
//  BOMTalkTests
//

import Foundation
@testable import BOMTalk

/// Virtual time: nothing fires until `advance(by:)`, which runs due work synchronously in deadline
/// order (ties in scheduling order), including work scheduled by fired work inside the window.
@MainActor
final class ManualTimers: Timers {

	private struct Entry {
		let deadline: Duration
		let sequence: Int
		let work: @MainActor () -> Void
	}

	private(set) var now: Duration = .zero
	/// Sorted by deadline, then sequence.
	private var entries: [Entry] = []
	private var sequence = 0

	/// Scheduled and not yet fired or cancelled.
	var pendingCount: Int { entries.count }

	/// Work due at `now` that has not run yet.
	var hasDue: Bool { entries.first.map { $0.deadline <= now } ?? false }

	@discardableResult
	func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> TimerToken {
		sequence += 1
		let entry = Entry(deadline: now + max(delay, .zero), sequence: sequence, work: work)
		// first index with a later deadline: equal deadlines keep scheduling order
		var low = 0, high = entries.count
		while low < high {
			let mid = (low + high) / 2
			if entries[mid].deadline <= entry.deadline {
				low = mid + 1
			} else {
				high = mid
			}
		}
		entries.insert(entry, at: low)
		let id = entry.sequence
		return TimerToken { [weak self] in
			self?.entries.removeAll { $0.sequence == id }
		}
	}

	/// Moves time forward, firing everything due on the way. Returns the number of fired timers.
	@discardableResult
	func advance(by duration: Duration) -> Int {
		precondition(duration >= .zero, "time only moves forward")
		let end = now + duration
		var fired = 0
		while let first = entries.first, first.deadline <= end {
			entries.removeFirst()
			now = first.deadline
			first.work()
			fired += 1
		}
		now = end
		return fired
	}
}
