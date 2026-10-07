// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@Suite(.serialized)
@MainActor
struct AppEnvironmentProviderTests {
    @Test
    func rapidProviderChangesNeverSendThePreviousProvidersCredential() async throws {
        let fixture = try ProviderEnvironmentFixture()
        defer { fixture.cleanUp() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderCredentialSpy.self]
        ProviderCredentialSpy.reset()
        let environment = AppEnvironment(userDefaults: fixture.defaults,
            catalogSession: URLSession(configuration: configuration), chatHistoryStore: ChatHistoryStore(fileURL: nil),
            keychainAccessOverrides: KeychainAccessOverrides(read: { account in
                account == "openrouter-api-key" ? "synthetic-router-key" : "synthetic-local-key"
            }, write: { _, _ in }, delete: { _ in }))
        fixture.defaults.setAIProvider(.openAICompatible)
        fixture.defaults.setLocalEndpointBaseURL("http://localhost:1234/v1")
        environment.bootstrap()
        fixture.defaults.setAIProvider(.openRouter)
        environment.bootstrap()
        await environment.waitForCatalogBootstrapForTesting()
        let requests = ProviderCredentialSpy.requests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy {
            $0.url?.host == "openrouter.ai" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-router-key"
        })
    }

    @Test
    func defaultInstallKeepsTheOpenRouterTransport() throws {
        let fixture = try ProviderEnvironmentFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set("vendor/saved-model", for: .selectedModel)

        let environment = fixture.makeEnvironment()
        environment.bootstrap()

        #expect(environment.providerSettings.provider == .openRouter)
        #expect((environment.aiService as? AIEndpointService)?.endpoint == .openRouter)
        #expect((environment.aiService as? AIEndpointService)?.defaultModel == "vendor/saved-model")
        #expect(environment.modelCatalog.source == .openRouter)
        #expect(environment.resolveAIConfig(for: TranslationModule()).model == "vendor/saved-model")
    }

    @Test
    func localProviderBuildsTheConfiguredEndpointAndItsOwnModel() throws {
        let fixture = try ProviderEnvironmentFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set("vendor/saved-model", for: .selectedModel)
        fixture.defaults.setAIProvider(.openAICompatible)
        fixture.defaults.setLocalEndpointBaseURL("http://localhost:11434/v1")
        fixture.defaults.setGlobalModelID("gemma4:e2b-mlx", for: .openAICompatible)

        let environment = fixture.makeEnvironment()
        environment.bootstrap()

        let service = try #require(environment.aiService as? AIEndpointService)
        #expect(service.endpoint.provider == .openAICompatible)
        #expect(service.endpoint.chatCompletionsURL.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(service.endpoint.imagesURL == nil)
        #expect(service.defaultModel == "gemma4:e2b-mlx")
        #expect(environment.modelCatalog.source == .openAICompatible(baseURL: URL(string: "http://localhost:11434/v1")!))
        #expect(environment.resolveAIConfig(for: TranslationModule()).model == "gemma4:e2b-mlx")
        #expect(fixture.defaults.string(for: .selectedModel) == "vendor/saved-model")
    }

    @Test
    func localProviderWithAnUnusableBaseURLHasNoTransport() throws {
        let fixture = try ProviderEnvironmentFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.setAIProvider(.openAICompatible)
        fixture.defaults.setLocalEndpointBaseURL("http://models.example.com/v1")

        let environment = fixture.makeEnvironment()
        environment.bootstrap()

        #expect(environment.aiService == nil)
        #expect(environment.requestAIService == nil)
        #expect(environment.modelCatalog.source == .unconfigured)
    }

    @Test
    func moduleOverridesStillApplyUnderTheLocalProvider() throws {
        let fixture = try ProviderEnvironmentFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.setAIProvider(.openAICompatible)
        fixture.defaults.setLocalEndpointBaseURL("http://localhost:1234/v1")
        fixture.defaults.setGlobalModelID("global-local-model", for: .openAICompatible)
        let configs = ["translation": ModuleAIConfig(useGlobal: false, customModel: "module-local-model")]
        fixture.defaults.set(try JSONEncoder().encode(configs), for: .moduleAIConfigs)

        let environment = fixture.makeEnvironment()
        environment.bootstrap()

        #expect(environment.resolveAIModelID(for: TranslationModule()) == "module-local-model")
        #expect(environment.resolveAIConfig(for: TranslationModule()).model == "module-local-model")
        #expect(environment.resolveAIConfig(for: SummarizationModule()).model == "global-local-model")
    }

    /// Settings -> API keeps its provider choice in a draft catalog, so the status bar Model row,
    /// Chat capability gating and the module pickers keep following the saved provider until Save.
    @Test
    func unsavedProviderDraftLeavesTheSharedCatalogOnTheActiveProvider() async throws {
        let fixture = try ProviderEnvironmentFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set("vendor/model", for: .selectedModel)
        fixture.defaults.set(
            Data(#"{"data":[{"id":"vendor/model","name":"Vendor Model"}]}"#.utf8),
            for: .cachedModelList
        )
        fixture.defaults.set(
            Data(#"{"endpoint":"http://localhost:11434/v1","modelIDs":["gemma4:e2b-mlx"]}"#.utf8),
            for: .cachedLocalModelList
        )

        let environment = fixture.makeEnvironment()
        environment.bootstrap()
        await environment.modelCatalog.loadCached()
        #expect(environment.modelCatalog.displayName(for: "vendor/model") == "Vendor Model")

        // The unsaved draft picks the other provider and lists it, exactly as APISettingsView does.
        let draft = environment.makeDraftModelCatalog()
        #expect(draft !== environment.modelCatalog)
        draft.setSource(.openAICompatible(baseURL: URL(string: "http://localhost:11434/v1")!))
        await draft.loadCached()
        #expect(draft.source == .openAICompatible(baseURL: URL(string: "http://localhost:11434/v1")!))
        #expect(draft.models.map(\.id) == ["gemma4:e2b-mlx"])

        #expect(environment.providerSettings.provider == .openRouter)
        #expect((environment.aiService as? AIEndpointService)?.endpoint == .openRouter)
        #expect(environment.modelCatalog.source == .openRouter)
        #expect(environment.modelCatalog.models.map(\.id) == ["vendor/model"])
        // The status bar Model row reads this: the catalog name, never the raw model ID.
        #expect(environment.modelCatalog.displayName(for: "vendor/model") == "Vendor Model")
        #expect(fixture.defaults.string(for: .aiProvider) == nil)
    }

    @Test
    func replayIgnoresTheLocalProviderAndWritesNothing() async throws {
        let fixture = try ProviderEnvironmentFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.setAIProvider(.openAICompatible)
        fixture.defaults.setLocalEndpointBaseURL("http://localhost:11434/v1")
        fixture.defaults.setGlobalModelID("gemma4:e2b-mlx", for: .openAICompatible)
        fixture.defaults.set(
            Data(#"{"endpoint":"http://localhost:11434/v1","modelIDs":["gemma4:e2b-mlx"]}"#.utf8),
            for: .cachedLocalModelList
        )
        let saved = try #require(fixture.defaults.persistentDomain(forName: fixture.suiteName)) as NSDictionary

        // A dedicated protocol class, so a previous test's in-flight catalog task cannot be counted here.
        ReplayProviderNetworkSpy.reset()
        let replayConfiguration = URLSessionConfiguration.ephemeral
        replayConfiguration.protocolClasses = [ReplayProviderNetworkSpy.self]
        let replayFixture = try StreamReplayFixture(chunks: ["synthetic replay"], intervalMilliseconds: 10)
        let environment = AppEnvironment(
            streamReplayFixture: replayFixture,
            userDefaults: fixture.defaults,
            catalogSession: URLSession(configuration: replayConfiguration)
        )
        environment.bootstrap()
        environment.bootstrap()

        #expect(environment.aiService == nil)
        #expect(environment.requestAIService is StreamReplayService)
        #expect(environment.resolveAIConfig(for: TranslationModule()).apiKey.isEmpty)
        #expect(environment.resolveAIConfig(for: TranslationModule()).model == "gemma4:e2b-mlx")

        await environment.modelCatalog.loadCached()
        await environment.modelCatalog.fetchModels(apiKey: "synthetic-test-credential")

        #expect(environment.modelCatalog.models.map(\.id) == ["gemma4:e2b-mlx"])
        #expect(ReplayProviderNetworkSpy.requestCount == 0)
        let current: [String: Any] = try #require(fixture.defaults.persistentDomain(forName: fixture.suiteName))
        #expect(saved.isEqual(to: current))
    }
}

@MainActor
private struct ProviderEnvironmentFixture {
    let suiteName = "AppEnvironmentProvider.\(UUID().uuidString)"
    let defaults: UserDefaults
    let session: URLSession

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderNetworkSpy.self]
        session = URLSession(configuration: configuration)
    }

    func makeEnvironment() -> AppEnvironment {
        AppEnvironment(userDefaults: defaults, catalogSession: session)
    }

    /// The session outlives the fixture on purpose: bootstrap's catalog task may still be in flight.
    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class ReplayProviderNetworkSpy: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int { lock.withLock { count } }

    static func reset() {
        lock.withLock { count = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { count += 1 }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

/// Keeps bootstrap's catalog task off the real network without asserting on counts.
private final class ProviderNetworkSpy: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

private final class ProviderCredentialSpy: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.recorded.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
