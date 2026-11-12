//
//  Timers.swift
//  BOMTalk
//

import Foundation

/// Schedules work on the main actor after a delay. Injectable, so tests can run on virtual time.
@MainActor
protocol Timers: AnyObject {
	/// Monotonic time since an arbitrary origin.
	var now: Duration { get }
	/// Runs `work` once after `delay`, unless the returned token is cancelled first.
	@discardableResult
	func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> TimerToken
}

/// Cancels a scheduled timer. Cancelling twice or after the timer fired does nothing.
@MainActor
final class TimerToken {

	private var onCancel: (@MainActor () -> Void)?

	init(onCancel: @escaping @MainActor () -> Void) {
		self.onCancel = onCancel
	}

	func cancel() {
		let onCancel = onCancel
		self.onCancel = nil
		onCancel?()
	}
}

/// Production timers: one task per timer, sleeping on the continuous clock.
@MainActor
final class TaskTimers: Timers {

	private let origin = ContinuousClock.now

	var now: Duration { ContinuousClock.now - origin }

	@discardableResult
	func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> TimerToken {
		let task = Task {
			guard (try? await Task.sleep(for: delay)) != nil else { return }	// cancelled
			work()
		}
		return TimerToken { task.cancel() }
	}
}
