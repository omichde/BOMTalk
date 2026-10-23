//
//  MPCTransport.swift
//  BOMTalk
//

import Foundation
import MultipeerConnectivity
import os

/// MultipeerConnectivity based transport: advertises and browses at the same time (mesh),
/// filters by app id and protocol version, connects automatically and reconnects with backoff.
///
/// A thin adapter: the per-peer state machine lives in `MPCPeerMachine`, which is kept apart from
/// the (single) session, so a session pool could be added later.
@MainActor
final class MPCTransport: Transport {

	var onEvent: (@MainActor (TransportEvent) -> Void)?
	private(set) var localPeer: TransportPeer

	/// Everything that only exists while running; recreated on every start.
	private struct Services {
		let session: MCSession
		var advertiser: MCNearbyServiceAdvertiser
		let browser: MCNearbyServiceBrowser
		let proxy: MPCDelegateProxy
	}

	private let serviceType: String
	private let appID: String
	private let protocolVersion: Int
	private let identity: MPCIdentity
	private let invitationContext: Data?
	private let logger = Logger.bomtalk("transport")

	private var services: Services?
	private var machine: MPCPeerMachine<MCPeerID>
	private var advertiserRestart: Task<Void, Never>?

	init(serviceType: String, appID: String, displayName: String, protocolVersion: Int) {
		self.serviceType = serviceType
		self.appID = appID
		self.protocolVersion = protocolVersion
		identity = MPCIdentity.load(appID: appID, displayName: displayName, defaults: .standard, store: KeychainUUIDStore(service: "BOMTalk.\(appID)"))
		invitationContext = InvitationContext(appID: appID, version: protocolVersion, uuid: identity.uuid).encoded()
		machine = MPCPeerMachine(localID: identity.uuid)
		localPeer = TransportPeer(id: identity.uuid, name: identity.displayName, info: [:])
	}

	// MARK: - Transport

	func start(info: [String: String]) {
		guard services == nil else { return }
		localPeer.info = info
		let session = MCSession(peer: identity.peerID, securityIdentity: nil, encryptionPreference: .required)
		let browser = MCNearbyServiceBrowser(peer: identity.peerID, serviceType: serviceType)
		let proxy = MPCDelegateProxy(transport: self)
		session.delegate = proxy
		browser.delegate = proxy
		let advertiser = makeAdvertiser(proxy: proxy)
		services = Services(session: session, advertiser: advertiser, browser: browser, proxy: proxy)
		advertiser.startAdvertisingPeer()
		browser.startBrowsingForPeers()
	}

	func stop() {
		guard let services else { return }
		self.services = nil
		advertiserRestart?.cancel()
		advertiserRestart = nil
		services.advertiser.stopAdvertisingPeer()
		services.browser.stopBrowsingForPeers()
		services.advertiser.delegate = nil
		services.browser.delegate = nil
		services.session.delegate = nil
		services.session.disconnect()
		machine.reset()
	}

	/// Restarts the advertiser at most once per `advertiserRestartDelay`, with the latest info.
	func update(info: [String: String]) {
		localPeer.info = info
		guard services != nil, advertiserRestart == nil else { return }
		advertiserRestart = Task { [weak self] in
			try? await Task.sleep(for: MPCPolicy.advertiserRestartDelay)
			guard !Task.isCancelled, let self else { return }
			self.advertiserRestart = nil
			self.restartAdvertiser()
		}
	}

