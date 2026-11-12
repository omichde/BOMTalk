//
//  HelloTests.swift
//  BOMTalkTests
//

import Foundation
import Testing
@testable import BOMTalk

/// The relay's background traffic on the simulated radio network, on virtual time: hello cost per
/// link, the adaptive interval, keepalives, and name / info records that travel only when needed.
@Suite(.serialized) @MainActor struct HelloTests {

	/// Long runs: timers still fire at their exact deadlines, only `run(until:)` checks less often.
	static var coarse: SimConfig {
		var config = SimConfig()
		config.step = .milliseconds(100)
		return config
	}

	/// Info of about 140 bytes per device, like a host app's role and a few settings.
	static let info = ["role": "exhibit-kiosk", "room": "Hall B", "note": String(repeating: "x", count: 100)]

	/// Fully visible networks with the link policy: heartbeat bytes (hellos, keepalives, record
	/// requests) per link and second once converged stay flat beyond 30 devices. Measured: 10 / 30 / 50
	/// devices 868 / 2572 / 2619 B/s (before the lighter hello: 1960 / 5771 / 9690 B/s).
	@Test(arguments: [(10, 1_200), (30, 3_000), (50, 3_000)]) func heartbeatBytesPerLink(devices: Int, limit: Int) async {
		let net = SimNetwork(count: devices, seed: 60, config: Self.coarse, wrap: SimNetwork.relay)
		net.fullMesh()
		for device in net.devices {
			device.transport.start(info: Self.info)
		}
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(60)))
		await net.run(for: .seconds(60))
		let bytes = net.bytesSent, heartbeat = net.totalCounters.heartbeatBytesSent, start = net.now
		await net.run(for: .seconds(60))
		let seconds = (net.now - start).seconds
		let perLink = Double(net.bytesSent - bytes) / seconds / Double(net.connectedLinks)
		print("heartbeat bytes per link and second, \(devices) devices, \(net.connectedLinks) links: \(Int(perLink))")
		#expect(Int(perLink) <= limit)
		#expect(net.totalCounters.heartbeatBytesSent - heartbeat == net.bytesSent - bytes)	// nothing else on the links
		let interval = RelayPolicy.helloInterval(devices: devices)
		#expect(net.devices.allSatisfy { $0.relay.snapshot.helloInterval == interval })
		#expect(net.totalCounters.recordRequestsSent == 0)
		#expect(net.totalCounters.entriesExpired == 0)
		#expect(net.allConnected)
		#expect(net.contractViolations.isEmpty)
	}

	/// 150 devices in a sparse random graph: the interval reaches its 15 s cap, entries live 50 s, and
	/// keepalives keep every link heard well within the 10 s liveness window, so nothing stalls or
	/// expires over 75 s (5 intervals).
	@Test func cappedIntervalKeepsLinksAlive() async throws {
		let net = SimNetwork(count: 150, seed: 61, config: Self.coarse, wrap: SimNetwork.relay)
		net.randomConnected(maxDegree: 4, extraEdges: 40)
		try #require(net.isVisibilityConnected)
		try #require(net.diameter <= Int(RelayPolicy.hopLimit))
		var lastSent: [[Int]: Duration] = [:], longestGap: Duration = .zero
		net.loses = { _, from, to in
			let now = net.now
			if let last = lastSent[[from, to]] {
				longestGap = max(longestGap, now - last)
			}
			lastSent[[from, to]] = now
			return false
		}
		for device in net.devices {
			device.transport.start(info: Self.info)
		}
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(120)))
		await net.run(for: .seconds(20))
		let before = net.totalCounters, bytes = net.bytesSent, start = net.now
		lastSent = [:]
		longestGap = .zero
		for _ in 0 ..< 15 {
			await net.run(for: .seconds(5))
			}
		let after = net.totalCounters
		let perLink = Double(net.bytesSent - bytes) / (net.now - start).seconds / Double(net.connectedLinks)
		print("heartbeat bytes per link and second, 150 devices, \(net.connectedLinks) links: \(Int(perLink)), longest gap \(longestGap)")
		#expect(net.devices.allSatisfy { $0.relay.snapshot.helloInterval == RelayPolicy.maxHelloInterval })
		#expect(longestGap <= RelayPolicy.keepaliveInterval + RelayPolicy.sweepInterval + .milliseconds(100))
		#expect(after.keepalivesSent > before.keepalivesSent)
		#expect(after.stalledDisconnects == before.stalledDisconnects)
		#expect(after.entriesExpired == before.entriesExpired)
		#expect(after.voluntaryDrops == before.voluntaryDrops)
		#expect(net.linkChanges.filter { $0.at >= start }.isEmpty)
		#expect(net.allConnected)
		#expect(net.totalCounters.radioResets == 0)
		#expect(net.contractViolations.isEmpty)
	}

	/// Line 0 – 1 – 2, 2 joins while every hello carrying its record towards 0 is lost for 2 s: 0 knows
	/// 2's links but not its name, so it does not report 2 yet and asks; the answer arrives after the
	/// loss ends and 2 shows up with its name.
	@Test func lostRecordIsRequested() async throws {
		let net = SimNetwork(count: 3, seed: 62, wrap: SimNetwork.relay)
		net.line()
		net[0].start()
		net[1].start()
		#expect(await net.run(until: { net[0].peers(.connected) == [1] }, limit: .seconds(5)))
		var losing = true, lost = 0
		net.loses = { data, _, to in
			guard losing, to == 0, let envelope = RelayEnvelope(data), envelope.kind == .hello, envelope.origin == net[2].id,
				RelayHello.hasRecord(envelope.payload)
			else { return false }
			lost += 1
			return true
		}
		net[2].transport.start(info: ["role": "kiosk"])
		let started = net.now
		// 0 learns 2's links from its periodic hellos, which carry no record
		#expect(await net.run(until: { net[0].relay.snapshot.reachable.contains { $0.id == net[2].id } }, limit: .seconds(15)))
		await net.run(for: .seconds(1))
		#expect(lost >= 1)
		#expect(net[1].relay.snapshot.reachable.contains { $0.id == net[2].id && $0.name == "d2" })
		#expect(net[0].peers[net[2].id] == nil)	// routed, but not reported without a name
		#expect(net[0].relay.snapshot.counters.recordRequestsSent >= 1)
		losing = false
		#expect(await net.run(until: { net[0].peers[net[2].id]?.state == .connected }, limit: RelayPolicy.recordRequestGap + RelayPolicy.minHelloInterval * (1 + RelayPolicy.helloJitter) + .seconds(1)))
		print("named after \(net.now - started)")
		let found = net[0].events.compactMap { event -> TransportPeer? in
			if case let .connected(peer) = event, peer.id == net[2].id { peer } else { nil }
		}
		#expect(found.map(\.name) == ["d2"] && found.first?.info == ["role": "kiosk"])
		#expect(net[2].relay.snapshot.counters.recordRequestsReceived >= 1)
		#expect(net.contractViolations.isEmpty)
	}

	/// An info change whose hello is lost on the way to one device: that device keeps the old info
	/// until the next periodic hello names the new info version, asks, and gets the new record.
	@Test func lostInfoChangeIsRecovered() async throws {
		let net = SimNetwork(count: 3, seed: 63, wrap: SimNetwork.relay)
		net.line()
		for device in net.devices {
			device.transport.start(info: ["v": "1"])
		}
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(10)))
		await net.run(for: .seconds(5))
		var lost = 0
		net.loses = { data, _, to in
			guard lost == 0, to == 0, let envelope = RelayEnvelope(data), envelope.kind == .hello, envelope.origin == net[2].id,
				RelayHello.hasRecord(envelope.payload)
			else { return false }
			lost += 1
			return true
		}
		net[2].transport.update(info: ["v": "2"])
		let changed = net.now
		let info = { () -> [String: String]? in
			net[0].events.reversed().lazy.compactMap { event -> [String: String]? in
				switch event {
				case let .found(peer) where peer.id == net[2].id, let .connected(peer) where peer.id == net[2].id: peer.info
				default: nil
				}
			}.first
		}
		await net.run(for: .seconds(1))
		#expect(lost == 1)
		#expect(info() == ["v": "1"])	// stale meanwhile
		#expect(net[1].relay.snapshot.reachable.contains { $0.id == net[2].id })
		#expect(await net.run(until: { info() == ["v": "2"] }, limit: RelayPolicy.minHelloInterval * (1 + RelayPolicy.helloJitter) + .seconds(1)))
		print("recovered after \(net.now - changed)")
		#expect(net[0].relay.snapshot.counters.recordRequestsSent == 1)
		#expect(net[0].peers[net[2].id]?.state == .connected)	// never dropped meanwhile
		#expect(net.contractViolations.isEmpty)
	}

	/// `Talk.info` changes reach a device 3 hops away: in `peer.info` (Talk's info frame) and in the
	/// relay's view (the record in the next hello), without any record request.
	@Test func infoUpdateAcrossHops() async throws {
		let net = SimNetwork(count: 4, seed: 64, talk: true, wrap: SimNetwork.relay)
		net.line()
		let far = try #require(net[3].talk), near = try #require(net[0].talk)
		far.info = ["role": "kiosk"]
		net.startAll()
		#expect(await net.run(until: { net.allConnected }, limit: .seconds(10)))
		#expect(await net.run(until: { near.peer(far)?.info == ["role": "kiosk"] }, limit: .seconds(2)))
		far.info = ["role": "screen"]
		#expect(await net.run(until: { near.peer(far)?.info == ["role": "screen"] }, limit: .seconds(2)))
		#expect(await net.run(until: {
			net[0].events.contains { if case let .found(peer) = $0 { peer.id == far.me.id && peer.info == ["role": "screen"] } else { false } }
		}, limit: .seconds(2)))
		#expect(near.peer(far)?.name == "d3")
		#expect(net.totalCounters.recordRequestsSent == 0)
		#expect(net.contractViolations.isEmpty)
	}
}

extension Duration {
	var seconds: Double {
		Double(components.seconds) + Double(components.attoseconds) / 1e18
	}
}
