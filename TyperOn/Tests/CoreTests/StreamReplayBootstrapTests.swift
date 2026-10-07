// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@Suite(.serialized)
@MainActor
struct StreamReplayBootstrapTests {
    @Test
    func replayKeychainGateCannotReadOrChangeSeededKeys() {
        let memory = ReplayKeychainMemory()
        let ordinary = KeychainService(accessOverrides: memory.overrides)
        let ordinaryCanRead = ordinary.getGlobalAPIKey() != nil
        #expect(ordinaryCanRead)
        let before = memory.snapshot()
        let callsBefore = memory.operationCount
        let replay = KeychainService(allowsSystemAccess: false, accessOverrides: memory.overrides)

        let global = replay.getGlobalAPIKey()
        let module = replay.getModuleAPIKey(moduleId: "translation")
        replay.setGlobalAPIKey("synthetic replacement")
        replay.setModuleAPIKey("synthetic replacement", moduleId: "translation")
        replay.deleteGlobalAPIKey()
        replay.deleteModuleAPIKey(moduleId: "translation")

        #expect(global == nil)
        #expect(module == nil)
        let preserved = before == memory.snapshot()
        let callbacksNotInvoked = callsBefore == memory.operationCount
        #expect(preserved)
        #expect(callbacksNotInvoked)

        ordinary.setGlobalAPIKey("synthetic updated value")
        ordinary.deleteModuleAPIKey(moduleId: "translation")
        let normalWriteApplied = ordinary.getGlobalAPIKey() == "synthetic updated value"
        let normalDeleteApplied = ordinary.getModuleAPIKey(moduleId: "translation") == nil
        #expect(normalWriteApplied)
        #expect(normalDeleteApplied)
    }

    @Test
    func replayStatusMenuNeverCallsKeyProvider() throws {
        let fixture = try StreamReplayFixture(chunks: ["synthetic"], intervalMilliseconds: 10)
        let environment = AppEnvironment(streamReplayFixture: fixture)
        var readCount = 0
        let controller = StatusBarController(
            environment: environment,
            coordinator: AppCoordinator(environment: environment),
            onboardingController: OnboardingWindowController(environment: environment),
            globalAPIKeyProvider: {
                readCount += 1
                return "synthetic test key"
            }
        )
        let menu = try #require(controller.statusMenuForTesting())
        controller.menuWillOpen(menu)
        let replayItem = menu.items.first { $0.title == "Local Replay: No API Key Needed" }
        #expect(readCount == 0)
        #expect(replayItem != nil)
        #expect(replayItem?.isEnabled == false)
        #expect(replayItem?.action == nil)
    }

