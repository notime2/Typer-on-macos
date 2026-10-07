// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@Suite
struct StreamReplayServiceTests {
    @Test
    func fixtureLoadsOnlyWithExplicitArgument() throws {
        let normalLaunchFixture: StreamReplayFixture? = try StreamReplayFixture.fromLaunchArguments([
            "Typer On", "/missing/fixture.json"
        ])
        #expect(normalLaunchFixture == nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(##"{"chunks":["# Heading\n","Synthetic текст 😀"],"intervalMilliseconds":10}"##.utf8).write(to: url)
        let fixture = try StreamReplayFixture.fromLaunchArguments(["Typer On", StreamReplayFixture.argument, url.path])
        #expect(fixture?.chunks == ["# Heading\n", "Synthetic текст 😀"])
        #expect(fixture?.intervalMilliseconds == 10)
    }

    @Test(arguments: [
        ["Typer On", StreamReplayFixture.argument],
        ["Typer On", StreamReplayFixture.argument, ""],
        ["Typer On", StreamReplayFixture.argument, "--other-option"],
        ["Typer On", StreamReplayFixture.argument + "=/missing/fixture.json"],
        ["Typer On", StreamReplayFixture.argument, "a.json", StreamReplayFixture.argument, "b.json"]
    ])
    func invalidArgumentsFailClosed(arguments: [String]) {
        #expect(throws: StreamReplayError.invalidArguments) {
            try StreamReplayFixture.fromLaunchArguments(arguments)
        }
    }

    @Test
    func missingFileFailsClosed() {
        let missingPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        #expect(throws: StreamReplayError.unreadableFixture) {
            try StreamReplayFixture.fromLaunchArguments(["Typer On", StreamReplayFixture.argument, missingPath])
        }
    }

    @Test(arguments: [
        "{}",
        #"{"chunks":[],"intervalMilliseconds":10}"#,
        #"{"chunks":[""],"intervalMilliseconds":10}"#,
        #"{"chunks":["text"],"intervalMilliseconds":0}"#,
        #"{"chunks":["text"],"intervalMilliseconds":1001}"#,
        #"{"chunks":["text"],"intervalMilliseconds":1.5}"#,
        #"{"chunks":["text"],"intervalMilliseconds":"10"}"#,
        "not JSON"
    ])
    func malformedFixtureFailsClosed(json: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        #expect(throws: StreamReplayError.invalidFixture) {
            try StreamReplayFixture.fromLaunchArguments(["Typer On", StreamReplayFixture.argument, url.path])
        }
    }

    @Test
    func fixtureBoundsFilePayloadCountAndDuration() throws {
        #expect(throws: StreamReplayError.invalidFixture) {
            try StreamReplayFixture(chunks: Array(repeating: "x", count: 8193), intervalMilliseconds: 1)
        }
        #expect(throws: StreamReplayError.invalidFixture) {
            try StreamReplayFixture(chunks: [String(repeating: "я", count: 131_073)], intervalMilliseconds: 1)
        }
        #expect(throws: StreamReplayError.invalidFixture) {
            try StreamReplayFixture(chunks: Array(repeating: "x", count: 121), intervalMilliseconds: 1000)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 32, count: StreamReplayFixture.maximumFileBytes + 1).write(to: url)
        #expect(throws: StreamReplayError.invalidFixture) {
            try StreamReplayFixture.fromLaunchArguments(["Typer On", StreamReplayFixture.argument, url.path])
        }
    }

    @Test
    func repeatedRequestsStartFromFirstChunkAndChatUsesTextEvents() async throws {
        let fixture = try StreamReplayFixture(chunks: ["# Title\n", "One ", "two."], intervalMilliseconds: 10)
        let service = StreamReplayService(fixture: fixture, sleep: { _ in })
        for _ in 0..<2 {
            var chunks: [String] = []
            for try await chunk in service.stream(request: request, config: config) { chunks.append(chunk) }
            #expect(chunks == fixture.chunks)
        }
        var events: [ChatStreamEvent] = []
        for try await event in service.streamChat(request: request, config: config) { events.append(event) }
        let expectedEvents: [ChatStreamEvent] = fixture.chunks.map { .text($0) }
        #expect(events == expectedEvents)
    }

    @Test
    func cancellingConsumerCancelsProducerBeforeNextChunk() async throws {
        let gate = ReplaySleepGate()
        let fixture = try StreamReplayFixture(chunks: ["first", "must not arrive"], intervalMilliseconds: 10)
        let service = StreamReplayService(fixture: fixture, sleep: { _ in try await gate.sleep() })
        let stream = service.stream(request: request, config: config)
        let consumer = Task<[String], Error> {
            var received: [String] = []
            do {
                for try await chunk in stream {
                    received.append(chunk)
                    await gate.didReceiveFirstChunk()
                }
            } catch is CancellationError {
                // Cancellation can terminate an AsyncThrowingStream with or without throwing.
            }
            return received
        }
        await gate.waitUntilFirstChunkReceived()
        await gate.waitUntilSleeping()
        consumer.cancel()
        let received: [String] = try await consumer.value
        #expect(received == ["first"])
        await gate.waitUntilCancelled()
        let wasCancelled: Bool = await gate.wasCancelled
        #expect(wasCancelled)
    }

    private var request: ChatRequest {
        ChatRequest(model: "replay/local", messages: [.user("synthetic")])
    }

    private var config: ResolvedAIConfig {
        ResolvedAIConfig(apiKey: "", model: "replay/local", temperature: 0.7, maxTokens: 20480)
    }
}

private actor ReplaySleepGate {
    private var sleeper: CheckedContinuation<Void, Error>?
    private var sleepingWaiter: CheckedContinuation<Void, Never>?
    private var cancelledWaiter: CheckedContinuation<Void, Never>?
    private var receivedWaiter: CheckedContinuation<Void, Never>?
    private var hasSlept = false
    private var hasReceived = false
    private(set) var wasCancelled = false

    func sleep() async throws {
        try await withTaskCancellationHandler(operation: {
            try await suspendUntilCancellation()
        }, onCancel: {
            _ = Task<Void, Never> { await self.cancel() }
        })
    }

    private func suspendUntilCancellation() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if wasCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                sleeper = continuation
                hasSlept = true
                sleepingWaiter?.resume()
                sleepingWaiter = nil
            }
        }
    }

    func waitUntilSleeping() async {
        guard !hasSlept else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sleepingWaiter = continuation
        }
    }

    func waitUntilCancelled() async {
        guard !wasCancelled else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cancelledWaiter = continuation
        }
    }

    func waitUntilFirstChunkReceived() async {
        guard !hasReceived else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            receivedWaiter = continuation
        }
    }

    func didReceiveFirstChunk() {
        hasReceived = true
        receivedWaiter?.resume()
        receivedWaiter = nil
    }

    private func cancel() {
        wasCancelled = true
        sleeper?.resume(throwing: CancellationError())
        sleeper = nil
        cancelledWaiter?.resume()
        cancelledWaiter = nil
    }
}
