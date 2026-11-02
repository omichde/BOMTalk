//
//  SoakStats.swift
//  BOMTalkSample
//

import Foundation

/// What arrived from one origin of numbered pings: counts, ordering problems, gaps and latency.
/// Pure value logic, `ControlCenter` feeds it. Encodes with `gaps` and the average computed.
struct OriginStats: Encodable, Equatable, Sendable {

	/// Arrivals, duplicates included.
	private(set) var received = 0
	/// Arrivals of a sequence number seen before.
	private(set) var duplicates = 0
	/// First arrivals of a number below the highest seen so far.
	private(set) var outOfOrder = 0
	/// Numbers between the first and the highest seen that never arrived (yet).
	var gaps: Int { unique == 0 ? 0 : max(0, lastSeq - firstSeq + 1 - unique) }
	private(set) var firstSeq = 0
	/// Highest sequence number seen.
	private(set) var lastSeq = 0
	private(set) var latencyMinMs = 0.0
	private(set) var latencyMaxMs = 0.0
	var latencyAvgMs: Double { unique == 0 ? 0 : latencySum / Double(unique) }
	/// Seconds since 1970 of the last arrival.
	private(set) var lastReceivedAt = 0.0

	/// Distinct sequence numbers seen.
	private(set) var unique = 0
	private var latencySum = 0.0
	private var seen: Set<Int> = []

	/// Numbers older than this behind the highest are forgotten (a duplicate of one counts as new).
	static let window = 4096

	enum CodingKeys: String, CodingKey {
		case received, unique, duplicates, outOfOrder, gaps, firstSeq, lastSeq, latencyMinMs, latencyAvgMs, latencyMaxMs, lastReceivedAt
	}

	func encode(to encoder: any Encoder) throws {
		var c = encoder.container(keyedBy: CodingKeys.self)
		try c.encode(received, forKey: .received)
		try c.encode(unique, forKey: .unique)
		try c.encode(duplicates, forKey: .duplicates)
		try c.encode(outOfOrder, forKey: .outOfOrder)
		try c.encode(gaps, forKey: .gaps)
		try c.encode(firstSeq, forKey: .firstSeq)
		try c.encode(lastSeq, forKey: .lastSeq)
		try c.encode(latencyMinMs, forKey: .latencyMinMs)
		try c.encode(latencyAvgMs, forKey: .latencyAvgMs)
		try c.encode(latencyMaxMs, forKey: .latencyMaxMs)
		try c.encode(lastReceivedAt, forKey: .lastReceivedAt)
	}

	mutating func record(seq: Int, sentAt: Double, receivedAt: Double) {
		received += 1
		lastReceivedAt = receivedAt
		if seen.contains(seq) {
			duplicates += 1
			return
		}
		let latency = max(0, (receivedAt - sentAt) * 1000)
		if unique == 0 {
			firstSeq = seq
			lastSeq = seq
			latencyMinMs = latency
			latencyMaxMs = latency
		} else {
			if seq < lastSeq {
				outOfOrder += 1
			}
			firstSeq = min(firstSeq, seq)
			lastSeq = max(lastSeq, seq)
			latencyMinMs = min(latencyMinMs, latency)
			latencyMaxMs = max(latencyMaxMs, latency)
		}
		unique += 1
		latencySum += latency
		seen.insert(seq)
		if seen.count > Self.window * 2 {
			seen = seen.filter { $0 > lastSeq - Self.window }
		}
	}
}
