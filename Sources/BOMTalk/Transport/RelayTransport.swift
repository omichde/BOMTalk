//
//  RelayTransport.swift
//  BOMTalk
//

import Foundation
import os

/// Reaches devices beyond the direct links of the lower transport, hop by hop through other devices.
/// A decorator: `Talk` sees every reachable device as a connected peer, direct or relayed.
///
/// - **Envelope**: every frame between neighbours is a `RelayEnvelope` with origin, destination and
///   hop limit, so `received` reports the original sender.
/// - **Link state**: each device floods a `RelayHello` (name, info, its direct neighbours) every
///   `helloInterval` and right after its neighbours change. Hellos are forwarded once per version
///   (`epoch`, `seq`); every device keeps the latest per origin as its link map. Entries expire after
///   `helloExpiry`. An edge between two other devices counts only if both list each other; an edge
///   from this device counts while the lower transport is connected and the neighbour is not silent
///   for `helloExpiry` (stalled link).
/// - **Routing**: shortest path over the map (BFS, ties by UUID), recomputed on every change. Relays
///   forward data whose destination is not themselves; no retransmission, `Talk`'s timeouts handle
///   loss.
/// - Data from an origin that is not reachable yet (its hello is still on the way) is held briefly
///   and delivered right after its `connected`.
///
/// Timers, randomness (hello jitter) and the epoch source are injected, so the relay runs
/// deterministically on virtual time in tests.
@MainActor
final class RelayTransport: Transport {

	var onEvent: (@MainActor (TransportEvent) -> Void)?
	var localPeer: TransportPeer { lower.localPeer }

	/// A lower link (`connecting` or `connected` in the lower transport).
	private struct Link {
		var isConnected: Bool
		var peer: TransportPeer?
		/// Last frame received over the link (or when it connected).
		var lastHeard: Duration
	}

	private struct Entry {
		let hello: RelayHello
		/// Encoded hello, forwarded as is.
		let payload: Data
		/// Highest hop limit this version arrived with.
		var hopLimit: UInt8
		/// Local time of the last fresher hello.
		let updated: Duration
	}

	private struct Tombstone {
		let version: RelayHello.Version
		let until: Duration
	}

	private struct Route {
		let nextHop: UUID
		let hops: Int
	}

	/// What `onEvent` was told about a device.
	private enum State {
		case found, connecting, connected
	}

	private struct Reported {
		var state: State
		var peer: TransportPeer
	}

	private struct Held {
		let data: Data
		let since: Duration
	}

	/// Opens the injected generator for the generic `random(in:using:)` APIs.
	private struct Generator: RandomNumberGenerator {
		var base: any RandomNumberGenerator

		mutating func next() -> UInt64 { base.next() }
	}

	private let lower: any Transport
	private let timers: any Timers
	private var random: Generator
	private let epochSource: @MainActor () -> UInt64
	private let logger = Logger.bomtalk("relay")

	private var isRunning = false
	/// Incremented on every start and stop; work of an earlier run is ignored.
	private var run = 0
	private var epoch: UInt64 = 0
	private var seq: UInt64 = 0
	/// Payload of the last own hello, sent along with the map to new neighbours.
	private var ownHello: Data?
	private var lastHelloAt: Duration?
	private var periodicHello: TimerToken?
	private var triggeredHello: TimerToken?
	private var sweepTimer: TimerToken?

	private var visible: [UUID: TransportPeer] = [:]
	private var links: [UUID: Link] = [:]
	/// Live connected links as of the last refresh: the neighbours in our hello.
	private var linked: [UUID] = []
	private var entries: [UUID: Entry] = [:]
	private var tombstones: [UUID: Tombstone] = [:]
	private var routes: [UUID: Route] = [:]
	private var reported: [UUID: Reported] = [:]
	private var held: [UUID: [Held]] = [:]
	private var heldBytes = 0
	private var counters = RelayCounters()

	/// - Parameters:
	///   - random: Hello jitter.
	///   - epoch: Distinguishes runs of this device, must grow across restarts (wall-clock ms in
	///     production). A start within the same value still gets a higher epoch.
	init(lower: any Transport, timers: any Timers, random: any RandomNumberGenerator = SystemRandomNumberGenerator(), epoch: @escaping @MainActor () -> UInt64 = RelayTransport.wallClockEpoch) {
		self.lower = lower
		self.timers = timers
		self.random = Generator(base: random)
		self.epochSource = epoch
		lower.onEvent = { [weak self] event in
			self?.handle(event)
		}
	}

