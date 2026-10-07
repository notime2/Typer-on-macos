// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct StreamReplayFixture: Decodable, Sendable, Equatable {
    static let argument = "--qa-stream-replay"
    static let maximumFileBytes = 1_048_576

    let chunks: [String]
    let intervalMilliseconds: Int

    init(chunks: [String], intervalMilliseconds: Int) throws {
        guard !chunks.isEmpty, chunks.count <= 8192,
              chunks.allSatisfy({ !$0.isEmpty }),
              chunks.reduce(0, { $0 + $1.utf8.count }) <= 262_144,
              (1...1000).contains(intervalMilliseconds),
              chunks.count * intervalMilliseconds <= 120_000 else {
            throw StreamReplayError.invalidFixture
        }
        self.chunks = chunks
        self.intervalMilliseconds = intervalMilliseconds
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            chunks: container.decode([String].self, forKey: .chunks),
            intervalMilliseconds: container.decode(Int.self, forKey: .intervalMilliseconds)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case chunks, intervalMilliseconds
    }

    static func fromLaunchArguments(_ arguments: [String]) throws -> Self? {
        guard !arguments.contains(where: { $0.hasPrefix(argument + "=") }) else {
            throw StreamReplayError.invalidArguments
        }
        let positions = arguments.indices.filter { arguments[$0] == argument }
        guard !positions.isEmpty else { return nil }
        guard positions.count == 1,
              let position = positions.first,
              position + 1 < arguments.count,
              !arguments[position + 1].hasPrefix("-"),
              !arguments[position + 1].isEmpty else {
            throw StreamReplayError.invalidArguments
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: arguments[position + 1]))
        } catch {
            throw StreamReplayError.unreadableFixture
        }
        defer { try? handle.close() }

        do {
            // Bound the read itself, rather than trusting a potentially stale file-size check.
            let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
            guard data.count <= maximumFileBytes else { throw StreamReplayError.invalidFixture }
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw StreamReplayError.invalidFixture
        }
    }
}

enum StreamReplayError: LocalizedError, Equatable {
    case invalidArguments
    case unreadableFixture
    case invalidFixture

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Use --qa-stream-replay followed by one local fixture path."
        case .unreadableFixture:
            return "The stream replay fixture could not be opened."
        case .invalidFixture:
            return "The stream replay fixture is malformed or exceeds its size or duration limit."
        }
    }
}

struct StreamReplayService: AIService {
    let fixture: StreamReplayFixture
    private let sleep: @Sendable (Int) async throws -> Void

    init(
        fixture: StreamReplayFixture,
        sleep: @escaping @Sendable (Int) async throws -> Void = {
            try await Task.sleep(for: .milliseconds($0))
        }
    ) {
        self.fixture = fixture
        self.sleep = sleep
    }

    func stream(request: ChatRequest, config: ResolvedAIConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for (index, chunk) in fixture.chunks.enumerated() {
                        if index > 0 {
                            try await sleep(fixture.intervalMilliseconds)
                        }
                        try Task.checkCancellation()
                        if case .terminated = continuation.yield(chunk) { return }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
