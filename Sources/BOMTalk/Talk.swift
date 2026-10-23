//
//  Talk.swift
//  BOMTalk
//

import Foundation
import Observation
import os
@preconcurrency import Combine

/// Auto-connects to nearby devices running the same app and exchanges typed messages.
///
/// ```swift
/// let talk = Talk(serviceType: "exhibition", appID: "de.werk01.exhibition", displayName: "Lobby iPad")
/// talk.start()
/// talk.messages(Chat.self).sink { result in … }.store(in: &bag)
/// try await talk.send(Chat(text: "Hi"), to: peer)
/// ```
///
/// Known limitations: Swift task cancellation of `send` is not honoured yet (the transfer runs to
/// its end). A receiver that accepts an offer only after the sender's offer timeout gets no chunks
/// and reports `.timeout` itself once its chunk timeout passes.
@MainActor
@Observable
public final class Talk {

	/// This device.
	public private(set) var me: Peer
	/// Visible and connected peers. A disconnected peer falls back to `.discovered`; once it is no
	/// longer visible it is removed.
	public private(set) var peers: [Peer] = []
	/// Transfers in flight, both directions.
	public private(set) var transfers: [Transfer] = []
	public private(set) var isRunning = false
	/// Last general problem (not bound to a single message), e.g. local network access denied.
	public private(set) var issue: TalkError?
	/// Custom host info, visible as `Peer.info` on other devices. Updates are propagated live.
	/// Keep it small (discovery info is limited to ~400 bytes in total).
	public var info: [String: String] = [:] {
		didSet {
			guard info != oldValue else { return }
			me.info = info
			transport.update(info: info)
			let frame = Frame.info(info).encoded()
			for peer in peers where peer.state == .connected {
				sendFrame(frame, to: peer.id)
			}
		}
	}

	/// An outgoing offer waiting for accept / reject.
	private struct PendingOffer {
		let peer: UUID
		let continuation: CheckedContinuation<Result<Void, TalkError>, Never>
		let timeout: Task<Void, Never>
	}

	@ObservationIgnored private let transport: Transport
	@ObservationIgnored private let offerTimeout: Duration
	@ObservationIgnored private let registry = SubscriberRegistry()
	@ObservationIgnored private let reassembler: Reassembler
	@ObservationIgnored private let scheduler: Scheduler
	@ObservationIgnored private var offers: [UUID: PendingOffer] = [:]
	/// Tail of the serial delivery pipeline.
	@ObservationIgnored private var deliveries: Task<Void, Never>?

	/// - Parameters:
	///   - serviceType: Bonjour service type, 1–15 characters `[a-z0-9-]`, must be listed in
	///     `NSBonjourServices` as `_<serviceType>._tcp` and `_<serviceType>._udp`.
	///   - appID: Only peers with the same app id connect.
	///   - displayName: Name shown on other devices.
	///   - protocolVersion: Only peers with the same version connect.
	public convenience init(serviceType: String, appID: String, displayName: String, protocolVersion: Int = 1) {
		self.init(transport: MPCTransport(serviceType: serviceType, appID: appID, displayName: displayName, protocolVersion: protocolVersion))
	}

	/// Internal designated initializer, tests inject a loopback transport and short timeouts.
	init(transport: Transport, offerTimeout: Duration = .seconds(30), chunkTimeout: Duration = .seconds(30)) {
		self.transport = transport
		self.offerTimeout = offerTimeout
		self.reassembler = Reassembler(timeout: chunkTimeout)
		let local = transport.localPeer
		self.me = Peer(id: local.id, name: local.name, state: .connected, info: local.info)
		self.info = local.info
		// strong capture is fine: the transport only refers back to `self` weakly
		self.scheduler = Scheduler { data, peer throws(TalkError) in
			try transport.send(data, to: peer)
		}
		reassembler.onTimeout = { [weak self] transfer in
			self?.failIncoming(transfer, .timeout)
		}
		transport.onEvent = { [weak self] event in
			self?.handle(event)
		}
	}

	public func start() {
		guard !isRunning else { return }
		isRunning = true
		issue = nil
		transport.start(info: info)
	}

	public func stop() {
		guard isRunning else { return }
		isRunning = false	// ignore transport events from here on
		for id in offers.keys {
			answer(id, .failure(.notConnected))
		}
		scheduler.fail(.notConnected) { _, _ in true }
		for transfer in reassembler.dropAll() {
			failIncoming(transfer, .notConnected)
		}
		transport.stop()
		peers.removeAll()
		transfers.removeAll()
	}

