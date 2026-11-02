//
//  MPCPeerMachineTests.swift
//  BOMTalk
//

import Foundation
import MultipeerConnectivity
import Testing
@testable import BOMTalk

/// Scripted event sequences against the pure per-peer state machine. Handles are strings like
/// "a1"; peers are named by letter, the local device is "5…" so A (9…) is invited by us and B (1…)
/// invites us first.
@Suite struct MPCPeerMachineTests {

	static func uuid(_ digit: Character) -> UUID {
		UUID(uuidString: "\(digit)0000000-0000-0000-0000-000000000000")!
	}

	static let local = uuid("5")
	static let a = uuid("9")
	static let b = uuid("1")
	static let c = uuid("3")
	static let d = uuid("8")
	static let names = [a: "A", b: "B", c: "C", d: "D"]

	/// Runs the machine and renders its actions as strings; remembers the latest timer per peer.
	final class Script {
		var machine: MPCPeerMachine<String>
		var timers: [UUID: Int] = [:]

		init(maxPeers: Int = MPCPolicy.maxRemotePeers) {
			machine = MPCPeerMachine(localID: MPCPeerMachineTests.local, maxPeers: maxPeers)
		}

		func found(_ handle: String, _ id: UUID, name: String? = nil) -> [String] {
			render(machine.found(handle, id: id, name: name ?? MPCPeerMachineTests.names[id]!, info: [:]))
		}

		func lost(_ handle: String) -> [String] {
			render(machine.lost(handle))
		}

		func invitation(_ handle: String, _ id: UUID) -> [String] {
			let (accept, actions) = machine.invitation(from: handle, id: id, name: MPCPeerMachineTests.names[id]!)
			return [accept ? "accept" : "decline"] + render(actions)
		}

		func state(_ handle: String, _ state: MCSessionState) -> [String] {
			render(machine.sessionChanged(handle, to: state))
		}

		func policy(candidates: Set<UUID> = [], suppressed: Set<UUID> = [], full: Set<UUID> = []) -> [String] {
			render(machine.setPolicy(LinkPolicy(bridgeCandidates: candidates, suppressed: suppressed, full: full)))
		}

		func disconnect(_ id: UUID) -> [String] {
			render(machine.disconnect(id))
		}

		func fire(_ id: UUID) -> [String] {
			render(machine.timerFired(id, token: timers[id]!))
		}

		private func render(_ actions: [MPCPeerMachine<String>.Action]) -> [String] {
			let name = { (id: UUID) in MPCPeerMachineTests.names[id]! }
			return actions.map { action in
				switch action {
				case let .invite(handle): return "invite \(handle)"
				case let .cancel(handle): return "cancel \(handle)"
				case let .timer(id, token, delay):
					timers[id] = token
					return "timer \(name(id)) \(delay.components.seconds)s"
				case let .emit(event):
					switch event {
					case let .found(peer): return "found \(name(peer.id)) \(peer.name)"
					case let .lost(id): return "lost \(name(id))"
					case let .connecting(id): return "connecting \(name(id))"
					case let .connected(peer): return "connected \(name(peer.id))"
					case let .disconnected(id): return "disconnected \(name(id))"
					case .received, .failed: return "\(event)"
					}
				}
			}
		}
	}

	@Test func lowerUUIDInvitesAtOnce() {
		let s = Script()
		#expect(s.found("a1", Self.a) == ["found A A", "timer A 40s", "connecting A", "invite a1"])
		#expect(s.found("a1", Self.a) == [])	// unchanged, no second invitation
		#expect(s.state("a1", .connected) == ["connected A"])
		#expect(s.machine.sendHandle(for: Self.a) == "a1")
	}

	@Test func higherUUIDWaitsForFallback() {
		let s = Script()
		#expect(s.found("b1", Self.b) == ["found B B", "timer B 5s"])
		#expect(s.found("b1", Self.b) == [])	// timer is not postponed
		#expect(s.fire(Self.b) == ["timer B 40s", "connecting B", "invite b1"])
	}

	@Test func lostWhileConnected() {
		let s = Script()
		_ = s.found("a1", Self.a)
		_ = s.state("a1", .connected)
		#expect(s.lost("a1") == [])	// still connected
		#expect(s.machine.sendHandle(for: Self.a) == "a1")
		#expect(s.state("a1", .notConnected) == ["disconnected A", "lost A"])
		#expect(s.machine.sendHandle(for: Self.a) == nil)
		#expect(s.found("a1", Self.a) == ["found A A", "timer A 40s", "connecting A", "invite a1"])
	}

	@Test func reconnectWithBackoff() {
		let s = Script()
		_ = s.found("a1", Self.a)
		_ = s.state("a1", .connected)
		#expect(s.state("a1", .notConnected) == ["disconnected A", "timer A 1s"])
		#expect(s.fire(Self.a) == ["timer A 40s", "connecting A", "invite a1"])
		#expect(s.state("a1", .notConnected) == ["disconnected A", "timer A 2s"])
	}

	@Test func renameKeepsPeer() {
		let s = Script()
		_ = s.found("a1", Self.a)
		_ = s.state("a1", .connected)
		#expect(s.found("a2", Self.a, name: "A2") == ["found A A2"])
		#expect(s.lost("a1") == [])	// outdated advertised handle
		#expect(s.machine.sendHandle(for: Self.a) == "a1")	// session stays on the old handle
		#expect(s.state("a1", .notConnected) == ["disconnected A", "timer A 1s"])	// still visible via a2
		#expect(s.fire(Self.a) == ["timer A 40s", "connecting A", "invite a2"])
		#expect(s.state("a1", .notConnected) == [])	// old handle no longer matters
		#expect(s.state("a2", .connected) == ["connected A"])
		#expect(s.lost("a2") == [])
		#expect(s.state("a2", .notConnected) == ["disconnected A", "lost A"])
	}

