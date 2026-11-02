//
//  HTTPServer.swift
//  BOMTalkSample
//

import Foundation
import Network

struct HTTPRequest: Sendable, Equatable {
	let method: String
	/// Without the query string.
	let path: String
	let query: String?
	/// Names lowercased.
	let headers: [String: String]
	let body: Data
}

struct HTTPResponse: Sendable, Equatable {
	var status: Int
	var contentType = "application/json"
	var body: Data

	/// `{"ok":false,"error":message}`
	static func error(_ status: Int, _ message: String) -> HTTPResponse {
		let object: [String: Any] = ["ok": false, "error": message]
		return HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
	}

	var encoded: Data {
		let head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
		return Data(head.utf8) + body
	}

	private static func reason(_ status: Int) -> String {
		switch status {
		case 200: "OK"
		case 400: "Bad Request"
		case 404: "Not Found"
		case 405: "Method Not Allowed"
		case 408: "Request Timeout"
		case 413: "Content Too Large"
		case 500: "Internal Server Error"
		case 503: "Service Unavailable"
		default: "Status"
		}
	}
}

/// Minimal HTTP/1.1 request parser, fed with whatever the socket delivers (partial reads included).
/// Request line, headers and a body with `Content-Length`; chunked bodies are refused. One request
/// per connection.
struct HTTPParser {

	enum Result: Equatable {
		case needMore
		case request(HTTPRequest)
		/// Status and reason to answer with.
		case bad(Int, String)
	}

	private struct Head {
		let method: String
		let path: String
		let query: String?
		let headers: [String: String]
		let length: Int
	}

	private struct Bad: Error {
		let status: Int
		let reason: String

		init(_ reason: String, status: Int = 400) {
			self.status = status
			self.reason = reason
		}
	}

	static let maxHeaderBytes = 16 * 1024
	static let maxBodyBytes = 1024 * 1024

	private var buffer = Data()
	/// Parsed head, while waiting for the rest of the body.
	private var head: Head?

	mutating func feed(_ data: Data) -> Result {
		buffer.append(data)
		if head == nil {
			guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
				return buffer.count > Self.maxHeaderBytes ? .bad(400, "header too large") : .needMore
			}
			guard end.lowerBound - buffer.startIndex <= Self.maxHeaderBytes else { return .bad(400, "header too large") }
			do {
				head = try Self.parseHead(buffer[buffer.startIndex ..< end.lowerBound])
			} catch {
				return .bad(error.status, error.reason)
			}
			buffer = Data(buffer[end.upperBound...])
		}
		guard let head else { return .needMore }
		guard buffer.count >= head.length else { return .needMore }
		return .request(HTTPRequest(method: head.method, path: head.path, query: head.query, headers: head.headers, body: Data(buffer.prefix(head.length))))
	}

	private static func parseHead(_ data: Data) throws(Bad) -> Head {
		guard let text = String(data: data, encoding: .utf8) else { throw Bad("header is not UTF-8") }
		var lines = text.components(separatedBy: "\r\n")
		let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
		guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/"), parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
			throw Bad("malformed request line")
		}
		var headers: [String: String] = [:]
		for line in lines {
			guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw Bad("malformed header") }
			headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
		}
		guard headers["transfer-encoding"] == nil else { throw Bad("chunked bodies are not supported") }
		var length = 0
		if let value = headers["content-length"] {
			guard let parsed = Int(value), parsed >= 0 else { throw Bad("bad Content-Length") }
			guard parsed <= maxBodyBytes else { throw Bad("body too large", status: 413) }
			length = parsed
		}
		let target = parts[1]
		let split = target.firstIndex(of: "?")
		let path = String(split.map { target[..<$0] } ?? target)
		let query = split.map { String(target[target.index(after: $0)...]) }
		return Head(method: String(parts[0]), path: path, query: query, headers: headers, length: length)
	}
}

/// A tiny HTTP server on `NWListener` for the debug control layer: one request per connection, runs
/// on its own queue, hands requests to `handler` (which hops to the main actor itself). Restarts the
/// listener if it fails (port still in use right after a relaunch).
final class ControlServer: @unchecked Sendable {

	typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

