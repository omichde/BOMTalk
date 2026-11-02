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
	/// BOMTalk version per device index (`BOMTalkProtocol.version` for the others).
	var bomtalkVersions: [Int: Int] = [:]
	/// App protocol version per device index (1 for the others).
	var appVersions: [Int: Int] = [:]
	/// Time step of `run(for:)` / `run(until:)`.
	var step: Duration = .milliseconds(10)
	/// Main actor yields per step while any device has a `Talk`, so its tasks can run (otherwise one).
	var yields = 10
	/// Talk timeouts, on virtual time like everything else.
	var offerTimeout: Duration = .seconds(30)
	var chunkTimeout: Duration = .seconds(30)
	/// Talk's flow control window per outgoing transfer; `Int.max` turns flow control off.
	var window = FlowControl.window
	/// … and over all transfers to one peer.
	var peerWindow = FlowControl.peerWindow

	// MARK: MPC failure modes seen in simulator rig runs (all off by default)

	/// A new handle on every start, like `MPCRadio` (fresh `MCPeerID` per start). False: one handle for
	/// all runs, like the archived peer id before.
	var freshHandles = true
	/// How long a remote takes to notice that a device stopped (MPC reports an abrupt loss late). Until
	/// then its link stays up on the remote's side: sending succeeds, nothing arrives. Nil: at once.
	var lossDetection: Duration?
	/// After a device stopped, invitations between a remote that had a session link or a pending
	/// invitation with it and the same handle hang this long (MPC on the remote still holds the old session for that peer id,
	/// `GCKSession … Timed out, enforcing clean up`). Nil: no stale sessions.
	var staleSession: Duration?
	/// Probability that an invitation is never answered: neither the invitee nor the inviter hears
	/// anything, not even the invitation timeout (the peer machine's watchdog ends it).
	var hangProbability = 0.0
	/// Probability that an accepted invitation ends half open: the invitee reports `connected` but
	/// nothing passes the link, the inviter reports `notConnected` after the handshake.
	var halfOpenProbability = 0.0
	/// Devices whose session wedges when a linked remote stops abruptly: from then on every
	/// invitation from or to the device hangs (like `hangProbability`) until its radio restarts.
	/// Rig runs: one device's attempts with everyone hung for minutes after such a loss. See also
	/// `SimNetwork.wedge(_:)`.
	var wedgeOnAbruptLoss: Set<Int> = []
	/// A wedged session still answers declines: only accepted invitations from or to it hang. Rig runs
	/// (heal, cap 2): the wedged pair got quick declines from full devices, every accepted attempt hung.
	var wedgeAnswersDeclines = false
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
/// - **Handles**: a session link, an invitation and a sighting belong to the handles the devices had
///   then; a device that restarted with a fresh handle is a different peer on the radio.
/// - **Failure modes** (`SimConfig`, off by default): late loss detection, stale sessions after a
///   restart with the same handle, hanging invitations, half-open links, wedged sessions.
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
		/// Handle of each end when the link was created.
		let handles: [Int: SimHandle]
		var isConnected = false
		var isBlackholed = false
		/// Half open (`halfOpenProbability`): only this end, the invitee, has the link.
		var halfOpenEnd: Int?

		var isHalfOpen: Bool { halfOpenEnd != nil }
		/// Per sending device: when its queued data has gone out (with `bandwidth`).
		var busyUntil: [Int: Duration] = [:]

		init(handles: [Int: SimHandle]) {
			self.handles = handles
		}
	}

	private struct Invite {
		let id: Int
		let timeout: TimerToken?
		let from: SimHandle
		let target: SimHandle
	}

	/// A device and a handle of another device it had a session link with.
	private struct Remote: Hashable {
		let index: Int
		let handle: SimHandle
	}

	/// A session link between two devices came up (`connected`) or a connected one went down.
	struct LinkChange: Equatable {
		let at: Duration
		let a: Int
		let b: Int
		let up: Bool
	}

	let timers = ManualTimers()
	/// Failure probabilities may change while running.
	var config: SimConfig
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
	/// Sightings by browser and the handle reported.
	private var discovered: [Edge: SimHandle] = [:]
	private var pendingFound: [Edge: TimerToken] = [:]
	private var links: [Pair: Link] = [:]
	private var invites: [Edge: Invite] = [:]
	private var lastInvite = 0
	private var invitationCounts: [Pair: Int] = [:]
	/// Links of stopped devices that their remotes have not noticed yet (`lossDetection`).
	private var orphans: [Remote: TimerToken] = [:]
	/// Until when invitations between a remote and a handle hang (`staleSession`).
	private var stale: [Remote: Duration] = [:]
	/// Devices whose session is wedged until their radio restarts (`wedgeOnAbruptLoss`, `wedge(_:)`).
	private(set) var wedged: Set<Int> = []
	/// Invitations that hung (stale session or `hangProbability`), half-open links.
	private(set) var hungInvitations = 0
	private(set) var halfOpenLinks = 0

	/// - Parameters:
	///   - talk: Wraps every device in a `Talk` (not started).
	///   - wrap: Builds the transport above each link transport, see `Wrap`.
	init(count: Int, seed: UInt64 = 1, config: SimConfig = SimConfig(), talk: Bool = false, wrap: Wrap? = nil) {
		self.config = config
		rng = SeededGenerator(seed: seed)
		for index in 0 ..< count {
			let radio = SimRadio(index: index, network: self)
			let id = randomUUID()
			let link = LinkTransport(radio: radio, localID: id, displayName: radio.localHandle.description, appID: "de.werk01.sim", protocolVersion: config.appVersions[index] ?? 1, timers: timers, maxPeers: config.maxPeers, bomtalkVersion: config.bomtalkVersions[index] ?? BOMTalkProtocol.version)
			let transport = wrap?(link, timers) ?? link
			let talk = talk ? Talk(transport: transport, timers: timers, offerTimeout: config.offerTimeout, chunkTimeout: config.chunkTimeout, window: config.window, peerWindow: config.peerWindow) : nil
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

	/// Wedges the device's session: every invitation from or to it hangs until its radio stops (a
	/// stop and start of the device, or a radio reset by its link transport).
	func wedge(_ index: Int) {
		wedged.insert(index)
	}

	/// Remote peers in the session of a device, connecting or connected.
	func sessionPeers(_ index: Int) -> [Int] {
		links.keys.filter { $0.low == index || $0.high == index }.map { $0.other(index) }.sorted()
	}

	/// Session slots in use on a device: its links plus links of stopped devices it has not noticed.
	private func sessionLoad(_ index: Int) -> Int {
		sessionPeers(index).count + orphans.keys.count { $0.index == index }
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
	/// With `lossDetection`, remotes keep their side of each link for that long (`orphans`); with
	/// `staleSession`, invitations between the device's handle and remotes it had a link or a pending
	/// invitation with hang for that long.
	func radioStopped(_ index: Int) {
		wedged.remove(index)
		for edge in invites.keys.filter({ $0.from == index || $0.to == index }).sorted(by: Self.edgeOrder) {
			guard let invite = invites[edge] else { continue }
			if let staleSession = config.staleSession {
				let (remote, handle) = edge.from == index ? (edge.to, invite.from) : (edge.from, invite.target)
				stale[Remote(index: remote, handle: handle)] = timers.now + staleSession
			}
			if edge.from == index {
				invites.removeValue(forKey: edge)?.timeout?.cancel()
			}
		}
		for remote in orphans.keys.filter({ $0.index == index }) {
			orphans.removeValue(forKey: remote)?.cancel()
		}
		for pair in links.keys.filter({ $0.low == index || $0.high == index }).sorted(by: Self.pairOrder) {
			guard let link = links[pair], let handle = link.handles[index] else { continue }
			let other = pair.other(index)
			if config.wedgeOnAbruptLoss.contains(other) {
				wedged.insert(other)
			}
			if let staleSession = config.staleSession {
				stale[Remote(index: other, handle: handle)] = timers.now + staleSession
			}
			guard let lossDetection = config.lossDetection, (link.halfOpenEnd ?? other) == other else {
				dropLink(pair)
				continue
			}
			links[pair] = nil
			if link.isConnected, !link.isHalfOpen {
				linkChanges.append(LinkChange(at: timers.now, a: pair.low, b: pair.high, up: false))
			}
			let remote = Remote(index: other, handle: handle)
			orphans[remote] = timers.schedule(after: lossDetection) { [unowned self] in
				guard orphans.removeValue(forKey: remote) != nil else { return }
				post(other) { .state(handle, .notConnected) }
			}
		}
		refreshDiscovery()
	}

	/// Browsers that see the device report it again with the new info.
	func advertiserRestarted(_ index: Int) {
		for browser in devices.indices where discovered[Edge(from: browser, to: index)] != nil {
			let edge = Edge(from: browser, to: index)
			post(browser, after: discoveryDelay()) { [unowned self] in
				guard let handle = discovered[edge] else { return nil }
				return .found(handle, discoveryInfo: devices[index].radio.discoveryInfo)
			}
		}
	}

	/// Invites `target`; an outdated handle of a device (it restarted with a fresh one) times out.
	func invite(from a: Int, to target: SimHandle, context: Data?, timeout: TimeInterval) {
		let b = target.index
		let edge = Edge(from: a, to: b)
		invites.removeValue(forKey: edge)?.timeout?.cancel()
		invitationCounts[Pair(a, b), default: 0] += 1
		lastInvite += 1
		let id = lastInvite
		let from = handle(a)
		guard !hangs(from: from, to: target, wedgedToo: !config.wedgeAnswersDeclines) else {
			hungInvitations += 1
			invites[edge] = Invite(id: id, timeout: nil, from: from, target: target)	// silent until cancelled
			return
		}
		let token = timers.schedule(after: .seconds(timeout)) { [unowned self] in
			guard invites[edge]?.id == id else { return }
			invites[edge] = nil
			post(a) { .state(target, .notConnected) }
		}
		invites[edge] = Invite(id: id, timeout: token, from: from, target: target)
		timers.schedule(after: config.latency) { [unowned self] in
			guard invites[edge]?.id == id, canSee(a, b), handle(b) == target else { return }	// out of range: times out
			let radio = devices[b].radio
			let reply: @MainActor (Bool) -> Void = { [unowned self] accept in
				answer(edge, id: id, accept: accept)
			}
			radio.deliver(.invitation(from, context: context, reply: reply), run: radio.run)
		}
	}

	/// Like `cancelConnectPeer`: withdraws a pending invitation and drops the link, pending or connected,
	/// as far as they belong to `target`.
	func cancel(from a: Int, to target: SimHandle) {
		let b = target.index
		if let invite = invites[Edge(from: a, to: b)], invite.target == target {
			invites[Edge(from: a, to: b)] = nil
			invite.timeout?.cancel()
			post(a) { .state(target, .notConnected) }
		}
		if let orphan = orphans.removeValue(forKey: Remote(index: a, handle: target)) {
			orphan.cancel()
			post(a) { .state(target, .notConnected) }
		}
		if links[Pair(a, b)]?.handles[b] == target {
			dropLink(Pair(a, b))
		}
	}

	func send(_ data: Data, from a: Int, to target: SimHandle) throws {
		let b = target.index
		let pair = Pair(a, b)
		guard orphans[Remote(index: a, handle: target)] == nil else { return }	// the remote has not noticed yet
		guard let link = links[pair], link.isConnected, link.handles[b] == target else { throw SimError.notConnected }
		guard !link.isBlackholed, loses?(data, a, b) != true else { return }
		var delay = config.latency
		if let bandwidth = config.bandwidth {
			let start = max(timers.now, link.busyUntil[a] ?? .zero)
			let done = start + .seconds(Double(data.count) / Double(bandwidth))
			link.busyUntil[a] = done
			delay += done - timers.now
		}
		let from = link.handles[a] ?? handle(a)
		post(b, after: delay) { [unowned self] in
			guard links[pair] === link, !link.isBlackholed else { return nil }
			return .data(data, from: from)
		}
	}

	// MARK: - Sessions

	private func answer(_ edge: Edge, id: Int, accept: Bool) {
		guard let invite = invites[edge], invite.id == id else { return }	// late, cancelled or replaced
		invite.timeout?.cancel()
		invites[edge] = nil
		let (a, b) = (edge.from, edge.to)
		let (from, target) = (invite.from, invite.target)
		guard accept else {
			post(a, after: config.latency) { .state(target, .notConnected) }
			return
		}
		if config.wedgeAnswersDeclines, wedged.contains(a) || wedged.contains(b) {	// silent until cancelled
			hungInvitations += 1
			invites[edge] = Invite(id: id, timeout: nil, from: from, target: target)
			return
		}
		let pair = Pair(a, b)
		if let old = links.removeValue(forKey: pair), old.isConnected, !old.isHalfOpen {	// a fresh invitation replaces an old link silently
			linkChanges.append(LinkChange(at: timers.now, a: pair.low, b: pair.high, up: false))
		}
		guard sessionLoad(a) < config.sessionCapacity - 1, sessionLoad(b) < config.sessionCapacity - 1 else {
			capRefusals += 1
			post(a, after: config.handshake) { .state(target, .notConnected) }
			post(b, after: config.handshake) { .state(from, .notConnected) }
			return
		}
		let link = Link(handles: [a: from, b: target])
		links[pair] = link
		post(a, after: config.latency) { .state(target, .connecting) }
		post(b) { .state(from, .connecting) }
		if config.halfOpenProbability > 0, Double.random(in: 0 ..< 1, using: &rng) < config.halfOpenProbability {
			halfOpenLinks += 1
			link.halfOpenEnd = b
			link.isBlackholed = true
			timers.schedule(after: config.handshake) { [unowned self] in
				guard links[pair] === link else { return }
				link.isConnected = true
				post(a) { .state(target, .notConnected) }
				post(b) { .state(from, .connected) }
			}
			return
		}
		timers.schedule(after: config.handshake) { [unowned self] in
			guard links[pair] === link else { return }
			link.isConnected = true
			linkChanges.append(LinkChange(at: timers.now, a: pair.low, b: pair.high, up: true))
			post(a) { .state(target, .connected) }
			post(b) { .state(from, .connected) }
		}
	}

	/// Both sides report `notConnected`; a half-open link only on the side that had it.
	private func dropLink(_ pair: Pair) {
		guard let link = links.removeValue(forKey: pair) else { return }
		if link.isConnected, !link.isHalfOpen {
			linkChanges.append(LinkChange(at: timers.now, a: pair.low, b: pair.high, up: false))
		}
		for (index, other) in [(pair.low, pair.high), (pair.high, pair.low)] {
			guard let handle = link.handles[other] else { continue }
			if let end = link.halfOpenEnd, end != index {
				continue
			}
			post(index) { .state(handle, .notConnected) }
		}
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
					guard discovered[edge] == nil, pendingFound[edge] == nil else { continue }
					pendingFound[edge] = timers.schedule(after: discoveryDelay()) { [unowned self] in
						pendingFound[edge] = nil
						guard canSee(a, b), discovered[edge] == nil else { return }
						let handle = handle(b)
						discovered[edge] = handle
						let radio = devices[a].radio
						radio.deliver(.found(handle, discoveryInfo: devices[b].radio.discoveryInfo), run: radio.run)
					}
				} else {
					pendingFound.removeValue(forKey: edge)?.cancel()
					if let handle = discovered.removeValue(forKey: edge) {
						post(a) { .lost(handle) }
					}
				}
			}
		}
	}

	// MARK: - Helpers

	/// The device's current handle.
	private func handle(_ index: Int) -> SimHandle {
		devices[index].radio.localHandle
	}

	/// A wedged session (unless `wedgedToo` is false) or a stale one on either side, or bad luck
	/// (`hangProbability`).
	private func hangs(from: SimHandle, to target: SimHandle, wedgedToo: Bool) -> Bool {
		let now = timers.now
		if wedgedToo, wedged.contains(from.index) || wedged.contains(target.index) {
			return true
		}
		if let until = stale[Remote(index: target.index, handle: from)], until > now {
			return true
		}
		if let until = stale[Remote(index: from.index, handle: target)], until > now {
			return true
		}
		return config.hangProbability > 0 && Double.random(in: 0 ..< 1, using: &rng) < config.hangProbability
	}

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
