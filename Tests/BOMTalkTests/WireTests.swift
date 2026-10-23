//
//  WireTests.swift
//  BOMTalkTests
//

import Foundation
import Testing
@testable import BOMTalk

@Suite struct WireTests {

	@Test(arguments: [
		Frame.offer(.init(transferID: UUID(), kind: "ümlaut-🎉", totalBytes: 1 << 40, chunkCount: 123_456)),
		Frame.accept(UUID()),
		Frame.reject(UUID()),
		Frame.chunk(transferID: UUID(), index: 7, payload: Data([1, 2, 3])),
		Frame.info(["role": "controller"]),
	])
	func frameRoundTrip(_ frame: Frame) {
		#expect(Frame(frame.encoded()) == frame)
	}

	@Test func frameRejectsMalformed() {
		let accept = Frame.accept(UUID()).encoded()
		var wrongVersion = accept
		wrongVersion[2] = 2
		var unknownType = accept
		unknownType[3] = 99
		let malformed: [Data] = [
			Data(),
			Data("XX".utf8) + accept.dropFirst(2),
			wrongVersion,
			unknownType,
			accept.dropLast(),
			accept + Data([0]),
			Frame.chunk(transferID: UUID(), index: 0, payload: Data(count: Frame.maxChunkPayload + 1)).encoded(),
		]
		for data in malformed {
			#expect(Frame(data) == nil)
		}
	}

	@Test func codecRoundTrip() async throws {
		let blob = Blob(data: Data(repeating: 7, count: 100_000))
		let payload = try await Codec.encode(blob)
		#expect(payload.count < 10_000)	// compressed
		#expect(try await Codec.decode(Blob.self, from: payload) == blob)
	}
}
