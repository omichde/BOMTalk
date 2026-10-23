//
//  LoopbackTransport.swift
//  BOMTalkTests
//

import Foundation
@testable import BOMTalk

/// In-memory network: every started transport sees and connects to every other started one.
/// Events are queued and delivered one per main actor turn, in order.
@MainActor
final class LoopbackHub {

	private var transports: [UUID: LoopbackTransport] = [:]
	private var links: Set<Set<UUID>> = []
	private var queue: [(target: UUID, event: TransportEvent)] = []
	private var pump: Task<Void, Never>?

	func makeTalk(name: String, offerTimeout: Duration = .seconds(5), chunkTimeout: Duration = .seconds(5)) -> Talk {
		Talk(transport: LoopbackTransport(hub: self, name: name), offerTimeout: offerTimeout, chunkTimeout: chunkTimeout)
	}

	/// A started transport without a Talk; tests send and inspect its frames by hand.
	func makeRaw(name: String) -> LoopbackTransport {
		let transport = LoopbackTransport(hub: self, name: name)
		transport.start(info: [:])
		return transport
	}

	func started(_ transport: LoopbackTransport) {
		let me = transport.localPeer
		for other in transports.values {
			let them = other.localPeer
			enqueue(.found(them), to: me.id)
			enqueue(.found(me), to: them.id)
			enqueue(.connecting(them.id), to: me.id)
			enqueue(.connecting(me.id), to: them.id)
			enqueue(.connected(them), to: me.id)
			enqueue(.connected(me), to: them.id)
			links.insert([me.id, them.id])
		}
		transports[me.id] = transport
	}

	func stopped(_ transport: LoopbackTransport) {
		let id = transport.localPeer.id
		transports[id] = nil
		for other in transports.keys {
			disconnect(id, other)
			enqueue(.lost(id), to: other)
		}
		queue.removeAll { $0.target == id }
	}

	/// Drops the connection immediately: data in flight is discarded, both sides are told synchronously.
	func disconnect(_ x: UUID, _ y: UUID) {
		guard links.remove([x, y]) != nil else { return }
		queue.removeAll { entry in
			guard case .received(_, let from) = entry.event else { return false }
			return (entry.target == x && from == y) || (entry.target == y && from == x)
		}
		transports[x]?.onEvent?(.disconnected(y))
		transports[y]?.onEvent?(.disconnected(x))
	}

	func send(_ data: Data, from: UUID, to: UUID) throws(TalkError) {
		guard links.contains([from, to]) else { throw .notConnected }
		enqueue(.received(data, from: from), to: to)
	}

	func enqueue(_ event: TransportEvent, to target: UUID) {
		queue.append((target, event))
		guard pump == nil else { return }
		pump = Task {
			while !queue.isEmpty {
				let (target, event) = queue.removeFirst()
				transports[target]?.deliver(event)
				await Task.yield()
			}
			pump = nil
		}
	}
}

@MainActor
final class LoopbackTransport: Transport {

	var onEvent: (@MainActor (TransportEvent) -> Void)?
	private(set) var localPeer: TransportPeer
	private let hub: LoopbackHub	// strong: tests need not keep the hub around
	/// Every frame received, for inspection.
	private(set) var received: [Data] = []

	init(hub: LoopbackHub, name: String) {
		self.hub = hub
		self.localPeer = TransportPeer(id: UUID(), name: name, info: [:])
	}

	/// Talk guards start / stop, no need to do it twice.
	func start(info: [String: String]) {
		localPeer.info = info
		hub.started(self)
	}

	func stop() {
		hub.stopped(self)
	}

	func update(info: [String: String]) {
		localPeer.info = info
	}

	func deliver(_ event: TransportEvent) {
		if case .received(let data, _) = event {
			received.append(data)
		}
		onEvent?(event)
	}

	func send(_ data: Data, to peer: UUID) throws(TalkError) {
		try hub.send(data, from: localPeer.id, to: peer)
	}
}
