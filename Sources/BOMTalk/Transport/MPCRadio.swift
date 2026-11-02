//
//  MPCRadio.swift
//  BOMTalk
//

import Foundation
import MultipeerConnectivity
import os

/// The production transport: `LinkTransport` over MultipeerConnectivity.
typealias MPCTransport = LinkTransport<MPCRadio>

extension LinkTransport where Radio == MPCRadio {

	/// - Parameters:
	///   - maxPeers: Peer cap, below `MPCPolicy.maxRemotePeers` only for debugging (2 = 1 regular + 1 bridge).
	///   - ephemeral: A random identity, nothing stored (debug rigs).
	convenience init(serviceType: String, appID: String, displayName: String, protocolVersion: Int, maxPeers: Int = MPCPolicy.maxRemotePeers, ephemeral: Bool = false) {
		let identity = ephemeral
			? MPCIdentity.ephemeral(displayName: displayName)
			: MPCIdentity.load(appID: appID, displayName: displayName, defaults: .standard, store: KeychainUUIDStore(service: "BOMTalk.\(appID)"))
		self.init(
			radio: MPCRadio(displayName: identity.displayName, serviceType: serviceType),
			localID: identity.uuid,
			displayName: identity.displayName,
			appID: appID,
			protocolVersion: protocolVersion,
			timers: TaskTimers(),
			maxPeers: maxPeers
		)
	}
}

/// One `MCSession` plus advertiser and browser, recreated on every start. A thin adapter: callbacks
/// are hopped to the main actor in arrival order and passed on as `LinkRadioEvent`s.
///
/// Every start also gets a fresh `MCPeerID` (same display name): remote MPC stacks keep the session
/// of a peer that vanished abruptly for a while, and invitations between them and a reused peer id
/// hang meanwhile (`GCKSession … Timed out, enforcing clean up`). `LinkTransport` identifies devices
/// by the UUID in the discovery info and copes with several handles per device.
///
/// Sending happens off the main actor, one serial queue per peer (`Outbox`): `MCSession.send` may
/// block while MPC's buffer for a slow or vanished peer is full, and on the main actor that froze the
/// whole app (rig runs with blobs: instances stopped answering for good). Invitations, cancels and the
/// final `disconnect` go to one serial queue per run (`SessionControl`), in order: they may block as
/// well (rig soak: the main actor stood still for 2 s when an instance stopped, for 10 s when a
/// wedged one reset its radio).
@MainActor
final class MPCRadio: LinkRadio {

	var onEvent: (@MainActor (LinkRadioEvent<MCPeerID>) -> Void)?
	/// This run's peer id; replaced on every start.
	private(set) var localHandle: MCPeerID

	/// Everything that only exists while running; recreated on every start.
	private struct Services {
		let session: MCSession
		var advertiser: MCNearbyServiceAdvertiser
		let browser: MCNearbyServiceBrowser
		let proxy: MPCDelegateProxy
		let control: SessionControl
		var outboxes: [MCPeerID: Outbox] = [:]
	}

	private let displayName: String
	private let serviceType: String
	private let logger = Logger.bomtalk("transport")
	private var services: Services?

	init(displayName: String, serviceType: String) {
		self.displayName = displayName
		localHandle = MCPeerID(displayName: displayName)
		self.serviceType = serviceType
	}

	// MARK: - LinkRadio

	func displayName(of handle: MCPeerID) -> String {
		handle.displayName
	}

	func start(discoveryInfo: [String: String]) {
		guard services == nil else { return }
		localHandle = MCPeerID(displayName: displayName)
		let session = MCSession(peer: localHandle, securityIdentity: nil, encryptionPreference: .required)
		let browser = MCNearbyServiceBrowser(peer: localHandle, serviceType: serviceType)
		let proxy = MPCDelegateProxy(radio: self)
		session.delegate = proxy
		browser.delegate = proxy
		let advertiser = makeAdvertiser(proxy: proxy, discoveryInfo: discoveryInfo)
		services = Services(session: session, advertiser: advertiser, browser: browser, proxy: proxy, control: SessionControl(session: session, browser: browser))
		advertiser.startAdvertisingPeer()
		browser.startBrowsingForPeers()
	}

	func stop() {
		guard let services else { return }
		self.services = nil
		services.advertiser.stopAdvertisingPeer()
		services.browser.stopBrowsingForPeers()
		services.advertiser.delegate = nil
		services.browser.delegate = nil
		services.session.delegate = nil
		for outbox in services.outboxes.values {
			outbox.close()
		}
		services.control.disconnect()
	}

