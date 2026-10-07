// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@Test func testSSEParserValidData() {
    let line = #"data: {"id":"gen-123","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"#
    let result = SSEParser.parse(line: line)
    #expect(result != nil)
    #expect(result?.choices.first?.delta?.content == "Hello")
}

@Test func testSSEParserDone() {
    let result = SSEParser.parse(line: "data: [DONE]")
    #expect(result == nil)
}

@Test func testSSEParserInvalidLine() {
    let result = SSEParser.parse(line: "not a data line")
    #expect(result == nil)
}

@Test
func testSSEParserEmitsMixedTextAndImagesInOrder() {
    let line = #"data: {"choices":[{"index":0,"delta":{"content":"Caption","images":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AQID"}}]},"message":{"images":[{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,BAUG"}}]},"finish_reason":"stop"}]}"#
    var seenImagePayloads = Set<Data>()

    let events = SSEParser.parseEvents(line: line, seenImagePayloads: &seenImagePayloads)

    #expect(events == [
        .text("Caption"),
        .image(data: Data([1, 2, 3]), mimeType: "image/png"),
        .image(data: Data([4, 5, 6]), mimeType: "image/jpeg")
    ])
}

@Test
func testSSEParserEmitsFinalMessageImageWithoutText() {
    let line = #"data: {"choices":[{"index":0,"message":{"role":"assistant","content":null,"images":[{"type":"image_url","image_url":{"url":"data:image/webp;base64,BwgJ"}}]},"finish_reason":"stop"}]}"#
    var seenImagePayloads = Set<Data>()

    let events = SSEParser.parseEvents(line: line, seenImagePayloads: &seenImagePayloads)

    #expect(events == [
        .image(data: Data([7, 8, 9]), mimeType: "image/webp")
    ])
}

@Test
func testSSEParserDeduplicatesImageAcrossDeltaAndFinalMessage() {
    let deltaLine = #"data: {"choices":[{"index":0,"delta":{"images":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AQID"}}]},"finish_reason":null}]}"#
    let finalLine = #"data: {"choices":[{"index":0,"message":{"images":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AQID"}}]},"finish_reason":"stop"}]}"#
    var seenImagePayloads = Set<Data>()

    let deltaEvents = SSEParser.parseEvents(
        line: deltaLine,
        seenImagePayloads: &seenImagePayloads
    )
    let finalEvents = SSEParser.parseEvents(
        line: finalLine,
        seenImagePayloads: &seenImagePayloads
    )

    #expect(deltaEvents == [
        .image(data: Data([1, 2, 3]), mimeType: "image/png")
    ])
    #expect(finalEvents.isEmpty)
}

@Test
func testSSEParserKeepsValidPartsWhenImagePayloadIsMalformed() {
    let line = #"data: {"choices":[{"index":0,"delta":{"content":"Still usable","images":[{"type":"image_url","image_url":{"url":"https://example.com/image.png"}},{"type":"image_url","image_url":{"url":"data:text/plain;base64,AQID"}},{"type":"image_url","image_url":{"url":"data:image/png;base64,%%%"}},{"type":"image_url","image_url":{"url":"data:image/png;base64,AQID"}}]},"finish_reason":null}]}"#
    var seenImagePayloads = Set<Data>()

    let events = SSEParser.parseEvents(line: line, seenImagePayloads: &seenImagePayloads)

    #expect(events == [
        .text("Still usable"),
        .invalidImage,
        .invalidImage,
        .invalidImage,
        .image(data: Data([1, 2, 3]), mimeType: "image/png")
    ])
}

@Test
func testSSEParserAcceptsNoSpacePrefixAndEmitsFinalMessageContent() {
    let line = #"data:{"choices":[{"index":0,"message":{"role":"assistant","content":"Final text"},"finish_reason":"stop"}]}"#
    var seenImagePayloads = Set<Data>()
    var hasSeenText = false

    let events = SSEParser.parseEvents(
        line: line,
        seenImagePayloads: &seenImagePayloads,
        hasSeenText: &hasSeenText
    )

    #expect(events == [.text("Final text")])
    #expect(hasSeenText)
}

@Test
func testSSEParserFlagsNonArrayImagesPayloadWithoutDroppingText() {
    let line = #"data: {"choices":[{"index":0,"delta":{"content":"Usable text","images":{"unexpected":true}},"finish_reason":null}]}"#
    var seenImagePayloads = Set<Data>()

    let events = SSEParser.parseEvents(line: line, seenImagePayloads: &seenImagePayloads)

    #expect(events == [.text("Usable text"), .invalidImage])
}

