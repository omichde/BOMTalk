//
//  RadioHealth.swift
//  BOMTalk
//

import Foundation

/// Decides when `LinkTransport` should tear its radio down and start it fresh. Pure bookkeeping, fed
/// with the transport events the peer machine emits.
///
/// Simulator rig runs: after an abrupt loss of a neighbour, one device's `MCSession` could stay
/// wedged for minutes; every attempt of that device, in both directions and with every peer, hung
/// until the watchdog, while all other devices connected among themselves. Nothing BOMTalk sends
/// helps then, but a fresh session (and peer id) does.
///
/// - **Failure**: an attempt that ended without connecting after `RadioResetPolicy.slowFailure` or
///   more (watchdog, invitation timeout: a quick decline proves the radio works and does not count),
///   or a link that died younger than `RadioResetPolicy.healthyLinkAge` (half open, or connected and
///   then silent until the stall detector cut it).
/// - **Success**: data on a link at least `healthyLinkAge` old. Clears the failures and the backoff,
///   but not while bridge candidates exist: an old link proves nothing about new ones.
/// - **Reset** once `RadioResetPolicy.failures` failures with at least `distinctPeers` peers fell
///   into `window`, while some peer is visible and no link connected or carried data within
///   `liveness`; after a reset the next one waits `backoff` (60 s, 120 s, … 5 min) until a success.
/// - **Reset while linked**, the same count over failures with current bridge candidates only, when
///   the device is cut off from devices it sees (the relay's `LinkPolicy`): at once if its partition
///   is the smaller side (`outnumbered`), otherwise once the split lasted `isolationLimit`. Rig run
///   (heal, cap 2, third round): the relay of a pair went dark, both ends of the pair were left
///   wedged and linked to each other; every accepted attempt with the others hung and the working
///   link kept both from resetting, for good. The smaller side goes first because the wedge is
///   most likely there (its members just lost the relay abruptly); the larger side follows only if
///   that does not help, so a healthy majority does not reset for a wedged few.
struct RadioHealth {

	private struct Link {
		let connectedAt: Duration
		var lastData: Duration?
	}

	private struct Failure {
		let at: Duration
		let peer: UUID
	}

	/// Pending attempts and since when.
	private var attempts: [UUID: Duration] = [:]
	private var links: [UUID: Link] = [:]
	private var failures: [Failure] = []
	private var lastReset: Duration?
	/// Resets since the last success.
	private var resetsInRow = 0
	/// Resets since creation.
	private(set) var resets = 0
	/// From the relay's link policy: visible devices it cannot reach, whether its side is the smaller
	/// one, and since when there are any.
	private var bridgeCandidates: Set<UUID> = []
	private var outnumbered = false
	private var isolatedSince: Duration?

	/// Applies an event of the peer machine; true if it was a failure (time to ask `shouldReset`).
	mutating func observe(_ event: TransportEvent, at now: Duration) -> Bool {
		switch event {
		case let .connecting(id):
			attempts[id] = now
		case let .connected(peer):
			attempts[peer.id] = nil
			links[peer.id] = Link(connectedAt: now)
		case let .received(_, id):
			guard let link = links[id] else { break }
			links[id]?.lastData = now
			if now - link.connectedAt >= RadioResetPolicy.healthyLinkAge, bridgeCandidates.isEmpty {
				failures = []
				resetsInRow = 0
			}
		case let .disconnected(id):
			if let link = links.removeValue(forKey: id) {
				attempts[id] = nil
				return fail(id, if: now - link.connectedAt < RadioResetPolicy.healthyLinkAge, at: now)
			}
			if let since = attempts.removeValue(forKey: id) {
				return fail(id, if: now - since >= RadioResetPolicy.slowFailure, at: now)
			}
		case let .lost(id):
			attempts[id] = nil
			links[id] = nil
		case .found, .failed:
			break
		}
		return false
	}

	/// The relay's view: who is visible but unreachable, and whether this device is on the smaller side.
	mutating func observe(_ policy: LinkPolicy, at now: Duration) {
		bridgeCandidates = policy.bridgeCandidates
		outnumbered = policy.outnumbered
		isolatedSince = bridgeCandidates.isEmpty ? nil : isolatedSince ?? now
	}