    @Test
    func replayBootstrapAndCatalogRemainOfflineWithoutChangingSavedDefaults() async throws {
        let suite = "StreamReplayBootstrapTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("vendor/saved-model", for: .selectedModel)
        defaults.set(["translation", "missing-module"], for: .enabledModuleIDs)
        defaults.set(["translation", "translation", "missing-module"], for: .moduleOrder)
        defaults.set(0.3, for: .temperature)
        defaults.set(12345, for: .maxTokens)
        defaults.set(Data(#"{"data":[{"id":"vendor/saved-model","name":"Cached model"}]}"#.utf8), for: .cachedModelList)
        let saved = defaults.persistentDomain(forName: suite)! as NSDictionary

        ReplayNetworkSpy.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplayNetworkSpy.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fixture = try StreamReplayFixture(chunks: ["synthetic replay"], intervalMilliseconds: 10)
        for _ in 0..<2 {
            let environment = AppEnvironment(
                streamReplayFixture: fixture,
                userDefaults: defaults,
                catalogSession: session
            )
            environment.bootstrap()
            environment.bootstrap()
            environment.reloadModules()
            #expect(environment.aiService == nil)
            #expect(environment.requestAIService is StreamReplayService)
            let resolvedConfig: ResolvedAIConfig = environment.resolveAIConfig(for: TranslationModule())
            #expect(resolvedConfig.model == "vendor/saved-model")
            #expect(resolvedConfig.apiKey.isEmpty)
            await environment.modelCatalog.loadCached()
            await environment.modelCatalog.fetchModels(apiKey: "synthetic-test-credential")
            let metadata = await environment.modelCatalog.resolveModel(
                for: "vendor/saved-model", apiKey: "synthetic-test-credential"
            )
            #expect(metadata?.name == "Cached model")
            #expect(ReplayNetworkSpy.requestCount == 0)
            let currentDefaults: [String: Any] = try #require(defaults.persistentDomain(forName: suite))
            let defaultsUnchanged: Bool = saved.isEqual(to: currentDefaults)
            #expect(defaultsUnchanged)
        }
        let finalDefaults: [String: Any] = try #require(defaults.persistentDomain(forName: suite))
        let finalDefaultsUnchanged: Bool = saved.isEqual(to: finalDefaults)
        #expect(finalDefaultsUnchanged)
    }

    @Test
    func normalEnvironmentRemainsLiveAfterReplayEnvironmentIsReleased() throws {
        let suite = "StreamReplayBootstrapTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("vendor/saved-model", for: .selectedModel)
        do {
            let fixture = try StreamReplayFixture(chunks: ["synthetic"], intervalMilliseconds: 10)
            let replay = AppEnvironment(streamReplayFixture: fixture, userDefaults: defaults)
            replay.bootstrap()
            #expect(replay.isStreamReplay)
        }
        let normal = AppEnvironment(userDefaults: defaults)
        normal.bootstrap()
        #expect(!normal.isStreamReplay)
        #expect((normal.aiService as? AIEndpointService)?.defaultModel == "vendor/saved-model")
        #expect(normal.requestAIService is AIEndpointService)
    }

    @Test
    func normalViewModelsConsumeReplayThroughLifecycleManager() async throws {
        let suite = "StreamReplayBootstrapTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("vendor/image-output", for: .selectedModel)
        defaults.set(
            Data(#"{"data":[{"id":"vendor/image-output","name":"Image output","architecture":{"input_modalities":["text","image"],"output_modalities":["text","image"]}}]}"#.utf8),
            for: .cachedModelList
        )
        let fixture = try StreamReplayFixture(chunks: ["# Synthetic replay\n\nComplete."], intervalMilliseconds: 10)
        let environment = AppEnvironment(streamReplayFixture: fixture, userDefaults: defaults)
        environment.bootstrap()
        await environment.modelCatalog.loadCached()
        let cachedModel: OpenRouterModel? = environment.modelCatalog.model(for: "vendor/image-output")
        #expect(cachedModel?.supportsImageOutput == true)
        let manager = PanelLifecycleManager(environment: environment)
        manager.setup()
        defer { manager.teardown() }
        let chat = try #require(manager.chatVM)
        chat.inputText = "synthetic prompt"
        chat.sendMessage()
        await chat.waitForPendingWorkForTesting()
        let expectedText: String = fixture.chunks.joined()
        #expect(chat.messages.last?.text == expectedText)
        #expect(!chat.isStreaming)
        #expect(chat.error == nil)
        chat.reset()
        chat.inputText = "repeat synthetic prompt"
        chat.sendMessage()
        await chat.waitForPendingWorkForTesting()
        #expect(chat.messages.last?.text == expectedText)

        let processing = try #require(manager.processingVM)
        processing.process(module: TranslationModule(), selection: TextSelection(text: "synthetic", cursorPosition: .zero))
        await processing.waitForPendingWorkForTesting()
        #expect(processing.error == nil)
        #expect(!processing.isStreaming)
        #expect(processing.resultText == expectedText)
    }
}

private final class ReplayKeychainMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [
        "openrouter-api-key": "synthetic seeded global key",
        "module.translation.apikey": "synthetic seeded module key"
    ]
    private var count = 0

    var operationCount: Int { lock.withLock { count } }

    func snapshot() -> [String: String] { lock.withLock { values } }

    var overrides: KeychainAccessOverrides {
        KeychainAccessOverrides(
            read: { [self] account in
                lock.withLock { count += 1; return values[account] }
            },
            write: { [self] account, value in
                lock.withLock { count += 1; values[account] = value }
            },
            delete: { [self] account in
                lock.withLock { count += 1; _ = values.removeValue(forKey: account) }
            }
        )
    }
}

private final class ReplayNetworkSpy: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int { lock.withLock { count } }

    static func reset() { lock.withLock { count = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
