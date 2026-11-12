//
//  MPCPeerMachine.swift
//  BOMTalk
//

import Foundation
import MultipeerConnectivity

/// Per-peer bookkeeping of `LinkTransport` without any MPC objects: fed with browser, invitation and
/// session callbacks, it returns the actions to perform. `Handle` is `MCPeerID` in production.
///
/// Per peer the state is `idle → connecting → connected → idle`, plus visibility from the browser.
/// One device may appear with several handles (rename, relaunch): `advertised` is the latest one seen
/// by the browser and used for inviting, `session` the one the session link belongs to. Callbacks for
/// other handles are ignored, so an outdated handle can neither hide nor drop a peer.
///
/// Admission: without a `LinkPolicy` first come, first served up to `maxPeers`. With one (set by the
/// relay), `maxPeers` splits into regular and bridge slots (`LinkSlots`), counted over all pending
/// and connected peers: a regular slot for anyone not suppressed, beyond that the bridge slot only
/// for a bridge candidate. The same rule decides inviting and accepting. Two more rules keep pending
/// attempts (which may hang for the whole watchdog delay) from starving a device, seen in simulator
/// rig runs with small caps: own pending invitations never hold more than all slots but one, and an
/// invitation that finds no free slot takes the one of our oldest pending invitation.
///
/// Backoff counts failed attempts and dropped links; only data proves a link works and resets it,
/// so a link that connects but never carries anything (half open) backs off like a failed attempt.
///
/// A pending own invitation is cancelled as soon as nobody can answer it: the peer is lost, or it
/// shows up with a new handle (restarted). Time only matters for telling a simultaneous invitation
/// from a stale one; `now` is injected.
struct MPCPeerMachine<Handle: Hashable> {

	enum Action {
		case emit(TransportEvent)
		case invite(Handle)
		/// Cancels a pending or unwanted session link.
		case cancel(Handle)
		/// Call `timerFired(_:token:)` after the delay; outdated tokens are ignored.
		case timer(UUID, token: Int, after: Duration)
	}

	private enum State {
		case idle, connecting, connected
	}

	private struct Record {
		let id: UUID
		var name: String
		var info: [String: String] = [:]
		var advertised: Handle?
		var session: Handle?
		var state = State.idle
		/// Our own invitation is pending since then.
		var invitedAt: Duration?
		/// Consecutive failed or dropped connections, reset when data arrives.
		var failures = 0
		/// Order of our own invitation while `invited`: lower is older.
		var attempt = 0
		/// Pending timer: invite delay while idle, watchdog while connecting.
		var timer: Int?

		var invited: Bool { invitedAt != nil }
		var isVisible: Bool { advertised != nil }
		var peer: TransportPeer { TransportPeer(id: id, name: name, info: info) }
	}

	let localID: UUID
	let maxPeers: Int
	private let now: () -> Duration
	/// Nil: no split, everyone first come, first served.
	private(set) var policy: LinkPolicy?
	private var peers: [UUID: Record] = [:]
	private var actions: [Action] = []
	private var lastToken = 0
	private var lastAttempt = 0

	init(localID: UUID, maxPeers: Int = MPCPolicy.maxRemotePeers, now: @escaping () -> Duration) {
		self.localID = localID
		self.maxPeers = maxPeers
		self.now = now
	}

	/// Forgets all peers (the policy stays); pending timers become outdated.
	mutating func reset() {
		peers = [:]
	}

