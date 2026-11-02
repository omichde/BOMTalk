//
//  SimNetwork.swift
//  BOMTalkTests
//

import Foundation
import MultipeerConnectivity
import Testing
@testable import BOMTalk

/// Timing and limits of the simulated radio.
struct SimConfig {
	/// One way delay of invitations, answers and data.
	var latency: Duration = .milliseconds(5)
	/// From an accepted invitation to `connected` on both sides.
	var handshake: Duration = .milliseconds(200)
	/// Until a browser reports a newly visible peer, drawn from the seeded generator.
	var discoveryDelay: ClosedRange<Duration> = .milliseconds(50) ... .milliseconds(300)
	/// Peers per session including this device, like `kMCSessionMaximumNumberOfPeers`.
	var sessionCapacity = 8
	/// Peer cap of each device's `MPCPeerMachine`; above `sessionCapacity - 1` the sim refuses instead.
	var maxPeers = MPCPolicy.maxRemotePeers
	/// Bytes per second per link and direction; data queues behind earlier data. Nil: unlimited.
	var bandwidth: Int?
	/// Relay generation per device index (`RelayPolicy.generation` for the others).
	var generations: [Int: Int] = [:]
	/// Time step of `run(for:)` / `run(until:)`.
	var step: Duration = .milliseconds(10)
	/// Main actor yields per step while any device has a `Talk`, so its tasks can run (otherwise one).
	var yields = 10
	/// Talk timeouts, on virtual time like everything else.
	var offerTimeout: Duration = .seconds(30)
	var chunkTimeout: Duration = .seconds(30)
	/// Talk's flow control window per outgoing transfer; `Int.max` turns flow control off.
	var window = FlowControl.window
}

/// Deterministic generator (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {

	private var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}

/// In-memory radio network of N devices on virtual time (`ManualTimers`), with MPC-like semantics:
///
/// - **Visibility** (radio range) is a symmetric graph. A running device's browser finds every running
///   visible device after a discovery delay and loses it when it stops, vanishes or gets hidden.
///   Hiding a pair also drops its session link (out of range).
/// - **Invitations** reach the invitee after `latency` if it is visible, otherwise they time out.
///   Decline or timeout reports `notConnected` to the inviter.
/// - **Sessions**: an accepted invitation creates a link, both sides report `connecting`, then
///   `connected` after `handshake`. The cap of `sessionCapacity` peers (including self) is checked on
///   both sides when accepting; beyond it the connection fails with `notConnected` on both sides.
/// - **Data** arrives after `latency`, in order per link; sending on a link that is not connected throws.
///   With `bandwidth`, each link direction is one FIFO queue: a frame goes out only after everything
///   sent before it on that link (hellos wait behind queued chunks, like in MPC's reliable queue).
///
/// Every callback goes through the timers, so it arrives on a later turn, like MPC's main-queue hop.
/// Nothing iterates hashed collections in an order-dependent way: same seed, same event order.
///
/// ```swift
/// let net = SimNetwork(count: 5, seed: 1)
/// net.fullMesh()
/// net.startAll()
/// await net.run(for: .seconds(10))
/// ```
@MainActor
final class SimNetwork {

	/// Builds the transport a device's `Talk` (or the test) talks to, on top of the link transport.
	/// The hook for decorators like a relay; the default is the link transport itself.
	typealias Wrap = @MainActor (_ link: LinkTransport<SimRadio>, _ timers: ManualTimers) -> any Transport

	/// A `RelayTransport` on virtual time: hello jitter seeded from the device's UUID, epoch from the
	/// virtual clock (ms).
	static let relay: Wrap = { link, timers in
		let seed = withUnsafeBytes(of: link.localPeer.id.uuid) { $0.loadUnaligned(as: UInt64.self) }
		return RelayTransport(lower: link, timers: timers, random: SeededGenerator(seed: seed)) {
			UInt64(SimNetwork.milliseconds(timers.now))
		}
	}

	private struct Pair: Hashable {
		let low: Int
		let high: Int

		init(_ a: Int, _ b: Int) {
			low = min(a, b)
			high = max(a, b)
		}

		func other(_ x: Int) -> Int { x == low ? high : low }
	}

	/// From a browser (or inviter) to the peer it sees (or invites).
	private struct Edge: Hashable {
		let from: Int
		let to: Int
	}

