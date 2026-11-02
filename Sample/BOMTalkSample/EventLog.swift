//
//  EventLog.swift
//  BOMTalkSample
//

import Foundation

/// JSON lines in the app's Documents folder (`bomtalk-events.jsonl`), one event per line:
/// `{"t":<seconds since 1970>,"up":<seconds since launch>,"run":…,"label":…,"type":…, …fields}`.
///
/// Encoding happens on the caller (main actor), file I/O only on the log's own queue: lines are
/// buffered and written once a second. At `maxBytes` the file is moved to `bomtalk-events.1.jsonl`
/// (replacing an older one) and a new one starts, so a long soak run keeps the last 1–2 files' worth.
final class EventLog: @unchecked Sendable {

	static let fileName = "bomtalk-events.jsonl"
	static let flushInterval: TimeInterval = 1

	private let url: URL
	private let rotatedURL: URL
	private let maxBytes: Int
	private let runID: String
	private let label: String
	private let launched = Date()
	private let queue = DispatchQueue(label: "de.werk01.BOMTalkSample.events", qos: .utility)
	// only on `queue`
	private var buffer = Data()
	private var size = 0
	private var flushScheduled = false

	static var defaultDirectory: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
	}

	init(directory: URL = EventLog.defaultDirectory, maxBytes: Int = 4 * 1024 * 1024, runID: String, label: String) {
		url = directory.appendingPathComponent(Self.fileName)
		rotatedURL = directory.appendingPathComponent("bomtalk-events.1.jsonl")
		self.maxBytes = maxBytes
		self.runID = runID
		self.label = label
		queue.sync {
			size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
		}
	}

	/// Appends one event; `fields` must be JSON-encodable (strings, numbers, bools, arrays, dictionaries).
	func record(_ type: String, _ fields: [String: Any] = [:]) {
		let now = Date()
		var object = fields
		object["t"] = (now.timeIntervalSince1970 * 1000).rounded() / 1000
		object["up"] = (now.timeIntervalSince(launched) * 1000).rounded() / 1000
		object["run"] = runID
		object["label"] = label
		object["type"] = type
		guard JSONSerialization.isValidJSONObject(object), let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
		let line = json + [0x0A]
		queue.async { [self] in
			buffer.append(line)
			guard !flushScheduled else { return }
			flushScheduled = true
			queue.asyncAfter(deadline: .now() + Self.flushInterval) { [self] in
				flushScheduled = false
				write()
			}
		}
	}

	/// Writes what is buffered now and waits for it.
	func flush() {
		queue.sync { write() }
	}

	// MARK: - on `queue`

	private func write() {
		guard !buffer.isEmpty else { return }
		let data = buffer
		buffer = Data()
		let manager = FileManager.default
		if size > 0, size + data.count > maxBytes {
			try? manager.removeItem(at: rotatedURL)
			try? manager.moveItem(at: url, to: rotatedURL)
			size = 0
		}
		if !manager.fileExists(atPath: url.path) {
			manager.createFile(atPath: url.path, contents: nil)
			size = 0
		}
		guard let handle = try? FileHandle(forWritingTo: url) else { return }
		defer { try? handle.close() }
		do {
			try handle.seekToEnd()
			try handle.write(contentsOf: data)
			size += data.count
		} catch {
			// disk full or the like: drop the lines rather than grow the buffer without bound
		}
	}
}
