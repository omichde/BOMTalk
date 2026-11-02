//
//  SimRadio.swift
//  BOMTalkTests
//

import Foundation
@testable import BOMTalk

/// A simulated device on the radio. Stays the same across runs, like an archived `MCPeerID`.
struct SimHandle: Hashable, Sendable, CustomStringConvertible {
	let index: Int

	var description: String { "d\(index)" }
}

enum SimError: Error {
	case notConnected
	/// A virtual time limit passed.
	case timeout
}

/// `LinkRadio` of one simulated device. Only bookkeeping of its own run; everything between devices
/// (discovery, invitations, sessions, data) happens in `SimNetwork`.
@MainActor
final class SimRadio: LinkRadio {

	var onEvent: (@MainActor (LinkRadioEvent<SimHandle>) -> Void)?
	let localHandle: SimHandle
	unowned let network: SimNetwork

	private(set) var isRunning = false
	/// Incremented on every start; callbacks scheduled for an earlier run are dropped.
	private(set) var run = 0
	private(set) var discoveryInfo: [String: String] = [:]

	init(index: Int, network: SimNetwork) {
		localHandle = SimHandle(index: index)
		self.network = network
	}

	var index: Int { localHandle.index }

	// MARK: - LinkRadio

	func displayName(of handle: SimHandle) -> String {
		handle.description
	}

	func start(discoveryInfo: [String: String]) {
		guard !isRunning else { return }
		isRunning = true
		run += 1
		self.discoveryInfo = discoveryInfo
		network.radioStarted(index)
	}

	func stop() {
		guard isRunning else { return }
		isRunning = false
		network.radioStopped(index)
	}

	func restartAdvertiser(discoveryInfo: [String: String]) {
		guard isRunning else { return }
		self.discoveryInfo = discoveryInfo
		network.advertiserRestarted(index)
	}

	func invite(_ handle: SimHandle, context: Data?, timeout: TimeInterval) {
		guard isRunning else { return }
		network.invite(from: index, to: handle.index, context: context, timeout: timeout)
	}

	func cancel(_ handle: SimHandle) {
		guard isRunning else { return }
		network.cancel(from: index, to: handle.index)
	}

	func send(_ data: Data, to handle: SimHandle) throws {
		guard isRunning else { throw SimError.notConnected }
		try network.send(data, from: index, to: handle.index)
	}

	// MARK: - Delivery

	/// Delivers an event of the current run. Invitations to a stopped radio are declined.
	func deliver(_ event: LinkRadioEvent<SimHandle>, run: Int) {
		guard isRunning, run == self.run, let onEvent else {
			if case let .invitation(_, _, reply) = event {
				reply(false)
			}
			return
		}
		onEvent(event)
	}
}