	private final class Link {
		var isConnected = false
		var isBlackholed = false
		/// Per sending device: when its queued data has gone out (with `bandwidth`).
		var busyUntil: [Int: Duration] = [:]
	}

	private struct Invite {
		let id: Int
		let timeout: TimerToken
	}

	/// A session link between two devices came up (`connected`) or a connected one went down.
	struct LinkChange: Equatable {
		let at: Duration
		let a: Int
		let b: Int
		let up: Bool
	}

	let timers = ManualTimers()
	let config: SimConfig
	private(set) var devices: [SimDevice] = []
	/// Transport events of all devices, `"<ms> d<i> <event> d<j>"`.
	private(set) var log: [String] = []
	/// Accepted invitations that failed because a session was full.
	private(set) var capRefusals = 0
	/// Every change of a connected session link, in order.
	private(set) var linkChanges: [LinkChange] = []
	/// Violations of the `TransportEvent` ordering rules by any device's top transport, see
	/// `TransportContract`. Each one is also recorded as a test issue.
	private(set) var contractViolations: [String] = []
	/// Data on a connected link for which this returns true is accepted but never delivered (single
	/// lost frames, e.g. acks).
	var loses: ((_ data: Data, _ from: Int, _ to: Int) -> Bool)?

	private var rng: SeededGenerator
	private var visible: Set<Pair> = []
	private var vanished: Set<Int> = []
	private var discovered: Set<Edge> = []
	private var pendingFound: [Edge: TimerToken] = [:]
	private var links: [Pair: Link] = [:]
	private var invites: [Edge: Invite] = [:]
	private var lastInvite = 0
	private var invitationCounts: [Pair: Int] = [:]

	/// - Parameters:
	///   - talk: Wraps every device in a `Talk` (not started).
	///   - wrap: Builds the transport above each link transport, see `Wrap`.
	init(count: Int, seed: UInt64 = 1, config: SimConfig = SimConfig(), talk: Bool = false, wrap: Wrap? = nil) {
		self.config = config
		rng = SeededGenerator(seed: seed)
		for index in 0 ..< count {
			let radio = SimRadio(index: index, network: self)
			let id = randomUUID()
			let link = LinkTransport(radio: radio, localID: id, displayName: radio.localHandle.description, appID: "de.werk01.sim", protocolVersion: 1, timers: timers, maxPeers: config.maxPeers, generation: config.generations[index] ?? RelayPolicy.generation)
			let transport = wrap?(link, timers) ?? link
			let talk = talk ? Talk(transport: transport, timers: timers, offerTimeout: config.offerTimeout, chunkTimeout: config.chunkTimeout, window: config.window) : nil
			devices.append(SimDevice(index: index, radio: radio, link: link, transport: transport, talk: talk, network: self))
		}
	}

	subscript(index: Int) -> SimDevice { devices[index] }

	var now: Duration { timers.now }

	func index(of id: UUID) -> Int? {
		devices.firstIndex { $0.id == id }
	}

	// MARK: - Visibility

	func see(_ a: Int, _ b: Int) {
		guard a != b else { return }
		visible.insert(Pair(a, b))
		refreshDiscovery()
	}

	/// Out of range: also drops the session link.
	func hide(_ a: Int, _ b: Int) {
		visible.remove(Pair(a, b))
		dropLink(Pair(a, b))
		refreshDiscovery()
	}

	func fullMesh(_ indices: [Int]? = nil) {
		let indices = indices ?? Array(devices.indices)
		for (n, a) in indices.enumerated() {
			for b in indices[(n + 1)...] {
				see(a, b)
			}
		}
	}

	func line(_ indices: [Int]? = nil) {
		let indices = indices ?? Array(devices.indices)
		for (a, b) in zip(indices, indices.dropFirst()) {
			see(a, b)
		}
	}

	func ring(_ indices: [Int]? = nil) {
		let indices = indices ?? Array(devices.indices)
		line(indices)
		if let first = indices.first, let last = indices.last, indices.count > 2 {
			see(last, first)
		}
	}

	/// Devices split in two halves, each a full mesh, joined by one pair (last of the first half,
	/// first of the second).
	func twoCliques() {
		let half = devices.count / 2
		let first = Array(0 ..< half), second = Array(half ..< devices.count)
		fullMesh(first)
		fullMesh(second)
		if let a = first.last, let b = second.first {
			see(a, b)
		}
	}