	@Test func simultaneousInvitations() {
		let s = Script()
		_ = s.found("a1", Self.a)	// we invite A
		#expect(s.invitation("a1", Self.a) == ["decline"])	// we are the designated inviter
		_ = s.found("b1", Self.b)
		_ = s.fire(Self.b)	// fallback: we invite B
		#expect(s.invitation("b1", Self.b) == ["accept", "timer B 40s"])
		#expect(s.state("b1", .connected) == ["connected B"])
	}

	@Test func invitationFromConnectedPeer() {
		let s = Script()
		_ = s.found("a1", Self.a)
		_ = s.state("a1", .connected)
		#expect(s.invitation("a1", Self.a) == ["accept", "disconnected A", "connecting A", "timer A 40s"])
		#expect(s.state("a1", .connected) == ["connected A"])
		#expect(s.invitation("a2", Self.a) == ["accept", "cancel a1", "disconnected A", "connecting A", "timer A 40s"])
		#expect(s.machine.sendHandle(for: Self.a) == nil)
		#expect(s.state("a1", .notConnected) == [])
	}

	@Test func watchdogCancelsStuckConnect() {
		let s = Script()
		_ = s.found("a1", Self.a)
		#expect(s.fire(Self.a) == ["cancel a1", "disconnected A", "timer A 1s"])
		#expect(s.state("a1", .connected) == ["cancel a1"])	// late link of the cancelled attempt
		#expect(s.fire(Self.a) == ["timer A 40s", "connecting A", "invite a1"])
	}

	@Test func capacity() {
		let s = Script(maxPeers: 1)
		_ = s.found("a1", Self.a)
		#expect(s.found("d1", Self.d) == ["found D D"])	// full: no invitation
		#expect(s.invitation("c1", Self.c) == ["decline"])
		#expect(s.invitation("a1", Self.a) == ["decline"])	// own invitation pending
		_ = s.state("a1", .connected)
		#expect(s.state("a1", .notConnected) == ["disconnected A", "timer A 1s", "timer D 40s", "connecting D", "invite d1"])
		#expect(s.fire(Self.a) == [])	// full again
		#expect(s.state("d1", .notConnected) == ["disconnected D", "timer D 1s", "timer A 1s"])	// slot free, A still backs off
		#expect(s.fire(Self.a) == ["timer A 40s", "connecting A", "invite a1"])
	}

	// MARK: - Link policy

	/// Cap 2 under a policy: 1 regular + 1 bridge slot; the bridge slot only for candidates, inviting
	/// and accepting alike.
	@Test func bridgeSlot() {
		#expect(LinkSlots(maxPeers: 7).regular == 6 && LinkSlots(maxPeers: 7).bridge == 1)
		#expect(LinkSlots(maxPeers: 2).regular == 1 && LinkSlots(maxPeers: 2).bridge == 1)
		#expect(LinkSlots(maxPeers: 1).regular == 1 && LinkSlots(maxPeers: 1).bridge == 0)
		let s = Script(maxPeers: 2)
		#expect(s.policy() == [])
		_ = s.found("a1", Self.a)
		_ = s.state("a1", .connected)
		#expect(s.found("d1", Self.d) == ["found D D"])	// regular slot taken, D no candidate
		#expect(s.invitation("c1", Self.c) == ["decline"])
		#expect(s.policy(candidates: [Self.c, Self.d]) == ["timer D 40s", "connecting D", "invite d1"])
		#expect(s.invitation("c1", Self.c) == ["decline"])	// all slots taken
		_ = s.state("d1", .connected)
		#expect(s.state("a1", .notConnected) == ["disconnected A", "timer A 1s"])
		#expect(s.invitation("c1", Self.c) == ["accept", "connecting C", "timer C 40s"])	// regular slot
	}

	@Test func suppressedAndFull() {
		let s = Script()
		_ = s.policy(suppressed: [Self.a], full: [Self.d])
		#expect(s.found("a1", Self.a) == ["found A A"])
		#expect(s.found("d1", Self.d) == ["found D D"])	// would decline: not invited
		#expect(s.invitation("a1", Self.a) == ["decline"])
		#expect(s.invitation("d1", Self.d) == ["accept", "connecting D", "timer D 40s"])
		#expect(s.policy() == ["timer A 40s", "connecting A", "invite a1"])
	}

	@Test func deliberateDisconnect() {
		let s = Script()
		_ = s.policy()
		_ = s.found("a1", Self.a)
		_ = s.state("a1", .connected)
		#expect(s.policy(suppressed: [Self.a]) == [])
		#expect(s.disconnect(Self.a) == ["cancel a1", "disconnected A"])	// suppressed: no reconnect
		#expect(s.disconnect(Self.a) == [])
		#expect(s.state("a1", .notConnected) == [])
		#expect(s.policy() == ["timer A 1s"])	// backoff counts the drop
		_ = s.found("b1", Self.b)
		_ = s.fire(Self.b)
		#expect(s.disconnect(Self.b) == ["cancel b1", "disconnected B", "timer B 6s"])	// pending link, backoff + fallback
	}
}