	nonisolated static func wallClockEpoch() -> UInt64 {
		UInt64(max(0, Date().timeIntervalSince1970 * 1000))
	}

	// MARK: - Transport

	func start(info: [String: String]) {
		guard !isRunning else { return }
		isRunning = true
		run += 1
		epoch = max(epochSource(), epoch + 1)
		seq = 0
		lastHelloAt = nil
		lower.start(info: info)
		sendHello()
		scheduleSweep()
	}

	func stop() {
		guard isRunning else { return }
		isRunning = false
		run += 1
		for timer in [periodicHello, triggeredHello, sweepTimer] {
			timer?.cancel()
		}
		periodicHello = nil
		triggeredHello = nil
		sweepTimer = nil
		lower.stop()
		ownHello = nil
		visible = [:]
		links = [:]
		linked = []
		entries = [:]
		tombstones = [:]
		routes = [:]
		reported = [:]
		held = [:]
		heldBytes = 0
	}

	func update(info: [String: String]) {
		lower.update(info: info)
		triggerHello()
	}

	func send(_ data: Data, to peer: UUID) throws(TalkError) {
		guard isRunning, let route = routes[peer] else { throw .notConnected }
		let envelope = RelayEnvelope(kind: .data, hopLimit: RelayPolicy.hopLimit, origin: localPeer.id, destination: peer, payload: data)
		try lower.send(envelope.encoded(), to: route.nextHop)
	}

	// MARK: - Introspection

	var snapshot: RelaySnapshot {
		let now = timers.now
		return RelaySnapshot(
			neighbours: linked,
			reachable: routes.keys.sorted(by: Self.order).compactMap { id in
				routes[id].map { RelaySnapshot.Route(id: id, name: peer(id)?.name ?? "", hops: $0.hops, nextHop: $0.nextHop) }
			},
			map: entries.keys.sorted(by: Self.order).compactMap { id in
				entries[id].map { RelaySnapshot.Entry(id: id, name: $0.hello.name, version: $0.hello.version, neighbours: $0.hello.neighbours, age: now - $0.updated) }
			},
			counters: counters,
			bufferedFrames: held.values.reduce(0) { $0 + $1.count }
		)
	}

	// MARK: - Lower events

	private func handle(_ event: TransportEvent) {
		guard isRunning else { return }
		switch event {
		case let .found(peer):
			visible[peer.id] = peer
			refresh()
		case let .lost(id):
			visible[id] = nil
			refresh()
		case let .connecting(id):
			links[id] = Link(isConnected: false, peer: nil, lastHeard: timers.now)
			refresh()
		case let .connected(peer):
			links[peer.id] = Link(isConnected: true, peer: peer, lastHeard: timers.now)
			syncMap(to: peer.id)
			refresh()
		case let .disconnected(id):
			links[id] = nil
			refresh()
		case let .received(data, neighbour):
			received(data, from: neighbour)
		case let .failed(error):
			onEvent?(.failed(error))
		}
	}

	private func received(_ data: Data, from neighbour: UUID) {
		guard let link = links[neighbour], link.isConnected else {
			return logger.error("frame from unlinked neighbour \(neighbour, privacy: .public)")
		}
		let wasLive = isLive(link)
		links[neighbour]?.lastHeard = timers.now
		if !wasLive {
			refresh()
			guard isRunning else { return }	// stopped from within `onEvent`
		}
		guard let envelope = RelayEnvelope(data) else {
			return drop(.malformed, "\(data.count) bytes from \(neighbour)")
		}
		switch envelope.kind {
		case .hello:
			receivedHello(envelope, from: neighbour)
		case .data:
			receivedData(envelope, from: neighbour)
		}
	}

	// MARK: - Hellos

