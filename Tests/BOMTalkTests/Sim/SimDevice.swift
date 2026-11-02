//
//  SimDevice.swift
//  BOMTalkTests
//

import Foundation
@testable import BOMTalk

/// One simulated device: radio, link transport, the transport on top (maybe a decorator) and an
/// optional `Talk`. Records the events of the top transport, as `Talk` sees them.
@MainActor
final class SimDevice {

	enum State: Equatable {
		case visible, connecting, connected
	}

	/// What the top transport reported about a remote peer, and since when (virtual time).
	struct PeerState: Equatable {
		var state: State
		var since: Duration
	}

	let index: Int
	let radio: SimRadio
	let link: LinkTransport<SimRadio>
	let transport: any Transport
	let talk: Talk?
	private unowned let network: SimNetwork
	private(set) var peers: [UUID: PeerState] = [:]
	private(set) var events: [TransportEvent] = []
	private var contract = TransportContract()

	init(index: Int, radio: SimRadio, link: LinkTransport<SimRadio>, transport: any Transport, talk: Talk?, network: SimNetwork) {
		self.index = index
		self.radio = radio
		self.link = link
		self.transport = transport
		self.talk = talk
		self.network = network
		let inner = transport.onEvent	// Talk's handler, if any
		transport.onEvent = { [weak self] event in
			self?.record(event)
			inner?(event)
		}
	}

	var id: UUID { transport.localPeer.id }
	var name: String { radio.localHandle.description }

	func start() {
		if let talk {
			talk.start()
		} else {
			transport.start(info: [:])
		}
	}

	func stop() {
		if let talk {
			talk.stop()
		} else {
			transport.stop()
		}
		peers = [:]
		contract.reset()
	}

	/// Indices of peers in the given state, sorted.
	func peers(_ state: State) -> [Int] {
		peers.filter { $0.value.state == state }.keys.compactMap { network.index(of: $0) }.sorted()
	}

	private func record(_ event: TransportEvent) {
		events.append(event)
		if let violation = contract.check(event) {
			network.contractViolated("\(name): \(violation)")
		}
		let now = network.now
		switch event {
		case let .found(peer):
			if peers[peer.id] == nil {
				peers[peer.id] = PeerState(state: .visible, since: now)
			}
			log("found", peer.id)
		case let .lost(id):
			peers[id] = nil
			log("lost", id)
		case let .connecting(id):
			peers[id] = PeerState(state: .connecting, since: now)
			log("connecting", id)
		case let .connected(peer):
			peers[peer.id] = PeerState(state: .connected, since: now)
			log("connected", peer.id)
		case let .disconnected(id):
			peers[id] = PeerState(state: .visible, since: now)
			log("disconnected", id)
		case let .received(data, from):
			log("received \(data.count)", from)
		case let .failed(error):
			network.record("\(name) failed \(error)")
		}
	}

	private func log(_ what: String, _ peer: UUID) {
		network.record("\(name) \(what) \(network.index(of: peer).map { "d\($0)" } ?? peer.uuidString)")
	}
}