	/// Each pair sees each other with `probability`, drawn from the seeded generator.
	func random(probability: Double) {
		for a in devices.indices {
			for b in devices.indices where b > a {
				if Double.random(in: 0 ..< 1, using: &rng) < probability {
					see(a, b)
				}
			}
		}
	}

	/// A connected sparse graph, drawn from the seeded generator: a random spanning tree plus up to
	/// `extraEdges` random pairs, nobody seeing more than `maxDegree` others.
	func randomConnected(maxDegree: Int, extraEdges: Int) {
		var degree = Array(repeating: 0, count: devices.count)
		func connect(_ a: Int, _ b: Int) {
			see(a, b)
			degree[a] += 1
			degree[b] += 1
		}
		for b in devices.indices.dropFirst() {
			let candidates = (0 ..< b).filter { degree[$0] < maxDegree }
			connect(candidates[Int.random(in: candidates.indices, using: &rng)], b)
		}
		var added = 0, attempts = 0
		while added < extraEdges, attempts < extraEdges * 20 {
			attempts += 1
			let a = Int.random(in: devices.indices, using: &rng), b = Int.random(in: devices.indices, using: &rng)
			guard a != b, !isVisible(a, b), degree[a] < maxDegree, degree[b] < maxDegree else { continue }
			connect(a, b)
			added += 1
		}
	}

	/// Whether every device can reach every other over visible pairs.
	var isVisibilityConnected: Bool {
		var reached: Set<Int> = [0], queue = [0]
		while let a = queue.popLast() {
			for b in devices.indices where !reached.contains(b) && isVisible(a, b) {
				reached.insert(b)
				queue.append(b)
			}
		}
		return reached.count == devices.count
	}

	/// Visible others per device.
	func degree(_ index: Int) -> Int {
		devices.indices.count { isVisible(index, $0) }
	}

	func isVisible(_ a: Int, _ b: Int) -> Bool {
		visible.contains(Pair(a, b))
	}

	// MARK: - Lifecycle and faults

	func startAll() {
		devices.forEach { $0.start() }
	}

	/// Drops the session link: both sides report `notConnected`.
	func drop(_ a: Int, _ b: Int) {
		dropLink(Pair(a, b))
	}

	/// Data on the link is accepted but never delivered (a stalled link).
	func blackhole(_ a: Int, _ b: Int, _ on: Bool = true) {
		links[Pair(a, b)]?.isBlackholed = on
	}

	/// The device stops and is hidden from everyone until `reappear(_:)`.
	func vanish(_ index: Int) {
		vanished.insert(index)
		devices[index].stop()
		refreshDiscovery()
	}

	func reappear(_ index: Int) {
		vanished.remove(index)
		devices[index].start()
		refreshDiscovery()
	}

	/// Remote peers in the session of a device, connecting or connected.
	func sessionPeers(_ index: Int) -> [Int] {
		links.keys.filter { $0.low == index || $0.high == index }.map { $0.other(index) }.sorted()
	}

	func isConnected(_ a: Int, _ b: Int) -> Bool {
		links[Pair(a, b)]?.isConnected ?? false
	}

	/// Invitations sent between two devices so far, both directions.
	func invitations(_ a: Int, _ b: Int) -> Int {
		invitationCounts[Pair(a, b)] ?? 0
	}

	/// Invitations sent by anyone so far.
	var totalInvitations: Int {
		invitationCounts.values.reduce(0, +)
	}

	// MARK: - Running

	/// Fires everything due now and, with talks, yields to their tasks until nothing more is due.
	func settle() async {
		repeat {
			timers.advance(by: .zero)
			await yield()
		} while timers.hasDue
	}

	/// Advances virtual time in steps of `config.step`, settling after each.
	func run(for duration: Duration) async {
		let end = timers.now + duration
		await settle()
		while timers.now < end {
			timers.advance(by: min(config.step, end - timers.now))
			await settle()
		}
	}

	/// Runs until `condition` holds; false if `limit` (virtual) passes first.
	func run(until condition: () -> Bool, limit: Duration = .seconds(120)) async -> Bool {
		let end = timers.now + limit
		await settle()
		while !condition() {
			guard timers.now < end else { return false }
			timers.advance(by: config.step)
			await settle()
		}
		return true
	}