	func send(_ data: Data, to peer: UUID) throws(TalkError) {
		guard let services, let peerID = machine.sendHandle(for: peer) else { throw .notConnected }
		do {
			try services.session.send(data, toPeers: [peerID], with: .reliable)
		} catch {
			throw .sendFailed(error.localizedDescription)
		}
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
		guard let services, services.proxy === proxy else {
			if case let .invitation(_, _, handler) = callback {
				handler(false, nil)
			}
			return
		}
		switch callback {
		case let .found(peerID, info):
			found(peerID, info: info)
		case let .lost(peerID):
			perform(machine.lost(peerID))
		case let .invitation(peerID, context, handler):
			guard let id = InvitationContext.decode(context, appID: appID, protocolVersion: protocolVersion) else {
				return handler(false, nil)
			}
			let (accept, actions) = machine.invitation(from: peerID, id: id, name: peerID.displayName)
			handler(accept, accept ? services.session : nil)
			perform(actions)
		case let .state(peerID, state):
			perform(machine.sessionChanged(peerID, to: state))
		case let .data(data, peerID):
			perform(machine.received(data, from: peerID))
		case let .advertiserFailed(error):
			logger.error("advertiser failed: \(error, privacy: .public)")
			onEvent?(.failed(MPCPolicy.startError(error, serviceType: serviceType) ?? .advertiserFailed(error.localizedDescription)))
		case let .browserFailed(error):
			logger.error("browser failed: \(error, privacy: .public)")
			onEvent?(.failed(MPCPolicy.startError(error, serviceType: serviceType) ?? .browserFailed(error.localizedDescription)))
		}
	}

	private func found(_ peerID: MCPeerID, info: [String: String]?) {
		guard let (id, hostInfo) = DiscoveryInfo.decode(info, appID: appID, protocolVersion: protocolVersion) else { return }
		guard id != identity.uuid else {
			if peerID != identity.peerID {
				logger.warning("peer \(peerID.displayName, privacy: .public) has our own UUID (cloned device?)")
			}
			return
		}
		perform(machine.found(peerID, id: id, name: peerID.displayName, info: hostInfo))
	}

	// MARK: - Actions

	private func perform(_ actions: [MPCPeerMachine<MCPeerID>.Action]) {
		for action in actions {
			guard let services else { return }	// stopped from within `onEvent`
			switch action {
			case let .emit(event):
				onEvent?(event)
			case let .invite(peerID):
				services.browser.invitePeer(peerID, to: services.session, withContext: invitationContext, timeout: MPCPolicy.inviteTimeout)
			case let .cancel(peerID):
				services.session.cancelConnectPeer(peerID)
			case let .timer(id, token, delay):
				Task { [weak self] in
					try? await Task.sleep(for: delay)
					guard let self else { return }
					self.perform(self.machine.timerFired(id, token: token))
				}
			}
		}
	}

	private func restartAdvertiser() {
		guard var services else { return }
		services.advertiser.stopAdvertisingPeer()
		services.advertiser.delegate = nil
		services.advertiser = makeAdvertiser(proxy: services.proxy)
		self.services = services
		services.advertiser.startAdvertisingPeer()
	}

	private func makeAdvertiser(proxy: MPCDelegateProxy) -> MCNearbyServiceAdvertiser {
		let info = DiscoveryInfo.encode(appID: appID, protocolVersion: protocolVersion, uuid: identity.uuid, info: localPeer.info)
		let advertiser = MCNearbyServiceAdvertiser(peer: identity.peerID, discoveryInfo: info, serviceType: serviceType)
		advertiser.delegate = proxy
		return advertiser
	}
}

/// Receives MPC callbacks on MPC's queues and forwards them to the main actor.
/// `DispatchQueue.main.async` keeps the arrival order (FIFO), unlike unstructured tasks.
private final class MPCDelegateProxy: NSObject, Sendable, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {

	/// MPC types are not annotated `Sendable`; they are only touched on main after the hop.
	private struct Box: @unchecked Sendable {
		let callback: MPCTransport.Callback
	}

	private weak let transport: MPCTransport?

	init(transport: MPCTransport) {
		self.transport = transport
	}

	private func forward(_ callback: MPCTransport.Callback) {
		let box = Box(callback: callback)
		DispatchQueue.main.async {
			MainActor.assumeIsolated {
				if let transport = self.transport {
					transport.handle(box.callback, from: self)
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