	/// Forgets all peers like `reset()`, for a radio reset while running: every peer is reported
	/// `disconnected` (if pending or connected) and `lost`, in UUID order.
	mutating func forgetAll() -> [Action] {
		for record in peers.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
			if record.state != .idle {
				emit(.disconnected(record.id))
			}
			emit(.lost(record.id))
		}
		peers = [:]
		return take()
	}

	/// Whether the browser currently sees any peer.
	var hasVisiblePeers: Bool {
		peers.values.contains { $0.isVisible }
	}

	/// The handle to send to, nil unless connected.
	func sendHandle(for id: UUID) -> Handle? {
		guard let record = peers[id], record.state == .connected else { return nil }
		return record.session
	}

	// MARK: - Input

	mutating func found(_ handle: Handle, id: UUID, name: String, info: [String: String]) -> [Action] {
		var record = peers[id] ?? Record(id: id, name: name)
		let changed = !record.isVisible || record.name != name || record.info != info
		record.advertised = handle
		record.name = name
		record.info = info
		peers[id] = record
		if changed {
			emit(.found(record.peer))
		}
		if let session = record.session, session != handle {
			cancelInvite(id)	// our invitation went to an outdated handle
		}
		scheduleConnect(id)
		return take()
	}

	mutating func lost(_ handle: Handle) -> [Action] {
		guard let id = peers.values.first(where: { $0.advertised == handle })?.id else { return [] }
		peers[id]?.advertised = nil
		if peers[id]?.state == .idle {
			peers[id] = nil
			emit(.lost(id))
		} else {
			cancelInvite(id)	// nobody left to answer it; otherwise `lost` follows the disconnect
		}
		return take()
	}

	mutating func invitation(from handle: Handle, id: UUID, name: String) -> (accept: Bool, actions: [Action]) {
		guard id != localID else { return (false, []) }
		var record = peers[id] ?? Record(id: id, name: name)
		// Simultaneous invitations: the remote accepts ours. Only if ours went to the handle inviting
		// us; one to an outdated handle (the remote restarted with a fresh peer id) is never answered.
		// An older own invitation is stale: the remote is alive, so take theirs.
		if record.state == .connecting, let invitedAt = record.invitedAt, now() - invitedAt < MPCPolicy.simultaneousInviteWindow,
			record.session == handle, MPCPolicy.invitesFirst(local: localID, remote: id) {
			return (false, [])
		}
		let preempted = admits(id) ? nil : preemptable(for: id)
		guard admits(id) || preempted != nil else { return (false, []) }
		if let old = record.session, old != handle {
			actions.append(.cancel(old))
		}
		switch record.state {
		case .idle:
			emit(.connecting(id))
		case .connecting:
			break
		case .connected:
			// The remote relaunched: a fresh invitation proves the old link is dead.
			emit(.disconnected(id))
			emit(.connecting(id))
		}
		record.state = .connecting
		record.session = handle
		record.invitedAt = nil
		record.timer = startTimer(id, after: MPCPolicy.watchdogDelay)
		peers[id] = record
		if let preempted {
			withdraw(preempted)
		}
		return (true, take())
	}

	mutating func sessionChanged(_ handle: Handle, to state: MCSessionState) -> [Action] {
		guard let id = sessionID(handle) else {
			if state == .connected {
				actions.append(.cancel(handle))	// no links we don't track
			}
			return take()
		}
		switch state {
		case .connected:
			connect(id)
		case .notConnected:
			fail(id)
		case .connecting:
			break	// emitted on invite / accept already
		@unknown default:
			break
		}
		return take()
	}

	mutating func received(_ data: Data, from handle: Handle) -> [Action] {
		guard let id = sessionID(handle) else { return [] }
		connect(id)	// data proves the link is up, even if the state callback is still queued
		peers[id]?.failures = 0
		emit(.received(data, from: id))
		return take()
	}

	/// Sets or replaces the link policy; waiting peers get another chance, bridge candidates first.
	mutating func setPolicy(_ policy: LinkPolicy) -> [Action] {
		guard policy != self.policy else { return [] }
		self.policy = policy
		fillSlots()
		return take()
	}

	/// Drops a pending or connected link on purpose; bookkeeping as for a dropped link (backoff,
	/// reconnect unless the policy suppresses the peer).
	mutating func disconnect(_ id: UUID) -> [Action] {
		guard let record = peers[id], record.state != .idle else { return [] }
		if let session = record.session {
			actions.append(.cancel(session))
		}
		fail(id)
		return take()
	}

	mutating func timerFired(_ id: UUID, token: Int) -> [Action] {
		guard let record = peers[id], record.timer == token else { return [] }
		peers[id]?.timer = nil
		switch record.state {
		case .idle:
			invite(id)
		case .connecting:
			if let session = record.session {
				actions.append(.cancel(session))
			}
			fail(id)
		case .connected:
			break
		}
		return take()
	}

	// MARK: - Transitions

	private mutating func connect(_ id: UUID) {
		guard var record = peers[id], record.state != .connected else { return }
		record.state = .connected
		record.invitedAt = nil
		record.timer = nil
		peers[id] = record
		emit(.connected(record.peer))
		fillSlots()	// a pending invitation less: one held back by `invitesAllowed` may go now
	}

	/// Failed attempt or dropped link.
	private mutating func fail(_ id: UUID) {
		guard var record = peers[id], record.state != .idle else { return }
		record.state = .idle
		record.session = nil
		record.invitedAt = nil
		record.timer = nil
		record.failures += 1
		emit(.disconnected(id))
		if record.isVisible {
			peers[id] = record
			scheduleConnect(id)
		} else {
			peers[id] = nil
			emit(.lost(id))
		}
		fillSlots()
	}

	/// Invites a visible idle peer now or after tie-break / backoff delay.
	private mutating func scheduleConnect(_ id: UUID) {
		guard let record = peers[id], record.isVisible, record.state == .idle, record.timer == nil, wantsToInvite(id) else { return }
		let delay = MPCPolicy.delay(failures: record.failures, invitesFirst: MPCPolicy.invitesFirst(local: localID, remote: id))
		guard delay > .zero else { return invite(id) }
		let token = startTimer(id, after: delay)
		peers[id]?.timer = token
	}

	private mutating func invite(_ id: UUID) {
		guard var record = peers[id], let handle = record.advertised, record.state == .idle else { return }
		guard wantsToInvite(id), admits(id), invitesAllowed else {
			return	// retried by `fillSlots` once a slot frees up or the policy changes
		}
		lastAttempt += 1
		record.state = .connecting
		record.session = handle
		record.invitedAt = now()
		record.attempt = lastAttempt
		record.timer = startTimer(id, after: MPCPolicy.watchdogDelay)
		peers[id] = record
		emit(.connecting(id))
		actions.append(.invite(handle))
	}

	/// After a slot freed up or the policy changed: try all visible idle peers again, bridge
	/// candidates first, then those with the fewest failures in a row.
	private mutating func fillSlots() {
		let candidates = policy?.bridgeCandidates ?? []
		let waiting = peers.values.filter { $0.isVisible && $0.state == .idle && $0.timer == nil }
		let rank = { (record: Record) in (candidates.contains(record.id) ? 0 : 1, record.failures, record.id.uuidString) }
		for record in waiting.sorted(by: { rank($0) < rank($1) }) {
			scheduleConnect(record.id)
		}
	}

	/// Cancels our pending invitation, counting as failed attempt.
	private mutating func cancelInvite(_ id: UUID) {
		guard let record = peers[id], record.state == .connecting, record.invited, let session = record.session else { return }
		actions.append(.cancel(session))
		fail(id)
	}

	/// Withdraws our own pending invitation to make room for an accepted one; counts as a failed
	/// attempt (it was the oldest, most likely hanging).
	private mutating func withdraw(_ id: UUID) {
		if let session = peers[id]?.session {
			actions.append(.cancel(session))
		}
		fail(id)
	}

	// MARK: - Helpers

	/// Whether a link with the peer fits: a free regular slot (not for suppressed peers), or the
	/// bridge slot for a bridge candidate. Without a policy simply the cap.
	/// - Parameter ignoring: A peer whose pending or connected link is left out.
	private func admits(_ id: UUID, ignoring: UUID? = nil) -> Bool {
		let used = peers.values.count { $0.id != id && $0.id != ignoring && $0.state != .idle }
		guard let policy else { return used < maxPeers }
		guard !policy.suppressed.contains(id) else { return false }
		let slots = LinkSlots(maxPeers: maxPeers)
		return used < slots.regular || (used < slots.total && policy.bridgeCandidates.contains(id))
	}

	/// With a policy, our own pending invitations hold at most all slots but one, so an invitation
	/// from someone else (an isolated device, a bridge) always finds room.
	private var invitesAllowed: Bool {
		guard policy != nil else { return true }
		return peers.values.count { $0.state == .connecting && $0.invited } < max(1, maxPeers - 1)
	}

	/// With a policy, an invitation that finds no free slot may take the one of our oldest pending
	/// invitation: the inviter evidently reaches us, while ours may hang. Rig runs: an isolated device
	/// with every slot held by pending attempts declined everyone inviting it, for minutes.
	private func preemptable(for id: UUID) -> UUID? {
		guard policy != nil else { return nil }
		let pending = peers.values.filter { $0.id != id && $0.state == .connecting && $0.invited }
		guard let oldest = pending.min(by: { $0.attempt < $1.attempt }), admits(id, ignoring: oldest.id) else { return nil }
		return oldest.id
	}

	/// Suppressed peers and full ones (they would decline) are not invited; bridge candidates are.
	private func wantsToInvite(_ id: UUID) -> Bool {
		guard let policy else { return true }
		if policy.bridgeCandidates.contains(id) {
			return true
		}
		return !policy.suppressed.contains(id) && !policy.full.contains(id)
	}

	private func sessionID(_ handle: Handle) -> UUID? {
		peers.values.first { $0.session == handle }?.id
	}

	private mutating func startTimer(_ id: UUID, after delay: Duration) -> Int {
		lastToken += 1
		actions.append(.timer(id, token: lastToken, after: delay))
		return lastToken
	}

	private mutating func emit(_ event: TransportEvent) {
		actions.append(.emit(event))
	}

	private mutating func take() -> [Action] {
		defer { actions = [] }
		return actions
	}
}
