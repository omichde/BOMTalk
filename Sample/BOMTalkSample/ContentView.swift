//
//  ContentView.swift
//  BOMTalkSample
//

import SwiftUI
import BOMTalk
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {

	/// Empty until a default is generated once on first launch.
	@AppStorage("displayName") private var displayName = ""
	@State private var model: DemoModel?
	@Environment(\.scenePhase) private var scenePhase

	var body: some View {
		NavigationStack {
			if let model {
				DemoForm(model: model, displayName: $displayName)
					.navigationTitle("BOMTalk")
			}
		}
		.task {
			guard model == nil else { return }
			if displayName.isEmpty {
				displayName = await Self.defaultName()
			}
			model = DemoModel(displayName: displayName)
		}
		.onChange(of: scenePhase) { _, phase in
			switch phase {
			case .active: model?.sceneDidChange(active: true)
			case .background: model?.sceneDidChange(active: false)
			default: break
			}
		}
	}

	/// Device name plus a short random suffix, so equally named devices are distinguishable.
	/// Since iOS 16 `UIDevice.name` is just "iPhone" / "iPad"; `Host` may block, so not on main.
	private static func defaultName() async -> String {
		#if canImport(UIKit)
		let base = UIDevice.current.name
		#else
		let base = await Task.detached { Host.current().localizedName ?? "Mac" }.value
		#endif
		return "\(base) \(UUID().uuidString.prefix(4))"
	}
}

private struct DemoForm: View {

	@Bindable var model: DemoModel
	@Binding var displayName: String
	@State private var chatText = ""

	private var talk: Talk { model.talk }
	private var connected: [Peer] { talk.peers.filter { $0.state == .connected } }

	var body: some View {
		Form {
			Section("Me") {
				TextField("Display name", text: $displayName)
					.onSubmit { model.rename(displayName) }
				Toggle("Running", isOn: Binding(
					get: { talk.isRunning },
					set: { model.setRunning($0) }
				))
				Picker("Emoji", selection: $model.emoji) {
					ForEach(DemoModel.emojis, id: \.self) { Text($0) }
				}
				.pickerStyle(.segmented)
				if let issue = talk.issue {
					Label(issue.hint, systemImage: "exclamationmark.triangle")
						.foregroundStyle(.red)
				}
			}

			Section("Peers") {
				if talk.peers.isEmpty {
					Text("No peers yet").foregroundStyle(.secondary)
				}
				ForEach(talk.peers) { peer in
					LabeledContent {
						Text(peer.state.title)
					} label: {
						Text("\(peer.info["emoji"] ?? "") \(peer.name)")
					}
				}
			}

			Section("Chat") {
				HStack {
					TextField("Message", text: $chatText)
						.onSubmit(sendChat)
					Button("Send", action: sendChat)
						.disabled(chatText.isEmpty || connected.isEmpty)
				}
				ForEach(model.chat) { line in
					LineView(line: line)
				}
			}

			Section("Blobs") {
				Toggle("Accept blobs", isOn: $model.acceptBlobs)
				Picker("Size", selection: $model.blobSize) {
					ForEach(DemoModel.blobSizes, id: \.self) { Text("\($0) MB") }
				}
				.pickerStyle(.segmented)
				ForEach(connected) { peer in
					LabeledContent(peer.name) {
						if model.sendingBlob.contains(peer.id) {
							ProgressView().controlSize(.small)
						}
						else {
							Button("Send") {
								Task { await model.sendBlob(to: peer) }
							}
						}
					}
				}
				ForEach(model.blobLog) { line in
					LineView(line: line)
				}
			}

			Section("Transfers") {
				if talk.transfers.isEmpty {
					Text("No transfers").foregroundStyle(.secondary)
				}
				ForEach(talk.transfers) { transfer in
					TransferRow(transfer: transfer, peerName: model.name(of: transfer.peer))
						.onAppear {
							if transfer.direction == .incoming && transfer.kind == Blob.kind {
								model.noteIncomingStarted(from: transfer.peer)
							}
						}
				}
			}
		}
		.formStyle(.grouped)
	}

	private func sendChat() {
		guard !chatText.isEmpty else { return }
		let text = chatText
		chatText = ""
		Task { await model.sendChat(text) }
	}
}

private struct TransferRow: View {
	let transfer: Transfer
	let peerName: String

	var body: some View {
		VStack(alignment: .leading) {
			HStack {
				Text("\(transfer.direction == .outgoing ? "↑" : "↓") \(transfer.kind) – \(peerName)")
				Spacer()
				Text("\(Self.bytes(transfer.completedBytes)) / \(Self.bytes(transfer.totalBytes))")
					.font(.caption.monospacedDigit())
					.foregroundStyle(.secondary)
			}
			ProgressView(value: transfer.fractionCompleted)
		}
	}

	private static func bytes(_ count: Int) -> String {
		ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
	}
}

private struct LineView: View {
	let line: DemoModel.Line

	var body: some View {
		VStack(alignment: .leading) {
			Text("\(line.from) · \(line.date, style: .time)")
				.font(.caption)
				.foregroundStyle(.secondary)
			Text(line.text)
				.foregroundStyle(line.isError ? .red : .primary)
		}
	}
}

private extension Peer.State {
	var title: String {
		switch self {
		case .discovered: "discovered"
		case .connecting: "connecting"
		case .connected: "connected"
		}
	}
}

private extension TalkError {
	/// A short human hint for general issues.
	var hint: String {
		switch self {
		case .localNetworkDenied:
			"Local network access denied – allow it in Settings › Privacy & Security › Local Network."
		case .misconfigured(let reason):
			"App misconfigured (check NSBonjourServices in Info.plist): \(reason)"
		default:
			String(describing: self)
		}
	}
}