	/// Runs until `task` finished, then returns its value: a `Talk.send` completes only once the final
	/// ack arrived, which needs virtual time. Throws `SimError.timeout` if `limit` (virtual) passes first.
	func value<Success>(of task: Task<Success, any Error>, limit: Duration = .seconds(60)) async throws -> Success {
		var finished = false
		Task {
			_ = await task.result
			finished = true
		}
		guard await run(until: { finished }, limit: limit) else { throw SimError.timeout }
		return try await task.value
	}

	/// Without talks once, so long runs never hog the main actor (other suites' real-time tests).
	private func yield() async {
		guard devices.contains(where: { $0.talk != nil }) else { return await Task.yield() }
		for _ in 0 ..< config.yields {
			await Task.yield()
		}
	}

	// MARK: - Radio (called by `SimRadio`)

	func radioStarted(_ index: Int) {
		refreshDiscovery()
	}

	/// Like `MCSession.disconnect()` plus stopping advertiser and browser: remote peers report
	/// `notConnected` and lose the device; own pending invitations are withdrawn silently.
	func radioStopped(_ index: Int) {
		for edge in invites.keys.filter({ $0.from == index }).sorted(by: Self.edgeOrder) {
			invites.removeValue(forKey: edge)?.timeout.cancel()
		}
		for pair in links.keys.filter({ $0.low == index || $0.high == index }).sorted(by: Self.pairOrder) {
			dropLink(pair)
		}
		refreshDiscovery()
	}

	/// Browsers that see the device report it again with the new info.
	func advertiserRestarted(_ index: Int) {
		for browser in devices.indices where discovered.contains(Edge(from: browser, to: index)) {
			let edge = Edge(from: browser, to: index)
			post(browser, after: discoveryDelay()) { [unowned self] in
				guard discovered.contains(edge) else { return nil }
				return .found(devices[index].radio.localHandle, discoveryInfo: devices[index].radio.discoveryInfo)
			}
		}
	}

	func invite(from a: Int, to b: Int, context: Data?, timeout: TimeInterval) {
		let edge = Edge(from: a, to: b)
		invites.removeValue(forKey: edge)?.timeout.cancel()
		invitationCounts[Pair(a, b), default: 0] += 1
		lastInvite += 1
		let id = lastInvite
		let token = timers.schedule(after: .seconds(timeout)) { [unowned self] in
			guard invites[edge]?.id == id else { return }
			invites[edge] = nil
			post(a) { .state(SimHandle(index: b), .notConnected) }
		}
		invites[edge] = Invite(id: id, timeout: token)
		timers.schedule(after: config.latency) { [unowned self] in
			guard invites[edge]?.id == id, canSee(a, b) else { return }	// out of range: times out
			let target = devices[b].radio
			let reply: @MainActor (Bool) -> Void = { [unowned self] accept in
				answer(edge, id: id, accept: accept)
			}
			target.deliver(.invitation(SimHandle(index: a), context: context, reply: reply), run: target.run)
		}
	}

	/// Like `cancelConnectPeer`: withdraws a pending invitation and drops the link, pending or connected.
	func cancel(from a: Int, to b: Int) {
		if let invite = invites.removeValue(forKey: Edge(from: a, to: b)) {
			invite.timeout.cancel()
			post(a) { .state(SimHandle(index: b), .notConnected) }
		}
		dropLink(Pair(a, b))
	}

	func send(_ data: Data, from a: Int, to b: Int) throws {
		let pair = Pair(a, b)
		guard let link = links[pair], link.isConnected else { throw SimError.notConnected }
		guard !link.isBlackholed, loses?(data, a, b) != true else { return }
		var delay = config.latency
		if let bandwidth = config.bandwidth {
			let start = max(timers.now, link.busyUntil[a] ?? .zero)
			let done = start + .seconds(Double(data.count) / Double(bandwidth))
			link.busyUntil[a] = done
			delay += done - timers.now
		}
		post(b, after: delay) { [unowned self] in
			guard links[pair] === link, !link.isBlackholed else { return nil }
			return .data(data, from: SimHandle(index: a))
		}
	}

	// MARK: - Sessions