	/// Whether the radio looks wedged and a reset is allowed now.
	/// - Parameter peersVisible: Whether the browser sees any compatible peer at all.
	func shouldReset(at now: Duration, peersVisible: Bool) -> Bool {
		guard peersVisible, isWedgedAlone(at: now) || isWedgedApart(at: now) else { return false }
		guard let lastReset else { return true }
		return now - lastReset >= RadioResetPolicy.backoff(resetsInRow: resetsInRow)
	}

	/// No link works and attempts with several peers failed.
	private func isWedgedAlone(at now: Duration) -> Bool {
		// a link that is up and alive (or just came up) says the radio works
		guard !links.values.contains(where: { now - ($0.lastData ?? $0.connectedAt) < RadioResetPolicy.liveness }) else { return false }
		return enough(failures, at: now)
	}

	/// Cut off from devices it sees, and attempts with several of them failed, links or not.
	private func isWedgedApart(at now: Duration) -> Bool {
		guard let isolatedSince, outnumbered || now - isolatedSince >= RadioResetPolicy.isolationLimit else { return false }
		return enough(failures.filter { bridgeCandidates.contains($0.peer) }, at: now)
	}

	private func enough(_ failures: [Failure], at now: Duration) -> Bool {
		let recent = failures.filter { now - $0.at < RadioResetPolicy.window }
		return recent.count >= RadioResetPolicy.failures && Set(recent.map(\.peer)).count >= RadioResetPolicy.distinctPeers
	}

	/// The radio was reset: everything before it belonged to the old session.
	mutating func didReset(at now: Duration) {
		attempts = [:]
		links = [:]
		failures = []
		lastReset = now
		resetsInRow += 1
		resets += 1
	}

	/// The transport stopped: a later start begins without history (the reset count stays).
	mutating func restart() {
		attempts = [:]
		links = [:]
		failures = []
		lastReset = nil
		resetsInRow = 0
		bridgeCandidates = []
		outnumbered = false
		isolatedSince = nil
	}

	private mutating func fail(_ id: UUID, if counts: Bool, at now: Duration) -> Bool {
		guard counts else { return false }
		failures.append(Failure(at: now, peer: id))
		failures.removeAll { now - $0.at >= RadioResetPolicy.window }
		return true
	}
}

/// When a wedged radio is reset, see `RadioHealth`.
enum RadioResetPolicy {

	/// Failed attempts or young link deaths within `window` …
	static let failures = 3
	/// … with at least this many different peers (one peer that hangs is that peer's problem) …
	static let distinctPeers = 2
	/// … within this window. With a link cap of 2 a device has only one own invitation pending at a
	/// time, so three watchdog expiries take 40 s; 60 s leaves room for backoff in between.
	static let window: Duration = .seconds(60)
	/// An attempt that failed this long after it began counts (watchdog 20 s, invitation timeout
	/// 15 s); quicker answers (declines, a full session) prove the radio works.
	static let slowFailure: Duration = .seconds(10)
	/// A link dying younger than this counts as failure; data on an older one is a success. Longer
	/// than a stalled link takes to be cut (silent 15 s, rig runs: cut at 15–21 s) and equal to the
	/// relay's minimum age for a voluntary drop, so a drop never counts.
	static let healthyLinkAge: Duration = .seconds(30)
	/// No reset while a link connected or carried data this recently (the relay's liveness window),
	/// unless the device is cut off from others it sees …
	static let liveness: Duration = RelayPolicy.helloExpiry
	/// … and on the smaller side, or the split lasted this long: longer than any healthy merge takes
	/// (sim, 30 % hanging invitations at cap 2: converged within 43 s), and enough for the smaller
	/// side to reset first (its failures take up to 60 s).
	static let isolationLimit: Duration = .seconds(120)
	/// Delay between consecutive resets without a success in between; the first one is not delayed.
	static let backoffSteps: [Duration] = [.seconds(60), .seconds(120), .seconds(240), .seconds(300)]
	/// Between stopping the radio and starting it again, so MPC can tear the old session down.
	static let pause: Duration = .seconds(1)

	static func backoff(resetsInRow: Int) -> Duration {
		resetsInRow <= 0 ? .zero : backoffSteps[min(resetsInRow, backoffSteps.count) - 1]
	}
}
