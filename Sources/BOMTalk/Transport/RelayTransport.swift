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
/// - **Link policy (6 + 1)**, when the lower transport offers `LinkControl`: visible devices that
///   stay unreachable for `bridgeDelay` become bridge candidates and may take the bridge slot. With
///   every slot in use, one redundant neighbour (reachable without the direct edge) is unlinked:
///   an `unlink` frame tells it to disconnect, and neither side links again while they reach each
///   other via relay. Damped by minimum link age, a data-quiet window, a drop rate limit and
///   jitter. Neighbours silent for `stalledDisconnect` are disconnected, freeing their slot.
///
/// Timers, randomness (hello and decision jitter) and the epoch source are injected, so the relay
/// runs deterministically on virtual time in tests.
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
		var connectedAt: Duration?
		/// Last data frame over the link, either direction, own or forwarded.
		var lastData: Duration?
		/// Unlink in progress: the link is no longer used.
		var unlink: Unlink?
	}

	private struct Unlink {
		enum Role {
			/// We asked the neighbour to disconnect.
			case sent
			/// The neighbour asked us; we disconnect once the link is quiet.
			case received
		}

		let role: Role
		let at: Duration
	}

	/// A visible device without a route: since when, and after which delay it is a bridge candidate.
	private struct Unreachable {
		let since: Duration
		let delay: Duration
	}

	private struct PendingDrop {
		let since: Duration
		let delay: Duration
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
	/// The lower transport's admission control, nil without a link policy.
	private let control: (any LinkControl)?
	private let slots: LinkSlots?
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

	private var unreachable: [UUID: Unreachable] = [:]
	/// Unlinked devices and until when at most.
	private var suppressed: [UUID: Duration] = [:]
	/// The policy last handed to `control`.
	private var policy = LinkPolicy()
	/// Flags of our hello as of the last refresh.
	private var flags: RelayHello.Flags = []
	/// Last change of any edge in the map, own ones included.
	private var topologyChangedAt: Duration = .zero
	private var lastDropAt: Duration?
	private var pendingDrop: PendingDrop?
	/// Fires when the pending drop is due, so its jitter is not rounded to the sweep interval.
	private var dropTimer: TimerToken?
	private var linkActions: [RelaySnapshot.LinkAction] = []

	/// - Parameters:
	///   - random: Hello jitter, bridge and drop decision jitter.
	///   - epoch: Distinguishes runs of this device, must grow across restarts (wall-clock ms in
	///     production). A start within the same value still gets a higher epoch.
	init(lower: any Transport, timers: any Timers, random: any RandomNumberGenerator = SystemRandomNumberGenerator(), epoch: @escaping @MainActor () -> UInt64 = RelayTransport.wallClockEpoch) {
		self.lower = lower
		control = lower as? any LinkControl
		slots = control.map { LinkSlots(maxPeers: $0.linkCap) }
		self.timers = timers
		self.random = Generator(base: random)
		self.epochSource = epoch
		lower.onEvent = { [weak self] event in
			self?.handle(event)
		}
		control?.setLinkPolicy(policy)	// splits the cap from the start
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
		unreachable = [:]
		suppressed = [:]
		policy = LinkPolicy()
		control?.setLinkPolicy(policy)
		flags = []
		topologyChangedAt = .zero
		lastDropAt = nil
		pendingDrop = nil
		dropTimer?.cancel()
		dropTimer = nil
	}

	func update(info: [String: String]) {
		lower.update(info: info)
		triggerHello()
	}

	func send(_ data: Data, to peer: UUID) throws(TalkError) {
		guard isRunning, let route = routes[peer] else { throw .notConnected }
		let envelope = RelayEnvelope(kind: .data, hopLimit: RelayPolicy.hopLimit, origin: localPeer.id, destination: peer, payload: data)
		try lower.send(envelope.encoded(), to: route.nextHop)
		links[route.nextHop]?.lastData = timers.now
	}

	// MARK: - Introspection and debug controls

	/// Drops the link to a direct neighbour (pending or connected); false if there is none. The lower
	/// transport reconnects with backoff like after any drop.
	func debugDisconnect(_ id: UUID) -> Bool {
		guard isRunning, links[id] != nil, let control else { return false }
		control.disconnect(id)
		return true
	}

	/// Devices with these display names are invisible to the lower transport, see `LinkDebugControl`.
	var debugBlocked: Set<String> {
		get { (lower as? any LinkDebugControl)?.blockedNames ?? [] }
		set { (lower as? any LinkDebugControl)?.setBlockedNames(newValue) }
	}

	var snapshot: RelaySnapshot {
		let now = timers.now
		return RelaySnapshot(
			now: now,
			neighbours: linked,
			reachable: routes.keys.sorted(by: Self.order).compactMap { id in
				routes[id].map { RelaySnapshot.Route(id: id, name: peer(id)?.name ?? "", hops: $0.hops, nextHop: $0.nextHop) }
			},
			map: entries.keys.sorted(by: Self.order).compactMap { id in
				entries[id].map { RelaySnapshot.Entry(id: id, name: $0.hello.name, version: $0.hello.version, neighbours: $0.hello.neighbours, age: now - $0.updated) }
			},
			counters: currentCounters,
			bufferedFrames: held.values.reduce(0) { $0 + $1.count },
			slots: slots.map { slots in
				let used = links.count
				return RelaySnapshot.SlotUsage(regular: min(used, slots.regular), bridge: max(0, used - slots.regular), capacity: slots)
			},
			flags: flags,
			suppressed: suppressed.keys.sorted(by: Self.order),
			bridgeCandidates: policy.bridgeCandidates.sorted(by: Self.order),
			linkActions: linkActions
		)
	}

	/// Own counters plus the lower transport's radio resets.
	private var currentCounters: RelayCounters {
		var counters = self.counters
		counters.radioResets = (lower as? any LinkDebugControl)?.radioResets ?? 0
		return counters
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
			links[peer.id] = Link(isConnected: true, peer: peer, lastHeard: timers.now, connectedAt: timers.now)
			if let slots, slots.bridge > 0, links.values.count(where: \.isConnected) > slots.regular {
				counters.bridgeConnects += 1
				record(.bridge, peer.id)
			}
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
		let wasSilent = timers.now - link.lastHeard >= RelayPolicy.helloExpiry
		links[neighbour]?.lastHeard = timers.now
		if wasSilent {
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
		case .unlink:
			receivedUnlink(envelope, from: neighbour)
		}
	}

	// MARK: - Hellos

	private func receivedHello(_ envelope: RelayEnvelope, from neighbour: UUID) {
		counters.hellosReceived += 1
		guard let version = RelayHello.version(of: envelope.payload), envelope.destination == RelayEnvelope.broadcast else {
			return drop(.malformed, "hello from \(neighbour)")
		}
		let origin = envelope.origin
		guard origin != localPeer.id else { return }
		// copies of a known version are common: decide on the version before decoding
		if let entry = entries[origin] {
			guard version >= entry.hello.version else { return }
			if version == entry.hello.version {
				// a copy that took a shorter path: pass it on further than the first one could
				guard envelope.hopLimit > entry.hopLimit else { return }
				entries[origin]?.hopLimit = envelope.hopLimit
				flood(envelope, except: neighbour)
				return
			}
		} else if let tombstone = tombstones[origin], version <= tombstone.version {
			return
		}
		guard let hello = RelayHello(envelope.payload) else {
			return drop(.malformed, "hello from \(neighbour)")
		}
		tombstones[origin] = nil
		let previous = entries[origin]?.hello
		if previous?.neighbours != hello.neighbours {
			topologyChangedAt = timers.now
		}
		entries[origin] = Entry(hello: hello, payload: envelope.payload, hopLimit: envelope.hopLimit, updated: timers.now)
		flood(envelope, except: neighbour)
		// a periodic hello with nothing new only renews the entry
		if let previous, previous.neighbours == hello.neighbours, previous.name == hello.name, previous.info == hello.info, previous.flags == hello.flags {
			return
		}
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
		let hello = RelayHello(name: local.name, info: local.info, version: RelayHello.Version(epoch: epoch, seq: seq), neighbours: linked, flags: flags)
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
		links[neighbour]?.lastData = timers.now
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
			links[route.nextHop]?.lastData = timers.now
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
		var changed = false
		for id in entries.keys.sorted(by: Self.order) {
			guard let entry = entries[id], now - entry.updated >= RelayPolicy.helloExpiry else { continue }
			changed = true
			entries[id] = nil
			counters.entriesExpired += 1
			topologyChangedAt = now
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
		let run = self.run
		if changed || isDue {
			refresh()
			guard isRunning, self.run == run else { return }	// stopped from within `onEvent`
		}
		maintainLinks()
		guard isRunning, self.run == run else { return }
		scheduleSweep()
	}

	// MARK: - Routing and reporting

	/// After any change: own neighbours and flags (hello if changed), routes, events, link policy.
	private func refresh() {
		let run = self.run
		let live = links.filter { isLive($0.value) }.keys.sorted(by: Self.order)
		let flags = currentFlags
		if live != linked || flags != self.flags {
			if live != linked {
				topologyChangedAt = timers.now
			}
			linked = live
			self.flags = flags
			triggerHello()
		}
		routes = computeRoutes()
		reconcile()
		guard isRunning, self.run == run else { return }	// stopped from within `onEvent`
		updateLinkPolicy()	// last: may call back into `handle` right away
	}

	/// BFS from this device; neighbours in UUID order, so ties always resolve the same way.
	/// - Parameter excluded: A neighbour whose direct edge is left out (redundancy check).
	private func computeRoutes(excluding excluded: UUID? = nil) -> [UUID: Route] {
		let local = localPeer.id
		var routes: [UUID: Route] = [:]
		var queue: [UUID] = []
		for id in linked where id != excluded {
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

	/// Whether time alone changed something `refresh` derives: link liveness, a bridge candidate
	/// or an expired suppression.
	private var isDue: Bool {
		let now = timers.now
		if links.filter({ isLive($0.value) }).keys.sorted(by: Self.order) != linked {
			return true
		}
		if unreachable.contains(where: { now - $0.value.since >= $0.value.delay && !policy.bridgeCandidates.contains($0.key) }) {
			return true
		}
		return suppressed.values.contains { $0 <= now }
	}

	// MARK: - Link policy

	/// Bridge slot free; regular slots full (then reachable devices don't invite us).
	private var currentFlags: RelayHello.Flags {
		guard let slots else { return [] }
		var flags: RelayHello.Flags = []
		if slots.bridge > 0, links.count <= slots.regular {
			flags.insert(.bridgeSlotFree)
		}
		if links.count >= slots.regular {
			flags.insert(.regularSlotsFull)
		}
		return flags
	}

	/// Derives bridge candidates, suppression and full devices from the map and hands a changed
	/// policy to the lower transport.
	private func updateLinkPolicy() {
		guard let control else { return }
		let now = timers.now
		suppressed = suppressed.filter { $0.value > now }
		var candidates: Set<UUID> = []
		for id in visible.keys.sorted(by: Self.order) {
			// a pending link (maybe into the bridge slot) does not restart the grace period
			guard routes[id] == nil, links[id]?.isConnected != true else {
				unreachable[id] = nil
				continue
			}
			let since = unreachable[id] ?? startUnreachable(id)
			unreachable[id] = since
			if now - since.since >= since.delay {
				candidates.insert(id)
				suppressed[id] = nil	// unreachable: the unlink no longer holds
			}
		}
		unreachable = unreachable.filter { visible[$0.key] != nil }
		let full = entries.filter { $0.value.hello.flags.contains(.regularSlotsFull) && routes[$0.key] != nil && links[$0.key] == nil }.keys
		let policy = LinkPolicy(bridgeCandidates: candidates, suppressed: Set(suppressed.keys), full: Set(full))
		guard policy != self.policy else { return }
		self.policy = policy
		control.setLinkPolicy(policy)
	}

	/// Starts the grace period of a visible device without a route; a timer re-checks it right when
	/// it ends, so the jitter is not rounded to the sweep interval.
	private func startUnreachable(_ id: UUID) -> Unreachable {
		let entry = Unreachable(since: timers.now, delay: RelayPolicy.jittered(RelayPolicy.bridgeDelay, using: &random))
		let run = self.run
		timers.schedule(after: entry.delay) { [weak self] in
			guard let self, self.isRunning, self.run == run, self.unreachable[id]?.since == entry.since else { return }
			self.refresh()
		}
		return entry
	}

	/// Once per sweep: disconnects stalled links and unlinked ones, then maybe drops a redundant one.
	private func maintainLinks() {
		guard let control else { return }
		let run = self.run
		let now = timers.now
		var reverted = false
		for id in links.keys.sorted(by: Self.order) {
			guard isRunning, self.run == run else { return }	// stopped from within `onEvent`
			guard let link = links[id], link.isConnected else { continue }
			if now - link.lastHeard >= RelayPolicy.stalledDisconnect {
				counters.stalledDisconnects += 1
				record(.stalled, id)
				control.disconnect(id)
				continue
			}
			guard let unlink = link.unlink else { continue }
			switch unlink.role {
			case .received:
				let quiet = link.lastData.map { now - $0 >= RelayPolicy.dataQuiet } ?? true
				if now - unlink.at >= RelayPolicy.unlinkDelay, quiet {
					control.disconnect(id)
				}
			case .sent:
				if now - unlink.at >= RelayPolicy.unlinkTimeout {
					// the neighbour did not act on it: use the link again, suppression stays
					links[id]?.unlink = nil
					reverted = true
				}
			}
		}
		guard isRunning, self.run == run else { return }
		if reverted {
			refresh()
			guard isRunning, self.run == run else { return }
		}
		dropRedundant()
	}

	/// With every slot in use, unlinks the redundant neighbour with the highest map degree, once the
	/// map has been stable for a jittered `dropDelay`, at most once per `dropInterval`.
	private func dropRedundant() {
		let now = timers.now
		guard let slots, slots.bridge > 0, links.count >= slots.total,
			!links.values.contains(where: { $0.unlink != nil }),
			lastDropAt.map({ now - $0 >= RelayPolicy.dropInterval }) ?? true,
			let neighbour = redundantNeighbour()
		else {
			pendingDrop = nil
			dropTimer?.cancel()
			dropTimer = nil
			return
		}
		let pending = pendingDrop ?? PendingDrop(since: now, delay: RelayPolicy.jittered(RelayPolicy.dropDelay, using: &random))
		pendingDrop = pending
		let due = max(pending.since, topologyChangedAt) + pending.delay
		guard now >= due else {
			dropTimer?.cancel()
			let run = self.run
			dropTimer = timers.schedule(after: due - now) { [weak self] in
				guard let self, self.isRunning, self.run == run else { return }
				self.dropTimer = nil
				self.dropRedundant()
			}
			return
		}
		pendingDrop = nil
		dropTimer?.cancel()
		dropTimer = nil
		unlink(neighbour)
	}

	/// Linked neighbours old and quiet enough that are reachable without their direct edge; the one
	/// with the most neighbours of its own, ties by UUID.
	private func redundantNeighbour() -> UUID? {
		let now = timers.now
		let redundant = linked.filter { id in
			guard let link = links[id], let since = link.connectedAt, now - since >= RelayPolicy.minLinkAge else { return false }
			if let last = link.lastData, now - last < RelayPolicy.dataQuiet {
				return false
			}
			return computeRoutes(excluding: id)[id] != nil
		}
		let degree = { (id: UUID) in self.entries[id]?.hello.neighbours.count ?? 0 }
		return redundant.max { degree($0) != degree($1) ? degree($0) < degree($1) : Self.order($0, $1) }
	}

	/// Asks a neighbour to disconnect; both sides suppress each other from here on.
	private func unlink(_ id: UUID) {
		guard links[id] != nil else { return }
		let now = timers.now
		lastDropAt = now
		counters.voluntaryDrops += 1
		record(.drop, id)
		suppressed[id] = now + RelayPolicy.suppressionTimeout
		let envelope = RelayEnvelope(kind: .unlink, hopLimit: 1, origin: localPeer.id, destination: id, payload: Data())
		guard transmit(envelope.encoded(), to: id) else {
			refresh()	// suppression first, so the link is not invited again
			guard isRunning else { return }
			control?.disconnect(id)
			return
		}
		counters.unlinksSent += 1
		links[id]?.unlink = Unlink(role: .sent, at: now)
		refresh()
		announce()
	}

	/// The neighbour unlinks us: stop using the link, disconnect it once quiet (`maintainLinks`).
	private func receivedUnlink(_ envelope: RelayEnvelope, from neighbour: UUID) {
		guard envelope.origin == neighbour, envelope.destination == localPeer.id else {
			return drop(.malformed, "unlink from \(neighbour)")
		}
		counters.unlinksReceived += 1
		record(.unlinked, neighbour)
		let now = timers.now
		suppressed[neighbour] = now + RelayPolicy.suppressionTimeout
		links[neighbour]?.unlink = Unlink(role: .received, at: now)
		refresh()
		announce()
	}

	/// After an unlink the new neighbour list goes out at once, not after `helloMinGap`: other
	/// devices postpone their own drops on the change (`topologyChangedAt`), so two of them don't
	/// drop on the same stale map. Unlinks are rare (rate limited), so this cannot flood.
	private func announce() {
		guard isRunning, triggeredHello != nil else { return }
		sendHello()
	}

	private func record(_ kind: RelaySnapshot.LinkAction.Kind, _ neighbour: UUID) {
		let now = timers.now
		let age = links[neighbour]?.connectedAt.map { now - $0 }
		linkActions.append(RelaySnapshot.LinkAction(at: now, kind: kind, neighbour: neighbour, linkAge: age))
		if linkActions.count > RelayPolicy.linkActionHistory {
			linkActions.removeFirst(linkActions.count - RelayPolicy.linkActionHistory)
		}
	}

	// MARK: - Helpers

	/// Connected links in use (no unlink in progress): hellos go here.
	private var connectedLinks: [UUID] {
		links.filter { $0.value.isConnected && $0.value.unlink == nil }.keys.sorted(by: Self.order)
	}

	private func isLive(_ link: Link) -> Bool {
		link.isConnected && link.unlink == nil && timers.now - link.lastHeard < RelayPolicy.helloExpiry
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

	/// Same order as comparing `uuidString`s (hex digits sort like their values), without the strings.
	private static func order(_ a: UUID, _ b: UUID) -> Bool {
		key(a) < key(b)
	}

	private static func key(_ id: UUID) -> (UInt64, UInt64) {
		withUnsafeBytes(of: id.uuid) { bytes in
			(UInt64(bigEndian: bytes.loadUnaligned(as: UInt64.self)), UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
		}
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
	/// Map entries removed without a fresh hello for `helloExpiry`.
	var entriesExpired = 0
	var drops: [Drop: Int] = [:]
	/// Redundant links we unlinked.
	var voluntaryDrops = 0
	/// Silent links disconnected (`stalledDisconnect`).
	var stalledDisconnects = 0
	/// Links that connected into the bridge slot.
	var bridgeConnects = 0
	var unlinksSent = 0
	var unlinksReceived = 0
	/// Times the lower transport reset its wedged radio (`LinkDebugControl.radioResets`).
	var radioResets = 0

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

	/// Lower links (pending or connected) per slot kind.
	struct SlotUsage: Sendable, Equatable {
		let regular: Int
		let bridge: Int
		let capacity: LinkSlots
	}

	/// A link policy decision.
	struct LinkAction: Sendable, Equatable {
		enum Kind: String, Sendable {
			/// A link connected into the bridge slot.
			case bridge
			/// We unlinked a redundant neighbour.
			case drop
			/// A neighbour unlinked us.
			case unlinked
			/// A silent link was disconnected.
			case stalled
		}

		let at: Duration
		let kind: Kind
		let neighbour: UUID
		/// Since the link connected, nil if it never did.
		let linkAge: Duration?
	}

	/// The transport's clock when taken; `LinkAction.at` and entry ages relate to it.
	let now: Duration
	/// Direct neighbours counted as linked (connected and not silent).
	let neighbours: [UUID]
	/// Reachable devices, direct ones included, sorted by UUID.
	let reachable: [Route]
	let map: [Entry]
	let counters: RelayCounters
	let bufferedFrames: Int
	/// Nil without a link policy (lower transport without `LinkControl`).
	let slots: SlotUsage?
	/// Of our latest hello.
	let flags: RelayHello.Flags
	let suppressed: [UUID]
	let bridgeCandidates: [UUID]
	/// The latest `RelayPolicy.linkActionHistory` decisions, oldest first.
	let linkActions: [LinkAction]
}
