//
//  DemoModel.swift
//  BOMTalkSample
//

import Foundation
import Observation
import Combine
@_spi(Debug) import BOMTalk

/// Owns the `Talk` and turns its streams into simple observable UI state.
@MainActor
@Observable
final class DemoModel {

	struct Line: Identifiable {
		let id = UUID()
		let date: Date
		let from: String
		let text: String
		var isError = false
	}

	static let emojis = ["🙂", "🚀", "🐙", "🍕", "🎸"]
	static let blobSizes = [1, 10, 50]

	private(set) var talk: Talk
	private(set) var chat: [Line] = []
	/// Received blobs and blob send results, newest first.
	private(set) var blobLog: [Line] = []
	/// Peers a blob is currently being generated for or sent to.
	private(set) var sendingBlob: Set<Peer.ID> = []

	var emoji = emojis[0] {
		didSet { talk.info["emoji"] = emoji }
	}
	var blobSize = blobSizes[0]
	var acceptBlobs = false {
		didSet { subscribeBlobs() }
	}

	let options: LaunchOptions
	/// Debug control layer (launch argument `-controlPort` or `-soak`), nil in a normal run.
	private(set) var control: ControlCenter?
	/// Blob counters and recent results for the control layer.
	private(set) var transferStats = TransferStats()
	/// Display names the link layer ignores (debug block list), kept across renames.
	private(set) var blocked: Set<String>

	private var bag = Set<AnyCancellable>()
	private var blobSubscription: AnyCancellable?

	/// What the user wants, independent of `talk.isRunning`, which is stopped in the background.
	private(set) var wantsRunning = false

	init(displayName: String, options: LaunchOptions = .current) {
		self.options = options
		blocked = options.blocked
		talk = Self.makeTalk(displayName: displayName, options: options)
		acceptBlobs = options.acceptBlobs
		if options.hasControl {
			control = ControlCenter(model: self, options: options)
		}
		setUp()
		// launch argument `-autostart YES` for scripted runs (e.g. `simctl launch`)
		if options.autostart {
			setRunning(true)
		}
		control?.start()
	}

	func setRunning(_ running: Bool) {
		wantsRunning = running
		running ? talk.start() : talk.stop()
	}

	/// MultipeerConnectivity drops sessions in the background on iOS: stop there and
	/// start again when active, if the user had it running.
	func sceneDidChange(active: Bool) {
		if active {
			if wantsRunning { talk.start() }
		}
		else {
			talk.stop()
		}
	}

	/// Changing the name needs a new `Talk`, peers see a new device name afterwards.
	func rename(_ displayName: String) {
		guard !displayName.isEmpty, displayName != talk.me.name else { return }
		talk.stop()
		bag.removeAll()
		blobSubscription = nil
		talk = Self.makeTalk(displayName: displayName, options: options)
		talk.debugSetBlocked(blocked)
		setUp()
		if wantsRunning {
			talk.start()
		}
	}

	/// Broadcasts a chat message; the results are per peer.
	@discardableResult
	func sendChat(_ text: String) async -> [Peer.ID: Result<Void, TalkError>] {
		let chat = Chat(text: text, date: .now)
		append(Line(date: chat.date, from: talk.me.name, text: text), to: \.chat)
		let results = await talk.send(chat)
		for (id, result) in results {
			if case .failure(let error) = result {
				append(Line(date: .now, from: name(of: id), text: "not delivered: \(error)", isError: true), to: \.chat)
			}
		}
		return results
	}

	/// Sends `megabytes` (default: the picker's size) of random data; returns the seconds it took.
	@discardableResult
	func sendBlob(to peer: Peer, megabytes: Int? = nil) async -> Result<Double, TalkError> {
		sendingBlob.insert(peer.id)
		defer { sendingBlob.remove(peer.id) }
		let size = megabytes ?? blobSize
		let blob = await Blob.random(megabytes: size)
		let start = ContinuousClock.now
		control?.log("blob.send.start", ["peer": peer.id.uuidString, "name": peer.name, "mb": size])
		do {
			try await talk.send(blob, to: peer)
			let seconds = Self.interval(since: start)
			append(Line(date: .now, from: peer.name, text: "sent \(size) MB in \(Self.seconds(since: start))"), to: \.blobLog)
			transferStats.noteSent(peer: peer.name, mb: size, seconds: seconds, error: nil)
			control?.log("blob.send.end", ["peer": peer.id.uuidString, "name": peer.name, "mb": size, "ok": true, "seconds": seconds])
			return .success(seconds)
		}
		catch {
			let seconds = Self.interval(since: start)
			append(Line(date: .now, from: peer.name, text: "send failed: \(error)", isError: true), to: \.blobLog)
			transferStats.noteSent(peer: peer.name, mb: size, seconds: seconds, error: "\(error)")
			control?.log("blob.send.end", ["peer": peer.id.uuidString, "name": peer.name, "mb": size, "ok": false, "error": "\(error)", "seconds": seconds])
			return .failure(error)
		}
	}

