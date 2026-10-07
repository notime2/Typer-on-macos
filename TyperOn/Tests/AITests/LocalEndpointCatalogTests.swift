// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@Suite
struct OpenAIModelListDecodingTests {
    @Test
    func decodesTheOpenAIListShape() throws {
        let json = #"""
        {"object":"list","data":[
          {"id":"gemma4:e2b-mlx","object":"model","created":1787039766,"owned_by":"library"},
          {"id":"qwen3:8b","object":"model"}
        ]}
        """#
        let response = try JSONDecoder().decode(OpenAIModelListResponse.self, from: Data(json.utf8))
        #expect(response.modelIDs == ["gemma4:e2b-mlx", "qwen3:8b"])
    }

    @Test
    func skipsUnusableEntriesAndDuplicatesWithoutFailingTheList() throws {
        let json = #"""
        {"data":[{"id":"  keep-me  "},{"object":"model"},{"id":""},{"id":null},{"id":"keep-me"},{"id":"second"}]}
        """#
        let response = try JSONDecoder().decode(OpenAIModelListResponse.self, from: Data(json.utf8))
        #expect(response.modelIDs == ["keep-me", "second"])
    }

    @Test
    func rejectsAPayloadWithoutAModelList() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(OpenAIModelListResponse.self, from: Data(#"{"models":[]}"#.utf8))
        }
    }
}

@Suite(.serialized)
@MainActor
struct LocalEndpointCatalogTests {
    private static let localBaseURL = URL(string: "http://localhost:11434/v1")!
    private static let otherBaseURL = URL(string: "http://localhost:1234/v1")!
    private static let ollamaList = #"{"object":"list","data":[{"id":"qwen3:8b"},{"id":"gemma4:e2b-mlx"}]}"#

    @Test
    func localCatalogListsIDsWithoutModalityMetadataOrOpenRouterHeaders() async throws {
        let fixture = try LocalCatalogFixture()
        defer { fixture.cleanUp() }
        LocalCatalogStub.responses.set(status: 200, body: Self.ollamaList)

        await fixture.catalog.fetchModels(apiKey: "", source: .openAICompatible(baseURL: Self.localBaseURL))

        #expect(fixture.catalog.models.map(\.id) == ["gemma4:e2b-mlx", "qwen3:8b"])
        #expect(fixture.catalog.models.map(\.displayName) == ["gemma4:e2b-mlx", "qwen3:8b"])
        #expect(fixture.catalog.models.allSatisfy { $0.context_length == nil })
        #expect(fixture.catalog.models.allSatisfy { !$0.hasCompleteModalityMetadata })
        #expect(fixture.catalog.models.allSatisfy { !$0.supportsImageInput && !$0.supportsImageOutput })
        #expect(fixture.catalog.groupedModels.map(\.provider) == ["Local"])
        #expect(fixture.catalog.displayName(for: "gemma4:e2b-mlx") == "gemma4:e2b-mlx")
        #expect(fixture.catalog.groups(matching: "GEMMA").flatMap(\.models).map(\.id) == ["gemma4:e2b-mlx"])

        let request = try #require(LocalCatalogStub.responses.requests.last)
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Title") == nil)
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
    }

    @Test
    func localCatalogSendsBearerOnlyWhenAKeyExists() async throws {
        let fixture = try LocalCatalogFixture()
        defer { fixture.cleanUp() }
        LocalCatalogStub.responses.set(status: 200, body: Self.ollamaList)

        await fixture.catalog.fetchModels(apiKey: "local-secret", source: .openAICompatible(baseURL: Self.localBaseURL))

        let request = try #require(LocalCatalogStub.responses.requests.last)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-secret")
        #expect(request.value(forHTTPHeaderField: "X-Title") == nil)
    }

    @Test
    func openRouterRefreshKeepsItsURLAndHeaders() async throws {
        let fixture = try LocalCatalogFixture()
        defer { fixture.cleanUp() }
        LocalCatalogStub.responses.set(status: 200, body: #"{"data":[{"id":"vendor/model","name":"Vendor Model"}]}"#)

        await fixture.catalog.fetchModels(apiKey: "openrouter-key")

        let request = try #require(LocalCatalogStub.responses.requests.last)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer openrouter-key")
        #expect(request.value(forHTTPHeaderField: "X-Title") == "Typer On")
        #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "https://github.com/notime2/Typer-on-macos")
        #expect(fixture.defaults.data(for: .cachedModelList) != nil)
        #expect(fixture.defaults.data(for: .cachedLocalModelList) == nil)
    }

    @Test
    func switchingProvidersNeverShowsTheOtherProvidersList() async throws {
        let fixture = try LocalCatalogFixture()
        defer { fixture.cleanUp() }
        LocalCatalogStub.responses.set(status: 200, body: #"{"data":[{"id":"vendor/model","name":"Vendor Model"}]}"#)
        await fixture.catalog.fetchModels(apiKey: "openrouter-key")
        #expect(fixture.catalog.models.map(\.id) == ["vendor/model"])

        fixture.catalog.setSource(.openAICompatible(baseURL: Self.localBaseURL))
        #expect(fixture.catalog.models.isEmpty)
        #expect(fixture.catalog.displayModels.isEmpty)
        #expect(fixture.catalog.groupedModels.isEmpty)
        #expect(fixture.catalog.displayName(for: AIModelDefaults.defaultModelID) == AIModelDefaults.defaultModelID)

        await fixture.catalog.loadCached()
        #expect(fixture.catalog.models.isEmpty)

        fixture.catalog.setSource(.openRouter)
        #expect(fixture.catalog.displayModels.map(\.id) == ModelCatalogService.defaultModels.map(\.id))
        await fixture.catalog.loadCached()
        #expect(fixture.catalog.models.map(\.id) == ["vendor/model"])
    }

    @Test
    func unconfiguredLocalProviderNeverRequestsOrShowsDefaults() async throws {
        let fixture = try LocalCatalogFixture()
        defer { fixture.cleanUp() }
        LocalCatalogStub.responses.set(status: 200, body: Self.ollamaList)

        await fixture.catalog.fetchModels(apiKey: "", source: .unconfigured)

        #expect(LocalCatalogStub.responses.requests.isEmpty)
        #expect(fixture.catalog.models.isEmpty)
        #expect(fixture.catalog.displayModels.isEmpty)
        #expect(fixture.catalog.groupedModels.isEmpty)
    }

    @Test
    func localCacheIsKeyedByBaseURL() async throws {
        let fixture = try LocalCatalogFixture()
        defer { fixture.cleanUp() }
        LocalCatalogStub.responses.set(status: 200, body: Self.ollamaList)
        await fixture.catalog.fetchModels(apiKey: "", source: .openAICompatible(baseURL: Self.localBaseURL))
        #expect(fixture.defaults.data(for: .cachedLocalModelList) != nil)

        let restarted = fixture.makeCatalog()
        restarted.setSource(.openAICompatible(baseURL: Self.otherBaseURL))
        await restarted.loadCached()
        #expect(restarted.models.isEmpty)

        restarted.setSource(.openAICompatible(baseURL: Self.localBaseURL))
        await restarted.loadCached()
        #expect(restarted.models.map(\.id) == ["gemma4:e2b-mlx", "qwen3:8b"])
        #expect(LocalCatalogStub.responses.requests.count == 1)
    }

    @Test
    func failedLocalRefreshKeepsTheLastCachedList() async throws {
        let fixture = try LocalCatalogFixture()
        defer { fixture.cleanUp() }
        LocalCatalogStub.responses.set(status: 200, body: Self.ollamaList)
        await fixture.catalog.fetchModels(apiKey: "", source: .openAICompatible(baseURL: Self.localBaseURL))
        let cached = fixture.defaults.data(for: .cachedLocalModelList)

        LocalCatalogStub.responses.set(status: 500, body: "boom")
        await fixture.catalog.fetchModels(apiKey: "")

        #expect(fixture.catalog.models.map(\.id) == ["gemma4:e2b-mlx", "qwen3:8b"])
        #expect(fixture.catalog.error != nil)
        #expect(!fixture.catalog.isLoading)
        #expect(fixture.defaults.data(for: .cachedLocalModelList) == cached)
    }

    /// OpenRouter keeps the exact error value and text its catalog reported before the endpoint
    /// became configurable, so a non-200 refresh never gains a status-code message.
    @Test
    func openRouterRefreshFailureKeepsItsOriginalURLError() async throws {
        let fixture = try LocalCatalogFixture()
        defer { fixture.cleanUp() }
        LocalCatalogStub.responses.set(status: 500, body: "boom")

        await fixture.catalog.fetchModels(apiKey: "openrouter-key", source: .openRouter)

        #expect(fixture.catalog.error == URLError(.badServerResponse).localizedDescription)
        await #expect(throws: URLError(.badServerResponse)) {
            try await AIEndpointRequest.data(
                url: AIEndpointConfiguration.openRouter.modelsURL,
                endpoint: .openRouter,
                apiKey: "openrouter-key",
                session: fixture.session
            )
        }
    }

    /// The user-configured local endpoint keeps the descriptive status-code message instead.
    @Test
    func localRefreshFailureReportsTheHTTPStatus() async throws {
        let fixture = try LocalCatalogFixture()
        defer { fixture.cleanUp() }
        LocalCatalogStub.responses.set(status: 503, body: "boom")
        let endpoint = AIEndpointConfiguration.openAICompatible(baseURL: Self.localBaseURL)

        await fixture.catalog.fetchModels(apiKey: "", source: .openAICompatible(baseURL: Self.localBaseURL))

        #expect(fixture.catalog.error == "The endpoint answered with HTTP 503.")
        await #expect(throws: AIEndpointRequestError.httpStatus(503)) {
            try await AIEndpointRequest.data(
                url: endpoint.modelsURL, endpoint: endpoint, apiKey: "", session: fixture.session
            )
        }
    }

    @Test
    func localModelMetadataResolvesFromTheListWithoutAnotherRequest() async throws {
        let fixture = try LocalCatalogFixture()
        defer { fixture.cleanUp() }
        LocalCatalogStub.responses.set(status: 200, body: Self.ollamaList)
        await fixture.catalog.fetchModels(apiKey: "", source: .openAICompatible(baseURL: Self.localBaseURL))

        let resolved = await fixture.catalog.resolveModel(for: "gemma4:e2b-mlx", apiKey: "local-secret")
        #expect(resolved?.id == "gemma4:e2b-mlx")
        #expect(resolved?.supportsImageInput == false)
        #expect(await fixture.catalog.resolveModel(for: "not-listed", apiKey: "local-secret") == nil)
        #expect(LocalCatalogStub.responses.requests.count == 1)
    }
}

@MainActor
private struct LocalCatalogFixture {
    let suiteName = "LocalEndpointCatalog.\(UUID().uuidString)"
    let defaults: UserDefaults
    let catalog: ModelCatalogService
    let session: URLSession

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        LocalCatalogStub.responses = LocalCatalogResponses()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalCatalogStub.self]
        session = URLSession(configuration: configuration)
        catalog = ModelCatalogService(session: session, userDefaults: defaults)
    }

    func makeCatalog() -> ModelCatalogService {
        ModelCatalogService(session: session, userDefaults: defaults)
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suiteName) }
}

private final class LocalCatalogResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var body = "{}"
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { recorded } }

    func set(status: Int, body: String) {
        lock.withLock {
            self.status = status
            self.body = body
        }
    }

    func record(_ request: URLRequest) -> (status: Int, body: String) {
        lock.withLock {
            recorded.append(request)
            return (status, body)
        }
    }
}

private final class LocalCatalogStub: URLProtocol, @unchecked Sendable {
    // The suite is serialized, so assignment always precedes the requests it serves.
    nonisolated(unsafe) static var responses = LocalCatalogResponses()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let outcome = Self.responses.record(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: outcome.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(outcome.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
