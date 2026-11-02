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
/// whole app (rig runs with blobs: instances stopped answering for good).
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
		services = Services(session: session, advertiser: advertiser, browser: browser, proxy: proxy)
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
		services.session.disconnect()
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
		guard let services else { return }
		services.browser.invitePeer(handle, to: services.session, withContext: context, timeout: timeout)
	}

	func cancel(_ handle: MCPeerID) {
		services?.session.cancelConnectPeer(handle)
		services?.outboxes[handle] = nil
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
private final class Outbox: @unchecked Sendable {

	private let session: MCSession
	private let peer: MCPeerID
	private let queue: DispatchQueue
	private let lock = NSLock()
	/// Bytes queued and not handed to MPC yet; only under `lock`.
	private var backlog = 0
	private static let logger = Logger.bomtalk("transport")

	init(session: MCSession, peer: MCPeerID) {
		self.session = session
		self.peer = peer
		queue = DispatchQueue(label: "de.werk01.BOMTalk.send", qos: .userInitiated)
	}

	/// Throws if `MPCPolicy.sendBacklog` bytes already wait (one frame always fits).
	func send(_ data: Data) throws {
		let count = data.count
		let accepted = lock.withLock {
			guard backlog == 0 || backlog + count <= MPCPolicy.sendBacklog else { return false }
			backlog += count
			return true
		}
		guard accepted else { throw TalkError.sendFailed("send backlog full") }
		queue.async { [self] in
			do {
				try session.send(data, toPeers: [peer], with: .reliable)
			} catch {
				Self.logger.debug("sending to \(self.peer.displayName, privacy: .public) failed: \(error, privacy: .public)")
			}
			lock.withLock { backlog -= count }
		}
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
