//
//  LinkTransport.swift
//  BOMTalk
//

import Foundation
import os

/// Transport over a `LinkRadio`: advertises and browses at the same time (mesh), filters by app id
/// and protocol version, connects automatically and reconnects with backoff.
///
/// Radio-agnostic: the per-peer state machine lives in `MPCPeerMachine`, all MultipeerConnectivity
/// objects in the radio (`MPCRadio` in production, see `MPCTransport`). Timers are injected, so the
/// whole stack runs on virtual time in tests.
@MainActor
final class LinkTransport<Radio: LinkRadio>: Transport {

	var onEvent: (@MainActor (TransportEvent) -> Void)?
	private(set) var localPeer: TransportPeer

	let radio: Radio
	private let appID: String
	private let protocolVersion: Int
	private let invitationContext: Data?
	private let timers: any Timers
	private let logger = Logger.bomtalk("transport")

	private var isRunning = false
	private var machine: MPCPeerMachine<Radio.Handle>
	private var advertiserRestart: TimerToken?

	init(radio: Radio, localID: UUID, displayName: String, appID: String, protocolVersion: Int, timers: any Timers, maxPeers: Int = MPCPolicy.maxRemotePeers) {
		self.radio = radio
		self.appID = appID
		self.protocolVersion = protocolVersion
		self.timers = timers
		invitationContext = InvitationContext(appID: appID, version: protocolVersion, uuid: localID).encoded()
		machine = MPCPeerMachine(localID: localID, maxPeers: maxPeers)
		localPeer = TransportPeer(id: localID, name: displayName, info: [:])
		radio.onEvent = { [weak self] event in
			self?.handle(event)
		}
	}

	// MARK: - Transport

	func start(info: [String: String]) {
		guard !isRunning else { return }
		isRunning = true
		localPeer.info = info
		radio.start(discoveryInfo: discoveryInfo)
	}

	func stop() {
		guard isRunning else { return }
		isRunning = false
		advertiserRestart?.cancel()
		advertiserRestart = nil
		radio.stop()
		machine.reset()
	}

	/// Restarts the advertiser at most once per `advertiserRestartDelay`, with the latest info.
	func update(info: [String: String]) {
		localPeer.info = info
		guard isRunning, advertiserRestart == nil else { return }
		advertiserRestart = timers.schedule(after: MPCPolicy.advertiserRestartDelay) { [weak self] in
			guard let self else { return }
			self.advertiserRestart = nil
			guard self.isRunning else { return }
			self.radio.restartAdvertiser(discoveryInfo: self.discoveryInfo)
		}
	}

	func send(_ data: Data, to peer: UUID) throws(TalkError) {
		guard isRunning, let handle = machine.sendHandle(for: peer) else { throw .notConnected }
		do {
			try radio.send(data, to: handle)
		} catch {
			throw .sendFailed(error.localizedDescription)
		}
	}

	// MARK: - Radio callbacks (on main, in arrival order)

	private func handle(_ event: LinkRadioEvent<Radio.Handle>) {
		guard isRunning else {
			if case let .invitation(_, _, reply) = event {
				reply(false)
			}
			return
		}
		switch event {
		case let .found(handle, info):
			found(handle, info: info)
		case let .lost(handle):
			perform(machine.lost(handle))
		case let .invitation(handle, context, reply):
			guard let id = InvitationContext.decode(context, appID: appID, protocolVersion: protocolVersion) else {
				return reply(false)
			}
			let (accept, actions) = machine.invitation(from: handle, id: id, name: radio.displayName(of: handle))
			reply(accept)
			perform(actions)
		case let .state(handle, state):
			perform(machine.sessionChanged(handle, to: state))
		case let .data(data, handle):
			perform(machine.received(data, from: handle))
		case let .failed(error):
			onEvent?(.failed(error))
		}
	}

	private func found(_ handle: Radio.Handle, info: [String: String]?) {
		guard let (id, hostInfo) = DiscoveryInfo.decode(info, appID: appID, protocolVersion: protocolVersion) else { return }
		guard id != localPeer.id else {
			if handle != radio.localHandle {
				logger.warning("peer \(self.radio.displayName(of: handle), privacy: .public) has our own UUID (cloned device?)")
			}
			return
		}
		perform(machine.found(handle, id: id, name: radio.displayName(of: handle), info: hostInfo))
	}

	// MARK: - Actions

	private func perform(_ actions: [MPCPeerMachine<Radio.Handle>.Action]) {
		for action in actions {
			guard isRunning else { return }	// stopped from within `onEvent`
			switch action {
			case let .emit(event):
				onEvent?(event)
			case let .invite(handle):
				radio.invite(handle, context: invitationContext, timeout: MPCPolicy.inviteTimeout)
			case let .cancel(handle):
				radio.cancel(handle)
			case let .timer(id, token, delay):
				timers.schedule(after: delay) { [weak self] in
					guard let self else { return }
					self.perform(self.machine.timerFired(id, token: token))
				}
			}
		}
	}

	private var discoveryInfo: [String: String] {
		DiscoveryInfo.encode(appID: appID, protocolVersion: protocolVersion, uuid: localPeer.id, info: localPeer.info)
	}
}
