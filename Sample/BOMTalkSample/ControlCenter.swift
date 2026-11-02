//
//  ControlCenter.swift
//  BOMTalkSample
//

import Foundation
import Combine
@_spi(Debug) import BOMTalk

/// Measures the main actor from both sides: a main actor loop records how late its timer fires
/// (`ControlCenter` keeps the `LagStats`) and beats; a timer on a background queue notices when the
/// beats stop altogether and writes `main.stall` events while the stall lasts. A frozen main actor
/// shows up in the log as it happens, a suspended app (no stall events either) does not.
final class MainActorProbe: @unchecked Sendable {

	static let interval: Duration = .milliseconds(500)
	/// No beat for this long counts as a stall …
	static let stallAfter: TimeInterval = 2
	/// … reported again at this interval while it lasts.
	static let stallRepeat: TimeInterval = 10

	private let events: EventLog
	private let lock = NSLock()
	/// Only under `lock`.
	private var lastBeat = ContinuousClock.now
	private let queue = DispatchQueue(label: "de.werk01.BOMTalkSample.probe", qos: .utility)
	// only on `queue`
	private var timer: (any DispatchSourceTimer)?
	private var stallReported: ContinuousClock.Instant?

	init(events: EventLog) {
		self.events = events
	}

	/// Seconds since the main actor last beat.
	var silence: Double {
		let beat = lock.withLock { lastBeat }
		return ControlCenter.seconds(ContinuousClock.now - beat)
	}

	/// Called on the main actor by the measuring loop.
	func beat() {
		lock.withLock { lastBeat = .now }
	}

	func startWatchdog() {
		queue.async { [self] in
			guard timer == nil else { return }
			let timer = DispatchSource.makeTimerSource(queue: queue)
			timer.schedule(deadline: .now() + 1, repeating: 1)
			timer.setEventHandler { [weak self] in self?.check() }
			self.timer = timer
			timer.resume()
		}
	}

	// MARK: - on `queue`

	private func check() {
		let silence = silence
		guard silence >= Self.stallAfter else {
			stallReported = nil
			return
		}
		if let reported = stallReported, ControlCenter.seconds(ContinuousClock.now - reported) < Self.stallRepeat {
			return
		}
		stallReported = .now
		events.record("main.stall", ["silentMs": (silence * 1000).rounded()])
	}
}

/// Counters of the Sample's own traffic, for `GET /state`.
struct TransferStats: Encodable, Equatable, Sendable {

	struct Item: Encodable, Equatable {
		let at: Double
		/// `sent` or `received`.
		let direction: String
		let peer: String
		let megabytes: Int?
		let bytes: Int?
		let seconds: Double?
		let error: String?
	}

	private(set) var sent = 0
	private(set) var sendFailed = 0
	private(set) var received = 0
	private(set) var receiveFailed = 0
	private(set) var receivedBytes = 0
	var chatReceived = 0
	/// The latest 20 blob results, oldest first.
	private(set) var recent: [Item] = []

	mutating func noteSent(peer: String, mb: Int, seconds: Double, error: String?) {
		if error == nil { sent += 1 } else { sendFailed += 1 }
		add(Item(at: Date().timeIntervalSince1970, direction: "sent", peer: peer, megabytes: mb, bytes: nil, seconds: seconds, error: error))
	}

	mutating func noteReceived(peer: String, bytes: Int) {
		received += 1
		receivedBytes += bytes
		add(Item(at: Date().timeIntervalSince1970, direction: "received", peer: peer, megabytes: nil, bytes: bytes, seconds: nil, error: nil))
	}

	mutating func noteReceiveFailed() {
		receiveFailed += 1
	}

	private mutating func add(_ item: Item) {
		recent.append(item)
		if recent.count > 20 {
			recent.removeFirst(recent.count - 20)
		}
	}
}

/// The debug control layer of the Sample: `GET /state`, `POST /command`, event log, soak pings. Only
/// created with launch arguments (`-controlPort`, `-soak`, see `LaunchOptions`); a normal run never
/// sees it. All state lives on the main actor; the HTTP listener and the log file have their own
/// queues and only hop here for `Talk` access.
@MainActor
final class ControlCenter {

	private struct Ping {
		var sent = 0
		var recipients = 0
		var delivered = 0
		var failures: [String: Int] = [:]
	}

	private struct SoakInfo: Encodable, Sendable {
		let enabled: Bool
		let nextSeq: Int
		let sent: Int
		let recipients: Int
		let delivered: Int
		let failures: [String: Int]
		let origins: [String: OriginStats]
	}