	/// Typed stream of incoming messages. While at least one subscriber exists, offers for this
	/// kind are accepted; otherwise peers get `.notWanted`. Never fails: per-message problems
	/// arrive as `.failure`. Delivered on the main actor.
	public func messages<Message: TalkMessage>(_ type: Message.Type) -> AnyPublisher<Result<Received<Message>, TalkError>, Never> {
		registry.publisher(for: type)
	}

	/// Sends a message to one connected peer. Returns once all data was handed to the network.
	/// Throws `.encodingFailed` if `Message.kind` is empty or longer than 255 UTF-8 bytes.
	public func send<Message: TalkMessage>(_ message: Message, to peer: Peer) async throws(TalkError) {
		guard Self.isValid(kind: Message.kind) else { throw .encodingFailed }
		guard isConnected(peer.id) else { throw .notConnected }
		let payload = try await Codec.encode(message)
		try await transmit(payload, kind: Message.kind, to: peer.id)
	}

	/// Sends a message to all connected peers (encoded once). Peers without a subscriber for the
	/// kind report `.notWanted`.
	@discardableResult
	public func send<Message: TalkMessage>(_ message: Message) async -> [Peer.ID: Result<Void, TalkError>] {
		let recipients = peers.filter { $0.state == .connected }.map(\.id)
		guard !recipients.isEmpty else { return [:] }
		let payload: Data
		do throws(TalkError) {
			guard Self.isValid(kind: Message.kind) else { throw .encodingFailed }
			payload = try await Codec.encode(message)
		} catch {
			return Dictionary(uniqueKeysWithValues: recipients.map { ($0, .failure(error)) })
		}
		return await withTaskGroup(of: (Peer.ID, Result<Void, TalkError>).self) { group in
			for id in recipients {
				group.addTask {
					do throws(TalkError) {
						try await self.transmit(payload, kind: Message.kind, to: id)
						return (id, .success(()))
					} catch {
						return (id, .failure(error))
					}
				}
			}
			var results: [Peer.ID: Result<Void, TalkError>] = [:]
			for await (id, result) in group {
				results[id] = result
			}
			return results
		}
	}

	// MARK: - outgoing

	/// Offer, wait for the answer, then send the chunks interleaved with other transfers.
	private func transmit(_ payload: Data, kind: String, to peer: UUID) async throws(TalkError) {
		guard isConnected(peer) else { throw .notConnected }
		let id = UUID()
		let offer = Frame.offer(.init(transferID: id, kind: kind, totalBytes: UInt64(payload.count), chunkCount: UInt32(Scheduler.chunkCount(for: payload.count))))
		let answer = await withCheckedContinuation { continuation in
			do throws(TalkError) {
				// register first, the answer may arrive while sending
				offers[id] = PendingOffer(peer: peer, continuation: continuation, timeout: Task { [weak self, offerTimeout] in
					guard (try? await Task.sleep(for: offerTimeout)) != nil else { return }
					self?.answer(id, .failure(.timeout))
				})
				try transport.send(offer.encoded(), to: peer)
			} catch {
				self.answer(id, .failure(error))
			}
		}
		try answer.get()
		// the peer may have gone between the accept and resuming here
		guard isConnected(peer) else { throw .peerDisconnected }

		let transfer = Transfer(id: id, peer: peer, kind: kind, direction: .outgoing, totalBytes: payload.count)
		transfers.append(transfer)
		defer { transfers.removeAll { $0.id == id } }
		try await scheduler.transmit(payload, to: transfer)
	}

	/// Resumes a pending offer exactly once.
	private func answer(_ id: UUID, _ result: Result<Void, TalkError>) {
		guard let offer = offers.removeValue(forKey: id) else { return }
		offer.timeout.cancel()
		offer.continuation.resume(returning: result)
	}

	private func sendFrame(_ data: Data, to peer: UUID) {
		do {
			try transport.send(data, to: peer)
		} catch {
			log.error("sending frame to \(peer, privacy: .public) failed: \(String(describing: error), privacy: .public)")
		}
	}

	// MARK: - transport events