	func restartAdvertiser(discoveryInfo: [String: String]) {
		guard var services else { return }
		services.advertiser.stopAdvertisingPeer()
		services.advertiser.delegate = nil
		services.advertiser = makeAdvertiser(proxy: services.proxy, discoveryInfo: discoveryInfo)
		self.services = services
		services.advertiser.startAdvertisingPeer()
	}

	func invite(_ handle: MCPeerID, context: Data?, timeout: TimeInterval) {
		services?.control.invite(handle, context: context, timeout: timeout)
	}

	func cancel(_ handle: MCPeerID) {
		guard let services else { return }
		services.control.cancel(handle)
		services.outboxes[handle]?.close()
		self.services?.outboxes[handle] = nil
	}

	/// Queues the data for the peer; throws if the peer's backlog is full (`MPCPolicy.sendBacklog`).
	/// MPC's own errors arrive later and are only logged: the link transport learns about a dead link
	/// from the session state, the relay from silence.
	func send(_ data: Data, to handle: MCPeerID) throws {
		guard var services else { throw TalkError.notConnected }
		let outbox = services.outboxes[handle] ?? Outbox(session: services.session, peer: handle)
		if services.outboxes[handle] == nil {
			services.outboxes[handle] = outbox
			self.services = services
		}
		try outbox.send(data)
	}

	// MARK: - Delegate callbacks (on main, in arrival order)

	fileprivate enum Callback {
		case found(MCPeerID, [String: String]?)
		case lost(MCPeerID)
		case invitation(MCPeerID, Data?, (Bool, MCSession?) -> Void)
		case state(MCPeerID, MCSessionState)
		case data(Data, MCPeerID)
		case advertiserFailed(any Error)
		case browserFailed(any Error)
	}

	/// Callbacks of a previous run (other proxy) are ignored. Invitations that reached a previous
	/// advertiser of this run (info update) are still handled: the session is the same.
	fileprivate func handle(_ callback: Callback, from proxy: MPCDelegateProxy) {
		guard let services, services.proxy === proxy, let onEvent else {
			if case let .invitation(_, _, handler) = callback {
				handler(false, nil)
			}
			return
		}
		switch callback {
		case let .found(peerID, info):
			onEvent(.found(peerID, discoveryInfo: info))
		case let .lost(peerID):
			onEvent(.lost(peerID))
		case let .invitation(peerID, context, handler):
			let session = services.session
			onEvent(.invitation(peerID, context: context, reply: { accept in
				handler(accept, accept ? session : nil)
			}))
		case let .state(peerID, state):
			if state == .notConnected {
				services.outboxes[peerID]?.close()
				self.services?.outboxes[peerID] = nil
			}
			onEvent(.state(peerID, state))
		case let .data(data, peerID):
			onEvent(.data(data, from: peerID))
		case let .advertiserFailed(error):
			logger.error("advertiser failed: \(error, privacy: .public)")
			onEvent(.failed(MPCPolicy.startError(error, serviceType: serviceType) ?? .advertiserFailed(error.localizedDescription)))
		case let .browserFailed(error):
			logger.error("browser failed: \(error, privacy: .public)")
			onEvent(.failed(MPCPolicy.startError(error, serviceType: serviceType) ?? .browserFailed(error.localizedDescription)))
		}
	}

	private func makeAdvertiser(proxy: MPCDelegateProxy, discoveryInfo: [String: String]) -> MCNearbyServiceAdvertiser {
		let advertiser = MCNearbyServiceAdvertiser(peer: localHandle, discoveryInfo: discoveryInfo, serviceType: serviceType)
		advertiser.delegate = proxy
		return advertiser
	}
}

/// Sends to one peer of a session in order, on its own serial queue, and bounds what waits there.
/// Frames queue up under a lock and one drain on the queue hands them to MPC until none is left, so a
/// burst costs one dispatch, not one per frame.
private final class Outbox: @unchecked Sendable {

	private let session: MCSession
	private let peer: MCPeerID
	private let queue: DispatchQueue
	private let lock = NSLock()
	/// Frames not handed to MPC yet, their bytes (including the frame being sent) and whether a drain
	/// is scheduled or running; only under `lock`.
	private var pending: [Data] = []
	private var backlog = 0
	private var draining = false
	private static let logger = Logger.bomtalk("transport")