	private func receivedHello(_ envelope: RelayEnvelope, from neighbour: UUID) {
		counters.hellosReceived += 1
		guard let hello = RelayHello(envelope.payload), envelope.destination == RelayEnvelope.broadcast else {
			return drop(.malformed, "hello from \(neighbour)")
		}
		let origin = envelope.origin
		guard origin != localPeer.id else { return }
		if let entry = entries[origin] {
			guard hello.version >= entry.hello.version else { return }
			if hello.version == entry.hello.version {
				// a copy that took a shorter path: pass it on further than the first one could
				guard envelope.hopLimit > entry.hopLimit else { return }
				entries[origin]?.hopLimit = envelope.hopLimit
				flood(envelope, except: neighbour)
				return
			}
		} else if let tombstone = tombstones[origin], hello.version <= tombstone.version {
			return
		}
		tombstones[origin] = nil
		entries[origin] = Entry(hello: hello, payload: envelope.payload, hopLimit: envelope.hopLimit, updated: timers.now)
		flood(envelope, except: neighbour)
		refresh()
	}

	/// Forwards a hello to all connected links except the one it came from.
	private func flood(_ envelope: RelayEnvelope, except neighbour: UUID) {
		guard envelope.hopLimit > 1 else { return }
		let data = envelope.forwarded().encoded()
		for id in connectedLinks where id != neighbour {
			if transmit(data, to: id) {
				counters.hellosForwarded += 1
			}
		}
	}

	/// A new neighbour gets our latest hello and the whole map right away.
	private func syncMap(to neighbour: UUID) {
		if let ownHello {
			let envelope = RelayEnvelope(kind: .hello, hopLimit: RelayPolicy.hopLimit, origin: localPeer.id, destination: RelayEnvelope.broadcast, payload: ownHello)
			if transmit(envelope.encoded(), to: neighbour) {
				counters.hellosSent += 1
			}
		}
		for origin in entries.keys.sorted(by: Self.order) where origin != neighbour {
			guard let entry = entries[origin], entry.hopLimit > 1 else { continue }
			let envelope = RelayEnvelope(kind: .hello, hopLimit: entry.hopLimit - 1, origin: origin, destination: RelayEnvelope.broadcast, payload: entry.payload)
			if transmit(envelope.encoded(), to: neighbour) {
				counters.hellosForwarded += 1
			}
		}
	}

	private func sendHello() {
		triggeredHello?.cancel()
		triggeredHello = nil
		seq += 1
		let local = localPeer
		let hello = RelayHello(name: local.name, info: local.info, version: RelayHello.Version(epoch: epoch, seq: seq), neighbours: linked)
		let payload = hello.encoded()
		ownHello = payload
		let data = RelayEnvelope(kind: .hello, hopLimit: RelayPolicy.hopLimit, origin: local.id, destination: RelayEnvelope.broadcast, payload: payload).encoded()
		for id in connectedLinks {
			if transmit(data, to: id) {
				counters.hellosSent += 1
			}
		}
		lastHelloAt = timers.now
		periodicHello?.cancel()
		let run = self.run
		periodicHello = timers.schedule(after: RelayPolicy.helloDelay(using: &random)) { [weak self] in
			guard let self, self.isRunning, self.run == run else { return }
			self.periodicHello = nil
			self.sendHello()
		}
	}

	/// Sends a hello now, or once `helloMinGap` after the last one passed.
	private func triggerHello() {
		guard isRunning, triggeredHello == nil else { return }
		guard let last = lastHelloAt, timers.now - last < RelayPolicy.helloMinGap else { return sendHello() }
		let run = self.run
		triggeredHello = timers.schedule(after: RelayPolicy.helloMinGap - (timers.now - last)) { [weak self] in
			guard let self, self.isRunning, self.run == run else { return }
			self.triggeredHello = nil
			self.sendHello()
		}
	}

	// MARK: - Data

	private func receivedData(_ envelope: RelayEnvelope, from neighbour: UUID) {
		let local = localPeer.id
		guard envelope.destination == local else {
			guard envelope.hopLimit > 1 else {
				return drop(.hopLimit, "data \(envelope.origin) → \(envelope.destination)")
			}
			guard let route = routes[envelope.destination] else {
				return drop(.noRoute, "data \(envelope.origin) → \(envelope.destination)")
			}
			guard transmit(envelope.forwarded().encoded(), to: route.nextHop) else {
				return drop(.sendFailed, "data \(envelope.origin) → \(envelope.destination) via \(route.nextHop)")
			}
			counters.dataForwarded += 1
			return
		}
		guard envelope.origin != local else {
			return drop(.malformed, "data from ourselves via \(neighbour)")
		}
		if reported[envelope.origin]?.state == .connected {
			onEvent?(.received(envelope.payload, from: envelope.origin))
		} else {
			hold(envelope.payload, from: envelope.origin)
		}
	}

