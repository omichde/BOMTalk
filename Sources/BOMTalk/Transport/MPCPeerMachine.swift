//
//  MPCPeerMachine.swift
//  BOMTalk
//

import Foundation
import MultipeerConnectivity

/// Per-peer bookkeeping of `MPCTransport` without any MPC objects: fed with browser, invitation and
/// session callbacks, it returns the actions to perform. `Handle` is `MCPeerID` in production.
///
/// Per peer the state is `idle → connecting → connected → idle`, plus visibility from the browser.
/// One device may appear with several handles (rename, relaunch): `advertised` is the latest one seen
/// by the browser and used for inviting, `session` the one the session link belongs to. Callbacks for
/// other handles are ignored, so an outdated handle can neither hide nor drop a peer.
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
		/// Our own invitation is pending.
		var invited = false
		/// Consecutive failed or dropped connections, reset on connect.
		var failures = 0
		/// Pending timer: invite delay while idle, watchdog while connecting.
		var timer: Int?

		var isVisible: Bool { advertised != nil }
		var peer: TransportPeer { TransportPeer(id: id, name: name, info: info) }
	}

	let localID: UUID
	let maxPeers: Int
	private var peers: [UUID: Record] = [:]
	private var actions: [Action] = []
	private var lastToken = 0

	init(localID: UUID, maxPeers: Int = MPCPolicy.maxRemotePeers) {
		self.localID = localID
		self.maxPeers = maxPeers
	}

	/// Forgets all peers; pending timers become outdated.
	mutating func reset() {
		peers = [:]
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
		scheduleConnect(id)
		return take()
	}

	mutating func lost(_ handle: Handle) -> [Action] {
		guard let id = peers.values.first(where: { $0.advertised == handle })?.id else { return [] }
		peers[id]?.advertised = nil
		if peers[id]?.state == .idle {
			peers[id] = nil
			emit(.lost(id))
		}	// otherwise `lost` follows the disconnect
		return take()
	}

	mutating func invitation(from handle: Handle, id: UUID, name: String) -> (accept: Bool, actions: [Action]) {
		guard id != localID else { return (false, []) }
		var record = peers[id] ?? Record(id: id, name: name)
		if record.state == .connecting, record.invited, MPCPolicy.invitesFirst(local: localID, remote: id) {
			return (false, [])	// simultaneous invitations: the remote accepts ours
		}
		guard hasCapacity(excluding: id) else { return (false, []) }
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
		record.invited = false
		record.timer = startTimer(id, after: MPCPolicy.watchdogDelay)
		peers[id] = record
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
		emit(.received(data, from: id))
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
		record.invited = false
		record.failures = 0
		record.timer = nil
		peers[id] = record
		emit(.connected(record.peer))
	}

	/// Failed attempt or dropped link.
	private mutating func fail(_ id: UUID) {
		guard var record = peers[id], record.state != .idle else { return }
		record.state = .idle
		record.session = nil
		record.invited = false
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
		guard let record = peers[id], record.isVisible, record.state == .idle, record.timer == nil else { return }
		let delay = MPCPolicy.delay(failures: record.failures, invitesFirst: MPCPolicy.invitesFirst(local: localID, remote: id))
		guard delay > .zero else { return invite(id) }
		let token = startTimer(id, after: delay)
		peers[id]?.timer = token
	}

	private mutating func invite(_ id: UUID) {
		guard var record = peers[id], let handle = record.advertised, record.state == .idle else { return }
		guard hasCapacity(excluding: id) else {
			return	// retried by `fillSlots` once a slot frees up
		}
		record.state = .connecting
		record.session = handle
		record.invited = true
		record.timer = startTimer(id, after: MPCPolicy.watchdogDelay)
		peers[id] = record
		emit(.connecting(id))
		actions.append(.invite(handle))
	}

	/// After a slot freed up: try all visible idle peers again.
	private mutating func fillSlots() {
		let waiting = peers.values.filter { $0.isVisible && $0.state == .idle && $0.timer == nil }
		for id in waiting.map(\.id).sorted(by: { $0.uuidString < $1.uuidString }) {
			scheduleConnect(id)
		}
	}

	// MARK: - Helpers

	private func hasCapacity(excluding id: UUID) -> Bool {
		peers.values.count { $0.id != id && $0.state != .idle } < maxPeers
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