	private func handle(_ event: TransportEvent) {
		guard isRunning else { return }
		switch event {
		case .found(let peer):
			if let index = index(of: peer.id) {
				// while connected, info frames are authoritative over (possibly stale) discovery info
				let current = peers[index]
				peers[index] = Peer(id: peer.id, name: peer.name, state: current.state, info: current.state == .connected ? current.info : peer.info)
			} else {
				peers.append(Peer(id: peer.id, name: peer.name, state: .discovered, info: peer.info))
			}
		case .connecting(let id):
			// unknown peers (invited us before we saw them) are added on `connected`
			guard let index = index(of: id) else { return }
			peers[index].state = .connecting
		case .connected(let peer):
			let connected = Peer(id: peer.id, name: peer.name, state: .connected, info: peer.info)
			if let index = index(of: peer.id) {
				peers[index] = connected
			} else {
				peers.append(connected)
			}
			sendFrame(Frame.info(info).encoded(), to: peer.id)
		case .disconnected(let id):
			if let index = index(of: id) {
				peers[index].state = .discovered
			}
			failTransfers(of: id)
		case .lost(let id):
			failTransfers(of: id)
			peers.removeAll { $0.id == id }
		case .received(let data, let id):
			guard let frame = Frame(data) else {
				log.error("malformed frame (\(data.count) bytes) from \(id, privacy: .public)")
				return
			}
			handle(frame, from: id)
		case .failed(let error):
			issue = error
		}
	}

	private func handle(_ frame: Frame, from peer: UUID) {
		guard isConnected(peer) else { return }
		switch frame {
		case .offer(let offer):
			receive(offer, from: peer)
		case .accept(let id):
			guard offers[id]?.peer == peer else { return }
			answer(id, .success(()))
		case .reject(let id):
			guard offers[id]?.peer == peer else { return }
			answer(id, .failure(.notWanted))
		case .chunk(let id, let index, let payload):
			switch reassembler.add(payload, index: Int(index), to: id, from: peer) {
			case .ignored, .progressed:
				break
			case .failed(let transfer, let error):
				failIncoming(transfer, error)
			case .completed(let transfer, let data):
				transfers.removeAll { $0.id == transfer.id }
				guard let sender = peers.first(where: { $0.id == peer }) else { return }
				enqueueDelivery { [registry] in
					await registry.deliver(data, kind: transfer.kind, from: sender)
				}
			}
		case .info(let info):
			guard let index = index(of: peer) else { return }
			peers[index].info = info
		}
	}

	private func receive(_ offer: Frame.Offer, from peer: UUID) {
		let id = offer.transferID
		// a repeated offer is ignored; ids are unique across all transfers in flight
		guard !reassembler.contains(id, from: peer), !transfers.contains(where: { $0.id == id }) else { return }
		guard registry.count(offer.kind) > 0,
			let totalBytes = Int(exactly: offer.totalBytes),
			Int(offer.chunkCount) == Scheduler.chunkCount(for: totalBytes)
		else {
			sendFrame(Frame.reject(id).encoded(), to: peer)
			return
		}
		let transfer = Transfer(id: id, peer: peer, kind: offer.kind, direction: .incoming, totalBytes: totalBytes)
		reassembler.begin(transfer, chunkCount: Int(offer.chunkCount), totalBytes: totalBytes)
		transfers.append(transfer)
		sendFrame(Frame.accept(id).encoded(), to: peer)
	}

	// MARK: - failures

	/// Fails everything in flight with a peer that went away.
	private func failTransfers(of peer: UUID) {
		for (id, offer) in offers where offer.peer == peer {
			answer(id, .failure(.peerDisconnected))
		}
		scheduler.fail(.peerDisconnected) { _, transferPeer in transferPeer == peer }
		for transfer in reassembler.drop(peer: peer) {
			failIncoming(transfer, .peerDisconnected)
		}
	}

	/// Single failure path for incoming transfers (already removed from the reassembler).
	private func failIncoming(_ transfer: Transfer, _ error: TalkError) {
		transfers.removeAll { $0.id == transfer.id }
		enqueueDelivery { [registry] in
			registry.fail(error, kind: transfer.kind)
		}
	}

	/// Deliveries run one after another, so messages arrive in completion order.
	private func enqueueDelivery(_ work: @escaping @MainActor () async -> Void) {
		let previous = deliveries
		deliveries = Task {
			await previous?.value
			await work()
		}
	}

	// MARK: - helpers

	private func index(of peer: UUID) -> Int? {
		peers.firstIndex { $0.id == peer }
	}

	private func isConnected(_ peer: UUID) -> Bool {
		peers.contains { $0.id == peer && $0.state == .connected }
	}

	/// The offer frame carries the kind; keep it short and meaningful.
	private static func isValid(kind: String) -> Bool {
		!kind.isEmpty && kind.utf8.count <= 255
	}
}

private let log = Logger.bomtalk("talk")