	/// Keeps data of a not yet reachable origin until its `connected`, within the buffer limits.
	private func hold(_ data: Data, from origin: UUID) {
		guard held[origin, default: []].count < RelayPolicy.bufferMaxFrames, heldBytes + data.count <= RelayPolicy.bufferMaxBytes else {
			return drop(.bufferOverflow, "data from \(origin)")
		}
		held[origin, default: []].append(Held(data: data, since: timers.now))
		heldBytes += data.count
	}

	// MARK: - Sweep

	private func scheduleSweep() {
		let run = self.run
		sweepTimer = timers.schedule(after: RelayPolicy.sweepInterval) { [weak self] in
			guard let self, self.isRunning, self.run == run else { return }
			self.sweep()
		}
	}

	/// Expires map entries, tombstones and held data, then re-checks link liveness.
	private func sweep() {
		let now = timers.now
		for id in entries.keys.sorted(by: Self.order) {
			guard let entry = entries[id], now - entry.updated >= RelayPolicy.helloExpiry else { continue }
			entries[id] = nil
			tombstones[id] = Tombstone(version: entry.hello.version, until: now + RelayPolicy.tombstoneDuration)
		}
		tombstones = tombstones.filter { $0.value.until > now }
		for origin in held.keys.sorted(by: Self.order) {
			guard let frames = held[origin] else { continue }
			let expired = frames.prefix { now - $0.since >= RelayPolicy.bufferMaxAge }
			guard !expired.isEmpty else { continue }
			for frame in expired {
				heldBytes -= frame.data.count
				drop(.bufferTimeout, "data from \(origin)")
			}
			held[origin] = frames.count == expired.count ? nil : Array(frames.dropFirst(expired.count))
		}
		refresh()
		guard isRunning else { return }	// stopped from within `onEvent`
		scheduleSweep()
	}

	// MARK: - Routing and reporting

	/// After any change: own neighbours (hello if changed), routes, events.
	private func refresh() {
		let live = links.filter { isLive($0.value) }.keys.sorted(by: Self.order)
		if live != linked {
			linked = live
			triggerHello()
		}
		routes = computeRoutes()
		reconcile()
	}

	/// BFS from this device; neighbours in UUID order, so ties always resolve the same way.
	private func computeRoutes() -> [UUID: Route] {
		let local = localPeer.id
		var routes: [UUID: Route] = [:]
		var queue: [UUID] = []
		for id in linked {
			routes[id] = Route(nextHop: id, hops: 1)
			queue.append(id)
		}
		var index = 0
		while index < queue.count {
			let node = queue[index]
			index += 1
			guard let route = routes[node], route.hops < Int(RelayPolicy.hopLimit), let entry = entries[node] else { continue }
			for next in entry.hello.neighbours.sorted(by: Self.order) where next != local && routes[next] == nil {
				// both ends must list each other
				guard entries[next]?.hello.neighbours.contains(node) == true else { continue }
				routes[next] = Route(nextHop: route.nextHop, hops: route.hops + 1)
				queue.append(next)
			}
		}
		return routes
	}

	/// Brings `reported` in line with what is known, emitting the transitions in UUID order.
	private func reconcile() {
		let run = self.run
		let ids = Set(visible.keys).union(links.keys).union(entries.keys).union(reported.keys).subtracting([localPeer.id])
		for id in ids.sorted(by: Self.order) {
			let events = transition(id)
			for event in events {
				guard isRunning, self.run == run else { return }	// stopped from within `onEvent`
				onEvent?(event)
			}
		}
	}

