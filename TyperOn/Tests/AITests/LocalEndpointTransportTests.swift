// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

private let localEndpoint = AIEndpointConfiguration.openAICompatible(
    baseURL: URL(string: "http://localhost:11434/v1")!
)

private let transportRequest = ChatRequest(
    model: "gemma4:e2b-mlx",
    messages: [.user("Hello")],
    stream: true
)

private func transportConfig(apiKey: String, model: String = "gemma4:e2b-mlx") -> ResolvedAIConfig {
    ResolvedAIConfig(apiKey: apiKey, model: model, temperature: 0.7, maxTokens: 2_048)
}

@Suite
struct LocalEndpointRequestBuildingTests {
    @Test
    func openRouterRequestKeepsItsURLAndHeaders() throws {
        let service = AIEndpointService(apiKey: "key")
        let request = try service.buildURLRequest(for: transportRequest, apiKey: "openrouter-key")

        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer openrouter-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Title") == "Typer On")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "https://github.com/notime2/Typer-on-macos")
    }

    @Test
    func openRouterStillRequiresAnAPIKey() {
        let service = AIEndpointService(apiKey: "")
        #expect(throws: AIError.self) {
            try service.buildURLRequest(for: transportRequest, apiKey: "")
        }
    }

    @Test
    func localRequestUsesTheConfiguredBaseURLWithoutOpenRouterHeaders() throws {
        let service = AIEndpointService(endpoint: localEndpoint, apiKey: "")
        let request = try service.buildURLRequest(for: transportRequest, apiKey: "")

        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Title") == nil)
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(decoded?["model"] as? String == "gemma4:e2b-mlx")
        #expect(decoded?["stream"] as? Bool == true)
    }

    @Test
    func localRequestSendsBearerOnlyWhenAKeyExists() throws {
        let service = AIEndpointService(endpoint: localEndpoint, apiKey: "local-secret")
        let request = try service.buildURLRequest(for: transportRequest, apiKey: "local-secret")

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-secret")
        #expect(request.value(forHTTPHeaderField: "X-Title") == nil)
    }

    @Test
    func localProviderNeverBuildsAnImagesRequest() async {
        let service = AIEndpointService(endpoint: localEndpoint, apiKey: "local-secret")
        let request = ImageGenerationRequest(model: "gemma4:e2b-mlx", prompt: "draw a cat")

        #expect(throws: AIServiceFeatureError.imageGenerationUnsupported) {
            try service.buildImagesURLRequest(for: request, config: transportConfig(apiKey: "local-secret"))
        }

        await #expect(throws: AIServiceFeatureError.imageGenerationUnsupported) {
            try await service.generateImages(request: request, config: transportConfig(apiKey: "local-secret"))
        }
    }
}

/// One serialized suite: the streaming stub and the probe stub share process-wide state.
@Suite(.serialized)
struct LocalEndpointNetworkTests {
    @Test
    func localStreamDeliversTypedTextEventsThroughTheSharedSSEPath() async throws {
        let service = makeLocalStreamingService(
            body: """
            data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"OK"},"finish_reason":null}]}

            data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" done"},"finish_reason":null}]}

            data: {"id":"chatcmpl-1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

            data: [DONE]

            """
        )

        var events: [ChatStreamEvent] = []
        for try await event in service.streamChat(request: transportRequest, config: transportConfig(apiKey: "")) {
            events.append(event)
        }

        #expect(events == [.text("OK"), .text(" done")])
        let request = try #require(LocalStreamStub.recorder.requests.last)
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Title") == nil)
    }

    @Test
    func localStreamSurfacesEndpointErrors() async throws {
        let service = makeLocalStreamingService(
            body: #"{"error":{"message":"model \"missing\" not found"}}"#,
            status: 404
        )

        var caught: Error?
        do {
            for try await _ in service.streamChat(request: transportRequest, config: transportConfig(apiKey: "")) {}
        } catch {
            caught = error
        }

        let aiError = try #require(caught as? AIError)
        guard case .modelNotFound = aiError else {
            Issue.record("Expected a model-not-found error for an unknown local model")
            return
        }
    }
}

private func makeLocalStreamingService(body: String, status: Int = 200) -> AIEndpointService {
    LocalStreamStub.recorder = LocalStreamRecorder(body: body, status: status)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LocalStreamStub.self]
    return AIEndpointService(
        endpoint: localEndpoint,
        apiKey: "",
        session: URLSession(configuration: configuration)
    )
}

private final class LocalStreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let body: String
    let status: Int

    init(body: String, status: Int) {
        self.body = body
        self.status = status
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func record(_ request: URLRequest) {
        lock.withLock { recorded.append(request) }
    }
}

private final class LocalStreamStub: URLProtocol, @unchecked Sendable {
    // The suite is serialized, so assignment always precedes the requests it serves.
    nonisolated(unsafe) static var recorder = LocalStreamRecorder(body: "", status: 200)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.recorder.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.recorder.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension LocalEndpointNetworkTests {
    @Test
    func probeReportsTheModelCount() async {
        let probe = makeProbe(status: 200, body: #"{"object":"list","data":[{"id":"a"},{"id":"b"}]}"#)
        let result = await probe.probe(baseURLText: "http://localhost:11434/v1", apiKey: "")

        #expect(result == .success(modelCount: 2))
        #expect(result.message == "Connected. 2 models available.")
        #expect(LocalStreamStub.recorder.requests.last?.url?.absoluteString == "http://localhost:11434/v1/models")
    }

    @Test
    func probeReportsAnHTTPFailureInline() async {
        let probe = makeProbe(status: 404, body: "not found")
        let result = await probe.probe(baseURLText: "http://localhost:11434/v1", apiKey: "")

        #expect(!result.isSuccess)
        #expect(result.message == "The endpoint answered with HTTP 404.")
    }

    @Test
    func probeReportsAnUnexpectedPayloadInline() async {
        let probe = makeProbe(status: 200, body: #"{"models":["a"]}"#)
        let result = await probe.probe(baseURLText: "http://localhost:11434/v1", apiKey: "")

        #expect(!result.isSuccess)
        #expect(result.message == "The endpoint answered, but the model list was not in the OpenAI format.")
    }

    @Test
    func probeRejectsAnInsecureRemoteURLWithoutSendingARequest() async {
        let probe = makeProbe(status: 200, body: #"{"data":[]}"#)
        let result = await probe.probe(baseURLText: "http://models.example.com/v1", apiKey: "")

        #expect(!result.isSuccess)
        #expect(result.message == AIEndpointError.insecureRemoteHost("models.example.com").localizedDescription)
        #expect(LocalStreamStub.recorder.requests.isEmpty)
    }

    private func makeProbe(status: Int, body: String) -> LocalEndpointProbe {
        LocalStreamStub.recorder = LocalStreamRecorder(body: body, status: status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalStreamStub.self]
        return LocalEndpointProbe(session: URLSession(configuration: configuration))
    }
}