	/// Blocks (or unblocks, with an empty set) devices by display name in the link layer.
	func setBlocked(_ names: Set<String>) {
		blocked = names
		talk.debugSetBlocked(names)
	}

	func name(of id: Peer.ID) -> String {
		talk.peers.first { $0.id == id }?.name ?? "unknown peer"
	}

	// MARK: - private

	private static func makeTalk(displayName: String, options: LaunchOptions) -> Talk {
		guard options.needsDebugTalk else {
			return Talk(serviceType: "bomtalk-demo", appID: "de.werk01.BOMTalkSample", displayName: displayName)
		}
		let debug = TalkDebugOptions(linkCap: options.linkCap, ephemeralIdentity: options.ephemeral, blockedNames: options.blocked)
		return Talk(serviceType: "bomtalk-demo", appID: "de.werk01.BOMTalkSample", displayName: displayName, debug: debug)
	}

	/// Sets the info before any `start()`, so it is advertised right away.
	private func setUp() {
		talk.info["emoji"] = emoji
		control?.attach(talk)
		talk.messages(Chat.self)
			.sink { [weak self] result in
				guard let self else { return }
				switch result {
				case .success(let received):
					append(Line(date: received.message.date, from: received.peer.name, text: received.message.text), to: \.chat)
					transferStats.chatReceived += 1
				case .failure(let error):
					append(Line(date: .now, from: "–", text: "receive failed: \(error)", isError: true), to: \.chat)
					control?.log("receive.failed", ["kind": Chat.kind, "error": "\(error)"])
				}
			}
			.store(in: &bag)
		subscribeBlobs()
	}

	/// Without a subscriber, peers get `.notWanted` and no data is transferred at all.
	private func subscribeBlobs() {
		guard acceptBlobs else {
			blobSubscription = nil
			return
		}
		guard blobSubscription == nil else { return }
		blobSubscription = talk.messages(Blob.self)
			.sink { [weak self] result in
				guard let self else { return }
				switch result {
				case .success(let received):
					let size = ByteCountFormatter.string(fromByteCount: Int64(received.message.data.count), countStyle: .file)
					let duration = incomingStart.removeValue(forKey: received.peer.id).map { " in \(Self.seconds(since: $0))" } ?? ""
					append(Line(date: .now, from: received.peer.name, text: "received \(size)\(duration)"), to: \.blobLog)
					transferStats.noteReceived(peer: received.peer.name, bytes: received.message.data.count)
					control?.log("blob.received", ["peer": received.peer.id.uuidString, "name": received.peer.name, "bytes": received.message.data.count])
				case .failure(let error):
					append(Line(date: .now, from: "–", text: "receive failed: \(error)", isError: true), to: \.blobLog)
					transferStats.noteReceiveFailed()
					control?.log("receive.failed", ["kind": Blob.kind, "error": "\(error)"])
				}
			}
	}

	/// Start of the latest incoming blob per peer, noted by the progress row, for the log line.
	private var incomingStart: [Peer.ID: ContinuousClock.Instant] = [:]

	func noteIncomingStarted(from peer: Peer.ID) {
		incomingStart[peer] = incomingStart[peer] ?? .now
	}

	private static func interval(since start: ContinuousClock.Instant) -> Double {
		let duration = ContinuousClock.now - start
		return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
	}

	private static func seconds(since start: ContinuousClock.Instant) -> String {
		(ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
	}

	private func append(_ line: Line, to log: ReferenceWritableKeyPath<DemoModel, [Line]>) {
		self[keyPath: log].insert(line, at: 0)
	}
}