	/// Updates `reported` for one device and returns the events to emit, buffered data included.
	private func transition(_ id: UUID) -> [TransportEvent] {
		let current = reported[id]
		guard let peer = peer(id), let target = desiredState(id) else {
			guard let current else { return [] }
			reported[id] = nil
			return current.state == .found ? [.lost(id)] : [.disconnected(id), .lost(id)]
		}
		reported[id] = Reported(state: target, peer: peer)
		var events: [TransportEvent] = []
		if let current {
			if current.peer != peer {
				events.append(.found(peer))
			}
			switch (current.state, target) {
			case (.found, .connecting):
				events.append(.connecting(id))
			case (.found, .connected), (.connecting, .connected):
				events.append(.connected(peer))
			case (.connecting, .found), (.connected, .found):
				events.append(.disconnected(id))
			case (.connected, .connecting):
				events += [.disconnected(id), .connecting(id)]
			case (.found, .found), (.connecting, .connecting), (.connected, .connected):
				break
			}
		} else {
			events.append(.found(peer))
			switch target {
			case .found: break
			case .connecting: events.append(.connecting(id))
			case .connected: events.append(.connected(peer))
			}
		}
		if target == .connected, let frames = held.removeValue(forKey: id) {
			heldBytes -= frames.reduce(0) { $0 + $1.data.count }
			events += frames.map { .received($0.data, from: id) }
		}
		return events
	}

	private func desiredState(_ id: UUID) -> State? {
		if routes[id] != nil {
			return .connected
		}
		if let link = links[id], !link.isConnected {
			return .connecting
		}
		return visible[id] != nil || links[id] != nil || entries[id] != nil ? .found : nil
	}

	/// Name and info: from the hello if there is one, otherwise from the lower transport.
	private func peer(_ id: UUID) -> TransportPeer? {
		if let hello = entries[id]?.hello {
			return TransportPeer(id: id, name: hello.name, info: hello.info)
		}
		return links[id]?.peer ?? visible[id] ?? reported[id]?.peer
	}

	// MARK: - Helpers

	private var connectedLinks: [UUID] {
		links.filter(\.value.isConnected).keys.sorted(by: Self.order)
	}

	private func isLive(_ link: Link) -> Bool {
		link.isConnected && timers.now - link.lastHeard < RelayPolicy.helloExpiry
	}

	/// Sends to a lower neighbour; false if the lower transport refused.
	private func transmit(_ data: Data, to neighbour: UUID) -> Bool {
		do {
			try lower.send(data, to: neighbour)
			return true
		} catch {
			logger.debug("sending to \(neighbour, privacy: .public) failed: \(String(describing: error), privacy: .public)")
			return false
		}
	}

	private func drop(_ reason: RelayCounters.Drop, _ detail: String) {
		counters.drops[reason, default: 0] += 1
		if reason == .malformed {
			logger.error("dropping malformed frame: \(detail, privacy: .public)")
		} else {
			logger.debug("dropping (\(reason.rawValue, privacy: .public)): \(detail, privacy: .public)")
		}
	}

	private static func order(_ a: UUID, _ b: UUID) -> Bool {
		a.uuidString < b.uuidString
	}
}

/// Relay statistics since the transport was created.
struct RelayCounters: Sendable, Equatable {

	enum Drop: String, Sendable, CaseIterable {
		/// Data for a destination without a route.
		case noRoute
		/// Data whose hop limit ran out before reaching its destination.
		case hopLimit
		case malformed
		/// Data from a not yet reachable origin beyond the buffer limits.
		case bufferOverflow
		/// Held data whose origin did not become reachable in time.
		case bufferTimeout
		/// Data the lower transport refused to forward.
		case sendFailed
	}

	/// Own hello frames, per neighbour.
	var hellosSent = 0
	var hellosReceived = 0
	/// Hello frames passed on (flooding and map sync), per neighbour.
	var hellosForwarded = 0
	/// Data frames passed on to the next hop.
	var dataForwarded = 0
	var drops: [Drop: Int] = [:]

	subscript(drop: Drop) -> Int { drops[drop] ?? 0 }
}

/// State of a `RelayTransport` for debugging and tests.
struct RelaySnapshot: Sendable, Equatable {

	struct Route: Sendable, Equatable {
		let id: UUID
		let name: String
		let hops: Int
		let nextHop: UUID
	}

	struct Entry: Sendable, Equatable {
		let id: UUID
		let name: String
		let version: RelayHello.Version
		let neighbours: [UUID]
		/// Since the last fresher hello.
		let age: Duration
	}

	/// Direct neighbours counted as linked (connected and not silent).
	let neighbours: [UUID]
	/// Reachable devices, direct ones included, sorted by UUID.
	let reachable: [Route]
	let map: [Entry]
	let counters: RelayCounters
	let bufferedFrames: Int
}