	private struct AppInfo: Encodable, Sendable {
		let label: String
		let runID: String
		let pid: Int32
		let platform: String
		let version: String
		let time: Double
		let uptime: Double
		let isRunning: Bool
		let wantsRunning: Bool
		let darkSecondsLeft: Double?
		let eventLog: String
		let controlPort: UInt16?
		let linkCap: Int?
		let ephemeral: Bool
		let soak: Bool
		let soakBlobMB: Int?
		/// Main actor delays since launch or the last `resetStats`.
		let mainLag: LagStats
	}

	private struct SampleInfo: Encodable, Sendable {
		let soak: SoakInfo
		let transfers: TransferStats
		let acceptBlobs: Bool
		let sendingBlob: [String]
	}

	private struct StateResponse: Encodable, Sendable {
		let app: AppInfo
		let talk: TalkDebugSnapshot
		let sample: SampleInfo
	}

	private unowned let model: DemoModel
	private let options: LaunchOptions
	let events: EventLog
	private let launched = ContinuousClock.now
	private var server: ControlServer?
	private var activity: (any NSObjectProtocol)?
	private var bag = Set<AnyCancellable>()
	private var pollTask: Task<Void, Never>?
	private var probeTask: Task<Void, Never>?
	let probe: MainActorProbe
	private var lag = LagStats()
	/// Since the last summary.
	private var lagWindow = LagStats()
	/// Replies to commands with a `requestID`, so a retried command runs once (oldest first).
	private var replies: [String: [String: Any]] = [:]
	private var replyOrder: [String] = []
	private var inFlight: Set<String> = []
	private var soakTask: Task<Void, Never>?
	private var darkTask: Task<Void, Never>?
	private var darkUntil: ContinuousClock.Instant?

	private var soakEnabled = false
	private var nextSeq = 1
	private var ping = Ping()
	private var origins: [String: OriginStats] = [:]

	// what the last poll saw, to log changes only
	private var seenPeers: [UUID: (state: String, hops: Int?)] = [:]
	private var seenNeighbours: Set<UUID> = []
	private var seenActions: Set<String> = []
	private var seenTransfers: [UUID: TalkDebugSnapshot.TransferInfo] = [:]
	private var seenIssue: String?
	private var seenRunning: Bool?
	private var seenRadioResets = 0
	private var loggedCounters: [String: Int] = [:]
	private var loggedOrigins: [String: OriginStats] = [:]
	private var pollCount = 0

	static let pollInterval: Duration = .seconds(1)
	static let soakInterval: Duration = .seconds(3)
	/// Counter and ping stat deltas go to the event log this often (polls).
	static let summaryEvery = 10
	/// A soak blob goes out every this many pings (30 s).
	static let soakBlobEvery = 10
	/// Replies kept for retried commands.
	static let keptReplies = 64

	init(model: DemoModel, options: LaunchOptions) {
		self.model = model
		self.options = options
		let label = model.talk.me.name
		// ephemeral instances run side by side on a Mac and share one Documents folder
		let fileName = options.ephemeral ? "bomtalk-events-\(Self.fileSafe(label)).jsonl" : EventLog.defaultFileName
		events = EventLog(fileName: fileName, runID: options.runID, label: label)
		probe = MainActorProbe(events: events)
	}

	private var talk: Talk { model.talk }

	/// Letters, digits, `-` and `_` only.
	static func fileSafe(_ name: String) -> String {
		String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
	}

	// MARK: - Lifecycle