@Test
func testSSEParserDecodesMidStreamProviderError() throws {
    let line = #"data: {"id":"gen-error","error":{"code":429,"message":"Rate limit exceeded"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#

    let response = try #require(SSEParser.parse(line: line))

    #expect(response.error?.code == 429)
    #expect(response.error?.message == "Rate limit exceeded")
    #expect(response.choices.first?.finish_reason == "error")
}

@Test
func testSSEParserDistinguishesDoneMalformedAndControlLines() {
    if case .done = SSEParser.parseLine("data:[DONE]") {
        // Expected.
    } else {
        Issue.record("Expected a terminal SSE marker")
    }

    if case .malformedData = SSEParser.parseLine("data: {not-json}") {
        // Expected.
    } else {
        Issue.record("Expected malformed SSE data")
    }

    if case .ignored = SSEParser.parseLine(": keep-alive") {
        // Expected.
    } else {
        Issue.record("Expected an ignored SSE control line")
    }

    if case .ignored = SSEParser.parseLine("data:") {
        // Expected.
    } else {
        Issue.record("Expected an empty SSE data line to be ignored")
    }
}

@Test
func testOpenRouterStreamPreservesPartialTextThenThrowsSanitizedProviderError() async throws {
    let service = makeStreamingService(scenario: "provider-error")
    var events: [ChatStreamEvent] = []
    var caughtError: Error?

    do {
        for try await event in service.streamChat(
            request: testStreamRequest,
            config: testStreamConfig
        ) {
            events.append(event)
        }
    } catch {
        caughtError = error
    }

    #expect(events == [.text("Partial answer")])
    let aiError = try #require(caughtError as? AIError)
    guard case .httpError(let statusCode, let body) = aiError else {
        Issue.record("Expected a provider HTTP error")
        return
    }
    #expect(statusCode == 502)
    #expect(body == "OpenRouter returned an error. Image data was omitted.")
    #expect(!body.contains("SECRET_PAYLOAD"))
}

@Test
func testOpenRouterStreamRejectsCleanEOFMissingDoneMarker() async throws {
    let service = makeStreamingService(scenario: "missing-done")
    var events: [ChatStreamEvent] = []
    var caughtError: Error?

    do {
        for try await event in service.streamChat(
            request: testStreamRequest,
            config: testStreamConfig
        ) {
            events.append(event)
        }
    } catch {
        caughtError = error
    }

    #expect(events == [.text("Partial answer")])
    let aiError = try #require(caughtError as? AIError)
    guard case .invalidResponse = aiError else {
        Issue.record("Expected an invalid response for a stream without DONE")
        return
    }
}

@Test
func testOpenRouterStreamRejectsMalformedDataChunk() async throws {
    let service = makeStreamingService(scenario: "malformed")
    var caughtError: Error?

    do {
        for try await _ in service.streamChat(
            request: testStreamRequest,
            config: testStreamConfig
        ) {}
    } catch {
        caughtError = error
    }

    let aiError = try #require(caughtError as? AIError)
    guard case .invalidResponse = aiError else {
        Issue.record("Expected an invalid response for malformed SSE data")
        return
    }
}

@Test
func testOpenRouterStreamAcceptsControlLinesAndDoneMarker() async throws {
    let service = makeStreamingService(scenario: "complete")
    var events: [ChatStreamEvent] = []

    for try await event in service.streamChat(
        request: testStreamRequest,
        config: testStreamConfig
    ) {
        events.append(event)
    }

    #expect(events == [.text("Complete answer")])
}

private let testStreamRequest = ChatRequest(
    model: "vendor/test",
    messages: [.user("Hello")],
    stream: true
)

private let testStreamConfig = ResolvedAIConfig(
    apiKey: "key",
    model: "vendor/test",
    temperature: 0.7,
    maxTokens: 2_048
)

private func makeStreamingService(scenario: String) -> AIEndpointService {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamingURLProtocol.self]
    configuration.httpAdditionalHeaders = ["X-Test-Stream-Scenario": scenario]
    return AIEndpointService(
        apiKey: "key",
        session: URLSession(configuration: configuration)
    )
}

private final class StreamingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body: String
        switch request.value(forHTTPHeaderField: "X-Test-Stream-Scenario") {
        case "provider-error":
            body = """
            data: {"choices":[{"index":0,"delta":{"content":"Partial answer"},"finish_reason":null}]}

            data: {"error":{"code":502,"message":"data:image/png;base64,SECRET_PAYLOAD"},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}

            """
        case "missing-done":
            body = """
            data: {"choices":[{"index":0,"delta":{"content":"Partial answer"},"finish_reason":"stop"}]}

            """
        case "malformed":
            body = """
            data: {not-json}

            data: [DONE]

            """
        default:
            body = """
            : OPENROUTER PROCESSING

            data:

            data: {"choices":[{"index":0,"delta":{"content":"Complete answer"},"finish_reason":"stop"}]}

            data:[DONE]

            """
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
