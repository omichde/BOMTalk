//
//  DemoModel.swift
//  BOMTalkSample
//

import Foundation
import Observation
import Combine
import BOMTalk

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

	private var bag = Set<AnyCancellable>()
	private var blobSubscription: AnyCancellable?

	/// What the user wants, independent of `talk.isRunning`, which is stopped in the background.
	private(set) var wantsRunning = false

	init(displayName: String) {
		talk = Self.makeTalk(displayName: displayName)
		setUp()
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
		talk = Self.makeTalk(displayName: displayName)
		setUp()
		if wantsRunning {
			talk.start()
		}
	}

	func sendChat(_ text: String) async {
		let chat = Chat(text: text, date: .now)
		append(Line(date: chat.date, from: talk.me.name, text: text), to: \.chat)
		let results = await talk.send(chat)
		for (id, result) in results {
			if case .failure(let error) = result {
				append(Line(date: .now, from: name(of: id), text: "not delivered: \(error)", isError: true), to: \.chat)
			}
		}
	}

	func sendBlob(to peer: Peer) async {
		sendingBlob.insert(peer.id)
		defer { sendingBlob.remove(peer.id) }
		let size = blobSize
		let blob = await Blob.random(megabytes: size)
		let start = ContinuousClock.now
		do {
			try await talk.send(blob, to: peer)
			append(Line(date: .now, from: peer.name, text: "sent \(size) MB in \(Self.seconds(since: start))"), to: \.blobLog)
		}
		catch {
			append(Line(date: .now, from: peer.name, text: "send failed: \(error)", isError: true), to: \.blobLog)
		}
	}

	func name(of id: Peer.ID) -> String {
		talk.peers.first { $0.id == id }?.name ?? "unknown peer"
	}

	// MARK: - private

	private static func makeTalk(displayName: String) -> Talk {
		Talk(serviceType: "bomtalk-demo", appID: "de.werk01.BOMTalkSample", displayName: displayName)
	}

	/// Sets the info before any `start()`, so it is advertised right away.
	private func setUp() {
		talk.info["emoji"] = emoji
		talk.messages(Chat.self)
			.sink { [weak self] result in
				guard let self else { return }
				switch result {
				case .success(let received):
					append(Line(date: received.message.date, from: received.peer.name, text: received.message.text), to: \.chat)
				case .failure(let error):
					append(Line(date: .now, from: "–", text: "receive failed: \(error)", isError: true), to: \.chat)
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
				case .failure(let error):
					append(Line(date: .now, from: "–", text: "receive failed: \(error)", isError: true), to: \.blobLog)
				}
			}
	}

	/// Start of the latest incoming blob per peer, noted by the progress row, for the log line.
	private var incomingStart: [Peer.ID: ContinuousClock.Instant] = [:]

	func noteIncomingStarted(from peer: Peer.ID) {
		incomingStart[peer] = incomingStart[peer] ?? .now
	}

	private static func seconds(since start: ContinuousClock.Instant) -> String {
		(ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
	}

	private func append(_ line: Line, to log: ReferenceWritableKeyPath<DemoModel, [Line]>) {
		self[keyPath: log].insert(line, at: 0)
	}
}