	func start() {
		// no App Nap for a background macOS instance, no idle sleep during a long run
		activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "BOMTalk control layer")
		log("app.start", [
			"pid": ProcessInfo.processInfo.processIdentifier,
			"platform": Self.platform,
			"controlPort": options.controlPort.map { Int($0) } ?? NSNull(),
			"linkCap": options.linkCap ?? NSNull(),
			"ephemeral": options.ephemeral,
			"blocked": options.blocked.sorted(),
			"soak": options.soak,
			"soakBlobMB": options.soakBlobMB ?? NSNull(),
		])
		probe.startWatchdog()
		probeTask = Task { [weak self] in
			while !Task.isCancelled {
				let start = ContinuousClock.now
				try? await Task.sleep(for: MainActorProbe.interval)
				guard let self else { return }
				probe.beat()
				noteLag(Self.seconds(ContinuousClock.now - start - MainActorProbe.interval) * 1000)
			}
		}
		if let port = options.controlPort {
			let server = ControlServer(port: port, handler: { [weak self] request in
				await self?.handle(request) ?? .error(503, "shutting down")
			}, busy: { [probe] request in
				// the state is polled; a command must not be answered before it ran
				request.method == "GET" && request.path == "/state" ? .busy(mainSilentSeconds: probe.silence) : nil
			}, log: { [events] message in
				events.record("control.log", ["message": message])
			})
			self.server = server
			server.start()
		}
		pollTask = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: Self.pollInterval)
				self?.poll()
			}
		}
		if options.soak {
			setSoak(true)
		}
	}

	/// Called with every new `Talk` (rename), subscribes to the pings.
	func attach(_ talk: Talk) {
		bag.removeAll()
		talk.messages(SoakPing.self)
			.sink { [weak self] result in
				guard let self else { return }
				switch result {
				case .success(let received):
					receivedPing(received.message)
				case .failure(let error):
					log("receive.failed", ["kind": SoakPing.kind, "error": "\(error)"])
				}
			}
			.store(in: &bag)
	}

	func log(_ type: String, _ fields: [String: Any] = [:]) {
		events.record(type, fields)
	}

	// MARK: - Soak

	private func setSoak(_ on: Bool) {
		guard on != soakEnabled else { return }
		soakEnabled = on
		soakTask?.cancel()
		soakTask = nil
		log("soak", ["enabled": on])
		guard on else { return }
		soakTask = Task { [weak self] in
			var tick = 0
			while !Task.isCancelled {
				try? await Task.sleep(for: Self.soakInterval)
				guard let self, !Task.isCancelled else { return }
				guard talk.isRunning else { continue }
				tick += 1
				Task { await self.sendPing() }
				if let megabytes = options.soakBlobMB, tick % Self.soakBlobEvery == 0 {
					sendSoakBlob(megabytes: megabytes)
				}
			}
		}
	}

	/// Broadcasts the next numbered ping.
	@discardableResult
	private func sendPing() async -> (seq: Int, recipients: Int, delivered: Int, failed: [String: String]) {
		let seq = nextSeq
		nextSeq += 1
		let message = SoakPing(origin: talk.me.name, seq: seq, sentAt: Date().timeIntervalSince1970)
		let results = await talk.send(message)
		var failed: [String: String] = [:]
		var delivered = 0
		for (id, result) in results {
			switch result {
			case .success:
				delivered += 1
			case .failure(let error):
				failed[model.name(of: id)] = "\(error)"
				ping.failures["\(error)", default: 0] += 1
			}
		}
		ping.sent += 1
		ping.recipients += results.count
		ping.delivered += delivered
		return (seq, results.count, delivered, failed)
	}

	private func sendSoakBlob(megabytes: Int) {
		let candidates = talk.peers.filter { $0.state == .connected && !model.sendingBlob.contains($0.id) }
		guard let peer = candidates.randomElement() else { return }
		Task { await model.sendBlob(to: peer, megabytes: megabytes) }
	}

	private func receivedPing(_ message: SoakPing) {
		origins[message.origin, default: OriginStats()].record(seq: message.seq, sentAt: message.sentAt, receivedAt: Date().timeIntervalSince1970)
	}

	// MARK: - Main actor lag

	private func noteLag(_ milliseconds: Double) {
		lag.record(milliseconds)
		lagWindow.record(milliseconds)
		if milliseconds >= 1000 {
			log("main.lag.spike", ["ms": milliseconds.rounded()])
		}
	}

	// MARK: - Event log from polling

	private func poll() {
		pollCount += 1
		let snapshot = talk.debugSnapshot()
		if seenRunning != snapshot.isRunning {
			seenRunning = snapshot.isRunning
			log("talk.running", ["isRunning": snapshot.isRunning, "wants": model.wantsRunning])
		}
		if seenIssue != snapshot.issue {
			seenIssue = snapshot.issue
			log("talk.issue", ["issue": snapshot.issue ?? NSNull()])
		}
		if seenRadioResets != snapshot.counters.radioResets {
			seenRadioResets = snapshot.counters.radioResets
			log("radio.reset", ["resets": snapshot.counters.radioResets])
		}

		for peer in snapshot.peers {
			lastNames[peer.id] = peer.name
		}
		for device in snapshot.neighbours {
			lastNames[device.id] = device.name
		}
		let hops = Dictionary(snapshot.reachable.map { ($0.id, $0.hops) }, uniquingKeysWith: { first, _ in first })
		var peers: [UUID: (state: String, hops: Int?)] = [:]
		for peer in snapshot.peers {
			let now = (state: peer.state, hops: hops[peer.id])
			peers[peer.id] = now
			let before = seenPeers[peer.id]
			if before?.state != now.state {
				log("peer", ["id": peer.id.uuidString, "name": peer.name, "state": peer.state, "from": before?.state ?? "gone", "hops": now.hops ?? NSNull()])
			} else if before?.hops != now.hops {
				log("route", ["id": peer.id.uuidString, "name": peer.name, "hops": now.hops ?? NSNull(), "from": before?.hops ?? NSNull()])
			}
		}
		for (id, before) in seenPeers where peers[id] == nil {
			log("peer", ["id": id.uuidString, "name": nameInLastSnapshot(id), "state": "gone", "from": before.state])
		}
		seenPeers = peers

		let neighbours = Set(snapshot.neighbours.map(\.id))
		for device in snapshot.neighbours where !seenNeighbours.contains(device.id) {
			log("neighbour", ["id": device.id.uuidString, "name": device.name, "linked": true])	// not "up": the uptime field
		}
		for id in seenNeighbours.subtracting(neighbours) {
			log("neighbour", ["id": id.uuidString, "name": nameInLastSnapshot(id), "linked": false])
		}
		seenNeighbours = neighbours

		for action in snapshot.linkActions {
			let key = "\(action.kind)/\(action.neighbour)/\(action.at)"
			if seenActions.insert(key).inserted {
				log("link.action", ["kind": action.kind, "neighbour": action.neighbour.uuidString, "linkAge": action.linkAge ?? NSNull()])
			}
		}
		if seenActions.count > 256 {
			seenActions = Set(snapshot.linkActions.map { "\($0.kind)/\($0.neighbour)/\($0.at)" })
		}

		var transfers: [UUID: TalkDebugSnapshot.TransferInfo] = [:]
		for transfer in snapshot.transfers {
			transfers[transfer.id] = transfer
			if seenTransfers[transfer.id] == nil {
				log("transfer.started", Self.fields(of: transfer))
			}
		}
		for (id, transfer) in seenTransfers where transfers[id] == nil {
			log("transfer.ended", Self.fields(of: transfer))
		}
		seenTransfers = transfers

		if pollCount % Self.summaryEvery == 0 {
			logSummaries(snapshot)
		}
	}

	private var lastNames: [UUID: String] = [:]

	private func nameInLastSnapshot(_ id: UUID) -> String {
		lastNames[id] ?? ""
	}

	private func logSummaries(_ snapshot: TalkDebugSnapshot) {
		let counters = snapshot.counters
		var now: [String: Int] = [
			"hellosForwarded": counters.hellosForwarded,
			"dataForwarded": counters.dataForwarded,
			"entriesExpired": counters.entriesExpired,
			"voluntaryDrops": counters.voluntaryDrops,
			"stalledDisconnects": counters.stalledDisconnects,
			"bridgeConnects": counters.bridgeConnects,
			"unlinksSent": counters.unlinksSent,
			"unlinksReceived": counters.unlinksReceived,
			"radioResets": counters.radioResets,
		]
		for (reason, count) in counters.drops {
			now["drop.\(reason)"] = count
		}
		var changed: [String: Int] = [:]
		for (key, value) in now where value != loggedCounters[key, default: 0] {
			changed[key] = value - loggedCounters[key, default: 0]
		}
		if !changed.isEmpty {
			log("relay.counters", ["delta": changed, "reachable": snapshot.reachable.count, "neighbours": snapshot.neighbours.count])
		}
		loggedCounters = now
		log("main.lag", ["samples": lagWindow.samples, "avgMs": (lagWindow.avgMs * 10).rounded() / 10, "maxMs": lagWindow.maxMs.rounded(), "over250ms": lagWindow.over250ms])
		lagWindow = LagStats()

		for (origin, stats) in origins.sorted(by: { $0.key < $1.key }) where stats != loggedOrigins[origin] {
			let before = loggedOrigins[origin] ?? OriginStats()
			log("soak.stats", [
				"origin": origin,
				"received": stats.received,
				"receivedDelta": stats.received - before.received,
				"duplicates": stats.duplicates,
				"outOfOrder": stats.outOfOrder,
				"gaps": stats.gaps,
				"lastSeq": stats.lastSeq,
				"latencyAvgMs": stats.latencyAvgMs.rounded(),
				"latencyMaxMs": stats.latencyMaxMs.rounded(),
			])
			loggedOrigins[origin] = stats
		}
	}

	private static func fields(of transfer: TalkDebugSnapshot.TransferInfo) -> [String: Any] {
		["id": transfer.id.uuidString, "peer": transfer.peer.uuidString, "kind": transfer.kind, "direction": transfer.direction, "completedBytes": transfer.completedBytes, "totalBytes": transfer.totalBytes]
	}

	// MARK: - HTTP

	func handle(_ request: HTTPRequest) async -> HTTPResponse {
		switch (request.method, request.path) {
		case ("GET", "/state"):
			return await state()
		case ("POST", "/command"):
			return await command(request.body)
		case (_, "/state"):
			return .error(405, "use GET")
		case (_, "/command"):
			return .error(405, "use POST")
		default:
			return .error(404, "unknown path; try GET /state or POST /command")
		}
	}

	/// Gathered on the main actor, encoded off it.
	private func state() async -> HTTPResponse {
		let uptime = ContinuousClock.now - launched
		let response = StateResponse(
			app: AppInfo(
				label: talk.me.name,
				runID: options.runID,
				pid: ProcessInfo.processInfo.processIdentifier,
				platform: Self.platform,
				version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
				time: Date().timeIntervalSince1970,
				uptime: Double(uptime.components.seconds) + Double(uptime.components.attoseconds) / 1e18,
				isRunning: talk.isRunning,
				wantsRunning: model.wantsRunning,
				darkSecondsLeft: darkUntil.map { max(0, Self.seconds($0 - ContinuousClock.now)) },
				eventLog: events.path,
				controlPort: options.controlPort,
				linkCap: options.linkCap,
				ephemeral: options.ephemeral,
				soak: soakEnabled,
				soakBlobMB: options.soakBlobMB,
				mainLag: lag
			),
			talk: talk.debugSnapshot(),
			sample: SampleInfo(
				soak: SoakInfo(enabled: soakEnabled, nextSeq: nextSeq, sent: ping.sent, recipients: ping.recipients, delivered: ping.delivered, failures: ping.failures, origins: origins),
				transfers: model.transferStats,
				acceptBlobs: model.acceptBlobs,
				sendingBlob: model.sendingBlob.map { model.name(of: $0) }.sorted()
			)
		)
		let body = await Task.detached(priority: .userInitiated) {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.sortedKeys]
			return try? encoder.encode(response)
		}.value
		guard let body else { return .error(500, "cannot encode state") }
		return HTTPResponse(status: 200, body: body)
	}

	private func command(_ body: Data) async -> HTTPResponse {
		guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let name = object["cmd"] as? String else {
			return .error(400, "body must be a JSON object with a \"cmd\" string")
		}
		// a retry (same request id) gets the first reply, or hears that the command is still running
		let requestID = object["requestID"] as? String
		if let requestID, let cached = replies[requestID] {
			log("command", ["cmd": name, "requestID": requestID, "duplicate": true])
			return Self.reply(cached.merging(["duplicate": true]) { _, new in new })
		}
		if let requestID, inFlight.contains(requestID) {
			log("command", ["cmd": name, "requestID": requestID, "duplicate": true])
			return Self.reply(["ok": true, "inProgress": true])
		}
		log("command", ["cmd": name, "args": object.filter { $0.key != "cmd" && JSONSerialization.isValidJSONObject([$0.value]) }])
		if let requestID {
			inFlight.insert(requestID)
		}
		var reply: [String: Any] = ["ok": true]
		do {
			try await run(name, object, into: &reply)
		} catch let error as CommandError {
			reply = ["ok": false, "error": error.message]
		} catch {
			reply = ["ok": false, "error": "\(error)"]
		}
		if let requestID {
			inFlight.remove(requestID)
			replies[requestID] = reply
			replyOrder.append(requestID)
			while replyOrder.count > Self.keptReplies {
				replies[replyOrder.removeFirst()] = nil
			}
		}
		return Self.reply(reply)
	}

	private static func reply(_ reply: [String: Any]) -> HTTPResponse {
		guard let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) else { return .error(500, "cannot encode reply") }
		return HTTPResponse(status: reply["ok"] as? Bool == true ? 200 : 400, body: data)
	}

	private struct CommandError: Error {
		let message: String
		init(_ message: String) { self.message = message }
	}

	private func run(_ name: String, _ args: [String: Any], into reply: inout [String: Any]) async throws {
		switch name {
		case "ping":
			let result = await sendPing()
			reply["seq"] = result.seq
			reply["recipients"] = result.recipients
			reply["delivered"] = result.delivered
			reply["failed"] = result.failed
		case "chat":
			guard let text = args["text"] as? String, !text.isEmpty, text.utf8.count <= 10_000 else { throw CommandError("\"text\" must be a non-empty string") }
			let results = await model.sendChat(text)
			reply["recipients"] = results.count
			reply["delivered"] = results.values.count { if case .success = $0 { true } else { false } }
		case "blob":
			let peer = try resolve(args["to"], connectedOnly: true)
			let megabytes = (args["mb"] as? Int) ?? 10
			guard (1 ... 500).contains(megabytes) else { throw CommandError("\"mb\" must be 1…500") }
			guard !model.sendingBlob.contains(peer.id) else { throw CommandError("already sending a blob to \(peer.name)") }
			reply["peer"] = peer.name
			if args["wait"] as? Bool == true {
				switch await model.sendBlob(to: peer, megabytes: megabytes) {
				case .success(let seconds):
					reply["seconds"] = seconds
				case .failure(let error):
					throw CommandError("blob failed: \(error)")
				}
			} else {
				reply["started"] = true
				Task { await model.sendBlob(to: peer, megabytes: megabytes) }
			}
		case "acceptBlobs":
			guard let on = args["on"] as? Bool else { throw CommandError("\"on\" must be a boolean") }
			model.acceptBlobs = on
		case "disconnect":
			let peer = try resolve(args["peer"], connectedOnly: false)
			guard talk.debugDisconnect(peer.id) else { throw CommandError("\(peer.name) is not a direct neighbour") }
			reply["peer"] = peer.name
		case "block":
			guard let names = args["names"] as? [String] else { throw CommandError("\"names\" must be an array of display names") }
			model.setBlocked(Set(names))
			reply["blocked"] = names.sorted()
		case "dark":
			guard let seconds = (args["seconds"] as? NSNumber)?.doubleValue, (0.1 ... 3600).contains(seconds) else { throw CommandError("\"seconds\" must be 0.1…3600") }
			goDark(for: seconds)
		case "stop":
			cancelDark()
			model.setRunning(false)
		case "start":
			cancelDark()
			model.setRunning(true)
		case "soak":
			guard let on = args["on"] as? Bool else { throw CommandError("\"on\" must be a boolean") }
			setSoak(on)
		case "resetStats":
			origins = [:]
			loggedOrigins = [:]
			ping = Ping()
			lag = LagStats()
		default:
			throw CommandError("unknown cmd \"\(name)\"; known: ping chat blob acceptBlobs disconnect block dark stop start soak resetStats")
		}
	}

	/// Stops `Talk` now and starts it again after `seconds`.
	private func goDark(for seconds: Double) {
		darkTask?.cancel()
		model.setRunning(false)
		darkUntil = ContinuousClock.now + .seconds(seconds)
		darkTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(seconds))
			guard let self, !Task.isCancelled else { return }
			darkUntil = nil
			darkTask = nil
			model.setRunning(true)
		}
	}

	private func cancelDark() {
		darkTask?.cancel()
		darkTask = nil
		darkUntil = nil
	}

	/// A peer by UUID, UUID prefix (4+ characters) or display name.
	private func resolve(_ reference: Any?, connectedOnly: Bool) throws -> Peer {
		guard let reference = reference as? String, !reference.isEmpty else { throw CommandError("peer reference (name or id) missing") }
		let peers = talk.peers.filter { !connectedOnly || $0.state == .connected }
		var matches = peers.filter { $0.id.uuidString.caseInsensitiveCompare(reference) == .orderedSame || $0.name == reference }
		if matches.isEmpty {
			matches = peers.filter { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
		}
		if matches.isEmpty, reference.count >= 4 {
			matches = peers.filter { $0.id.uuidString.lowercased().hasPrefix(reference.lowercased()) }
		}
		guard let peer = matches.first else { throw CommandError("no \(connectedOnly ? "connected " : "")peer \"\(reference)\"") }
		guard matches.count == 1 else { throw CommandError("\"\(reference)\" is ambiguous") }
		return peer
	}

	nonisolated static func seconds(_ duration: Duration) -> Double {
		Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
	}

	private static var platform: String {
		#if os(iOS)
		"ios"
		#else
		"macos"
		#endif
	}
}