	private let port: UInt16
	private let handler: Handler
	private let log: @Sendable (String) -> Void
	private let queue = DispatchQueue(label: "de.werk01.BOMTalkSample.control")
	// everything below only on `queue`
	private var listener: NWListener?
	private var isStopped = false
	private var connections: [ObjectIdentifier: Connection] = [:]

	static let maxConnections = 32
	static let requestTimeout: TimeInterval = 10
	static let restartDelay: TimeInterval = 2

	init(port: UInt16, handler: @escaping Handler, log: @escaping @Sendable (String) -> Void = { _ in }) {
		self.port = port
		self.handler = handler
		self.log = log
	}

	func start() {
		queue.async { [self] in
			isStopped = false
			listen()
		}
	}

	func stop() {
		queue.async { [self] in
			isStopped = true
			listener?.cancel()
			listener = nil
			connections.values.forEach { $0.cancel() }
			connections = [:]
		}
	}

	// MARK: - on `queue`

	private func listen() {
		guard !isStopped, listener == nil else { return }
		let parameters = NWParameters.tcp
		parameters.allowLocalEndpointReuse = true
		guard let nwPort = NWEndpoint.Port(rawValue: port), let listener = try? NWListener(using: parameters, on: nwPort) else {
			return log("control server: cannot listen on port \(port)")
		}
		self.listener = listener
		listener.stateUpdateHandler = { [weak self, weak listener] state in
			guard let self, let listener else { return }
			switch state {
			case .ready:
				log("control server listening on port \(port)")
			case let .failed(error):
				log("control server failed: \(error)")
				listener.cancel()
				if self.listener === listener {
					self.listener = nil
				}
				queue.asyncAfter(deadline: .now() + Self.restartDelay) { self.listen() }
			default:
				break
			}
		}
		listener.newConnectionHandler = { [weak self] connection in
			self?.accept(connection)
		}
		listener.start(queue: queue)
	}

	private func accept(_ nwConnection: NWConnection) {
		guard connections.count < Self.maxConnections else { return nwConnection.cancel() }
		let connection = Connection(nwConnection, queue: queue, handler: handler) { [weak self] connection in
			self?.connections[ObjectIdentifier(connection)] = nil
		}
		connections[ObjectIdentifier(connection)] = connection
		connection.start()
	}

	/// One request, one response, then closed. Lives on the server's queue.
	private final class Connection: @unchecked Sendable {

		private let connection: NWConnection
		private let queue: DispatchQueue
		private let handler: Handler
		private let onDone: (Connection) -> Void
		private var parser = HTTPParser()
		private var timeout: DispatchWorkItem?
		private var isDone = false
		private var isResponding = false

		init(_ connection: NWConnection, queue: DispatchQueue, handler: @escaping Handler, onDone: @escaping (Connection) -> Void) {
			self.connection = connection
			self.queue = queue
			self.handler = handler
			self.onDone = onDone
		}

		func start() {
			connection.stateUpdateHandler = { [weak self] state in
				switch state {
				case .failed, .cancelled:
					self?.finish()
				default:
					break
				}
			}
			let timeout = DispatchWorkItem { [weak self] in
				self?.respond(.error(408, "request timeout"))
			}
			self.timeout = timeout
			queue.asyncAfter(deadline: .now() + ControlServer.requestTimeout, execute: timeout)
			connection.start(queue: queue)
			receive()
		}

		func cancel() {
			finish()
		}

		private func receive() {
			connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
				guard let self, !isDone, !isResponding else { return }
				if let data, !data.isEmpty {
					switch parser.feed(data) {
					case .needMore:
						break
					case let .bad(status, reason):
						return respond(.error(status, reason))
					case let .request(request):
						timeout?.cancel()
						let handler = handler
						Task {
							let response = await handler(request)
							self.queue.async { self.respond(response) }
						}
						return
					}
				}
				if error != nil || isComplete {
					return finish()	// closed before a full request
				}
				receive()
			}
		}

		private func respond(_ response: HTTPResponse) {
			guard !isDone, !isResponding else { return }
			isResponding = true
			timeout?.cancel()
			connection.send(content: response.encoded, completion: .contentProcessed { [weak self] _ in
				self?.finish()
			})
		}

		private func finish() {
			guard !isDone else { return }
			isDone = true
			timeout?.cancel()
			connection.cancel()
			onDone(self)
		}
	}
}