	init(session: MCSession, peer: MCPeerID) {
		self.session = session
		self.peer = peer
		queue = DispatchQueue(label: "de.werk01.BOMTalk.send", qos: .userInitiated)
	}

	/// Throws if `MPCPolicy.sendBacklog` bytes already wait (one frame always fits).
	func send(_ data: Data) throws {
		let count = data.count
		let startDrain: Bool? = lock.withLock {
			guard backlog == 0 || backlog + count <= MPCPolicy.sendBacklog else { return nil }
			backlog += count
			pending.append(data)
			let start = !draining
			draining = true
			return start
		}
		guard let startDrain else { throw TalkError.sendFailed("send backlog full") }
		if startDrain {
			queue.async { [self] in
				drain()
			}
		}
	}

	/// The link is gone: frames still waiting are dropped (a frame MPC is busy with completes or fails).
	func close() {
		lock.withLock {
			backlog -= pending.reduce(0) { $0 + $1.count }
			pending = []
		}
	}

	private func drain() {
		while true {
			let batch: [Data] = lock.withLock {
				let batch = pending
				pending = []
				draining = !batch.isEmpty
				return batch
			}
			guard !batch.isEmpty else { return }
			for data in batch {
				do {
					try session.send(data, toPeers: [peer], with: .reliable)
				} catch {
					Self.logger.debug("sending to \(self.peer.displayName, privacy: .public) failed: \(error, privacy: .public)")
				}
				lock.withLock { backlog -= data.count }
			}
		}
	}
}

/// Invitations, cancels and the final disconnect of one run's session, in order on a serial queue:
/// MPC may block in any of them (a wedged session, a send blocked in an `Outbox`), never the main
/// actor. A later run has its own queue, so a blocked teardown does not delay it.
private final class SessionControl: @unchecked Sendable {

	private let session: MCSession
	private let browser: MCNearbyServiceBrowser
	private let queue = DispatchQueue(label: "de.werk01.BOMTalk.control", qos: .userInitiated)

	init(session: MCSession, browser: MCNearbyServiceBrowser) {
		self.session = session
		self.browser = browser
	}

	func invite(_ peer: MCPeerID, context: Data?, timeout: TimeInterval) {
		let peer = Unchecked(value: peer)
		queue.async { [self] in
			browser.invitePeer(peer.value, to: session, withContext: context, timeout: timeout)
		}
	}

	func cancel(_ peer: MCPeerID) {
		let peer = Unchecked(value: peer)
		queue.async { [self] in
			session.cancelConnectPeer(peer.value)
		}
	}

	func disconnect() {
		queue.async { [self] in
			session.disconnect()
		}
	}

	/// `MCPeerID` is immutable but not annotated `Sendable`.
	private struct Unchecked<Value>: @unchecked Sendable {
		let value: Value
	}
}

/// Receives MPC callbacks on MPC's queues and forwards them to the main actor.
/// `DispatchQueue.main.async` keeps the arrival order (FIFO), unlike unstructured tasks.
private final class MPCDelegateProxy: NSObject, Sendable, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {

	/// MPC types are not annotated `Sendable`; they are only touched on main after the hop.
	private struct Box: @unchecked Sendable {
		let callback: MPCRadio.Callback
	}

	private weak let radio: MPCRadio?

	init(radio: MPCRadio) {
		self.radio = radio
	}

	private func forward(_ callback: MPCRadio.Callback) {
		let box = Box(callback: callback)
		DispatchQueue.main.async {
			MainActor.assumeIsolated {
				if let radio = self.radio {
					radio.handle(box.callback, from: self)
				} else if case let .invitation(_, _, handler) = box.callback {
					handler(false, nil)
				}
			}
		}
	}

	// MARK: MCNearbyServiceBrowserDelegate

	func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
		forward(.found(peerID, info))
	}

	func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
		forward(.lost(peerID))
	}

	func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
		forward(.browserFailed(error))
	}

	// MARK: MCNearbyServiceAdvertiserDelegate

	func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
		forward(.invitation(peerID, context, invitationHandler))
	}

	func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
		forward(.advertiserFailed(error))
	}

	// MARK: MCSessionDelegate

	func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
		forward(.state(peerID, state))
	}

	func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
		forward(.data(data, peerID))
	}

	func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
		certificateHandler(true)	// no PIN / identity check, encryption only
	}

	func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
	func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
	func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {}
}