	private func answer(_ edge: Edge, id: Int, accept: Bool) {
		guard let invite = invites[edge], invite.id == id else { return }	// late, cancelled or replaced
		invite.timeout.cancel()
		invites[edge] = nil
		let (a, b) = (edge.from, edge.to)
		guard accept else {
			post(a, after: config.latency) { .state(SimHandle(index: b), .notConnected) }
			return
		}
		let pair = Pair(a, b)
		if links.removeValue(forKey: pair)?.isConnected == true {	// a fresh invitation replaces an old link silently
			linkChanges.append(LinkChange(at: timers.now, a: pair.low, b: pair.high, up: false))
		}
		guard sessionPeers(a).count < config.sessionCapacity - 1, sessionPeers(b).count < config.sessionCapacity - 1 else {
			capRefusals += 1
			post(a, after: config.handshake) { .state(SimHandle(index: b), .notConnected) }
			post(b, after: config.handshake) { .state(SimHandle(index: a), .notConnected) }
			return
		}
		let link = Link()
		links[pair] = link
		post(a, after: config.latency) { .state(SimHandle(index: b), .connecting) }
		post(b) { .state(SimHandle(index: a), .connecting) }
		timers.schedule(after: config.handshake) { [unowned self] in
			guard links[pair] === link else { return }
			link.isConnected = true
			linkChanges.append(LinkChange(at: timers.now, a: pair.low, b: pair.high, up: true))
			post(a) { .state(SimHandle(index: b), .connected) }
			post(b) { .state(SimHandle(index: a), .connected) }
		}
	}

	private func dropLink(_ pair: Pair) {
		guard let link = links.removeValue(forKey: pair) else { return }
		if link.isConnected {
			linkChanges.append(LinkChange(at: timers.now, a: pair.low, b: pair.high, up: false))
		}
		post(pair.low) { .state(SimHandle(index: pair.high), .notConnected) }
		post(pair.high) { .state(SimHandle(index: pair.low), .notConnected) }
	}

	// MARK: - Discovery

	private func canSee(_ a: Int, _ b: Int) -> Bool {
		a != b && devices[a].radio.isRunning && devices[b].radio.isRunning
			&& !vanished.contains(a) && !vanished.contains(b) && visible.contains(Pair(a, b))
	}

	/// Brings every browser in line with visibility and running state, in index order.
	private func refreshDiscovery() {
		for a in devices.indices {
			for b in devices.indices where b != a {
				let edge = Edge(from: a, to: b)
				if canSee(a, b) {
					guard !discovered.contains(edge), pendingFound[edge] == nil else { continue }
					pendingFound[edge] = timers.schedule(after: discoveryDelay()) { [unowned self] in
						pendingFound[edge] = nil
						guard canSee(a, b), discovered.insert(edge).inserted else { return }
						let radio = devices[a].radio
						radio.deliver(.found(SimHandle(index: b), discoveryInfo: devices[b].radio.discoveryInfo), run: radio.run)
					}
				} else {
					pendingFound.removeValue(forKey: edge)?.cancel()
					if discovered.remove(edge) != nil {
						post(a) { .lost(SimHandle(index: b)) }
					}
				}
			}
		}
	}

	// MARK: - Helpers

	/// Schedules a callback for the device's current run; `event` is evaluated when due, nil skips it.
	private func post(_ index: Int, after delay: Duration = .zero, _ event: @escaping @MainActor () -> LinkRadioEvent<SimHandle>?) {
		let radio = devices[index].radio
		let run = radio.run
		timers.schedule(after: delay) {
			guard let event = event() else { return }
			radio.deliver(event, run: run)
		}
	}

	private func discoveryDelay() -> Duration {
		let range = config.discoveryDelay
		let span = (range.upperBound - range.lowerBound) / .milliseconds(1)
		return range.lowerBound + .milliseconds(Int.random(in: 0 ... Int(span), using: &rng))
	}

	private func randomUUID() -> UUID {
		let bytes = (0 ..< 2).flatMap { _ in withUnsafeBytes(of: rng.next()) { Array($0) } }
		return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress) as UUID }
	}

	func record(_ line: String) {
		log.append("\(Self.milliseconds(timers.now)) \(line)")
	}

	func contractViolated(_ violation: String) {
		let line = "\(Self.milliseconds(timers.now)) \(violation)"
		contractViolations.append(line)
		Issue.record("transport contract violated: \(line)")
	}

	static func milliseconds(_ duration: Duration) -> Int64 {
		duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
	}

	private static func edgeOrder(_ x: Edge, _ y: Edge) -> Bool {
		(x.from, x.to) < (y.from, y.to)
	}

	private static func pairOrder(_ x: Pair, _ y: Pair) -> Bool {
		(x.low, x.high) < (y.low, y.high)
	}
}
