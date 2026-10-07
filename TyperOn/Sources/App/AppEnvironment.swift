// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI

enum AppRuntime {
    static var isRunningTests: Bool {
        isRunningTests(environment: ProcessInfo.processInfo.environment)
    }

    static func isRunningTests(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}

@MainActor
@Observable
final class AppEnvironment {
    let keychainService: KeychainService
    let accessibilityManager = AccessibilityManager()
    let clipboardManager = ClipboardManager()
    let moduleRegistry: ModuleRegistry
    let customPromptStore = CustomPromptStore()
    let modelCatalog: ModelCatalogService
    let settingsState = SettingsWindowState()
    let chatHistoryStore: ChatHistoryStore
    @ObservationIgnored
    private var settingsWindowController: SettingsWindowController?
    private let userDefaults: UserDefaults
    private let catalogSession: URLSession
    private let streamReplayService: StreamReplayService?
    @ObservationIgnored private var bootstrapID = UUID()
    @ObservationIgnored private var catalogBootstrapTask: Task<Void, Never>?

    var isStreamReplay: Bool { streamReplayService != nil }

    /// Set by `AppDelegate` for a normal launch only; nil under XCTest and stream replay.
    var appUpdater: AppUpdater?

    var requestAIService: (any AIService)? {
        if let streamReplayService { return streamReplayService }
        return aiService
    }

    private(set) var aiService: (any AIService)?
    private(set) var textSelectionObserver: TextSelectionObserver?
    private(set) var textReplacer: TextReplacer?
    private(set) var selectionEventMonitor: SelectionEventMonitor?
    private(set) var selectionNotificationMonitor: AXNotificationMonitor?
    private(set) var hotkeyManager: HotkeyManager?

    init(
        streamReplayFixture: StreamReplayFixture? = nil,
        userDefaults: UserDefaults = .standard,
        catalogSession: URLSession = .shared,
        chatHistoryStore: ChatHistoryStore? = nil,
        keychainAccessOverrides: KeychainAccessOverrides? = nil
    ) {
        self.userDefaults = userDefaults
        self.catalogSession = catalogSession
        self.keychainService = KeychainService(allowsSystemAccess: streamReplayFixture == nil,
                                               accessOverrides: keychainAccessOverrides)
        self.streamReplayService = streamReplayFixture.map { StreamReplayService(fixture: $0) }
        self.moduleRegistry = ModuleRegistry(userDefaults: userDefaults)
        // Replay runs on synthetic text and never writes the real history.
        self.chatHistoryStore = chatHistoryStore ?? ChatHistoryStore(
            fileURL: streamReplayFixture == nil ? ChatHistoryStore.defaultFileURL() : nil
        )
        self.modelCatalog = ModelCatalogService(
            session: catalogSession,
            userDefaults: userDefaults,
            allowsRemoteRequests: streamReplayFixture == nil
        )
    }

    /// The persisted provider selection resolved into a transport; `endpoint` is nil for an unusable local base URL.
    var providerSettings: AIProviderSettings {
        userDefaults.aiProviderSettings
    }

    func bootstrap() {
        let bootstrapID = UUID()
        self.bootstrapID = bootstrapID
        let providerSettings = self.providerSettings
        let apiKey = globalAPIKey(for: providerSettings.provider)
        let model = userDefaults.globalModelID(for: providerSettings.provider)
        let temperature = userDefaults.double(for: .temperature)
        let maxTokens = userDefaults.integer(for: .maxTokens)

        if !isStreamReplay, providerSettings.provider.isSubscription {
            aiService = SubscriptionAIService(provider: providerSettings.provider,
                                              executablePath: providerSettings.subscriptionExecutablePath)
        } else {
            aiService = (isStreamReplay ? nil : providerSettings.endpoint).map { endpoint in
                AIEndpointService(
                    endpoint: endpoint,
                    apiKey: apiKey,
                    defaultModel: model,
                    defaultTemperature: temperature > 0 ? temperature : AIModelDefaults.defaultTemperature,
                    defaultMaxTokens: maxTokens > 0 ? maxTokens : AIModelDefaults.defaultMaxTokens
                )
            }
        }

        if textReplacer == nil {
            textReplacer = TextReplacer(clipboardManager: clipboardManager)
        }
        if textSelectionObserver == nil {
            textSelectionObserver = TextSelectionObserver(
                accessibilityManager: accessibilityManager,
                clipboardManager: clipboardManager
            )
        }
        if selectionEventMonitor == nil {
            selectionEventMonitor = SelectionEventMonitor()
        }
        if selectionNotificationMonitor == nil {
            selectionNotificationMonitor = AXNotificationMonitor()
        }
        if hotkeyManager == nil {
            hotkeyManager = HotkeyManager()
        }

        moduleRegistry.bootstrap(
            customModules: customPromptStore.toModules(),
            persistNormalization: !isStreamReplay
        )

        let catalogSource = providerSettings.catalogSource
        modelCatalog.setSource(catalogSource)
        let canFetchCatalog = providerSettings.provider.isSubscription
            || (catalogSource.endpoint.map { !$0.requiresAPIKey || !apiKey.isEmpty } ?? false)

        catalogBootstrapTask?.cancel()
        catalogBootstrapTask = Task {
            guard self.bootstrapID == bootstrapID, modelCatalog.source == catalogSource else { return }
            await modelCatalog.loadCached()
            if self.bootstrapID == bootstrapID, modelCatalog.source == catalogSource,
               !isStreamReplay, canFetchCatalog {
                await modelCatalog.fetchModels(apiKey: apiKey, source: catalogSource)
            }
        }

        Log.app.info("AppEnvironment bootstrapped with provider \(providerSettings.provider.rawValue, privacy: .public)")
    }

#if DEBUG
    func waitForCatalogBootstrapForTesting() async {
        await catalogBootstrapTask?.value
    }
#endif

    /// A separate catalog for an unsaved settings draft, so a draft endpoint never re-points the shared one.
    func makeDraftModelCatalog() -> ModelCatalogService {
        ModelCatalogService(
            session: catalogSession,
            userDefaults: userDefaults,
            allowsRemoteRequests: !isStreamReplay
        )
    }

    private func globalAPIKey(for provider: AIProvider) -> String {
        guard !isStreamReplay else { return "" }
        switch provider {
        case .openRouter:
            return keychainService.getGlobalAPIKey() ?? ""
        case .openAICompatible:
            return keychainService.getLocalEndpointAPIKey() ?? ""
        case .codex, .claudeCode:
            return ""
        }
    }

    func reloadModules() {
        moduleRegistry.bootstrap(
            customModules: customPromptStore.toModules(),
            persistNormalization: !isStreamReplay
        )
    }

    func installTextSelectionObserverForTesting(_ observer: TextSelectionObserver?) {
        textSelectionObserver = observer
    }

    func moduleAIConfig(for moduleID: String) -> ModuleAIConfig? {
        guard let data = userDefaults.data(for: .moduleAIConfigs),
              let configs = try? JSONDecoder().decode([String: ModuleAIConfig].self, from: data) else {
            return nil
        }

        return configs[moduleID]
    }

    func resolveAIConfig(for module: any TextModule) -> ResolvedAIConfig {
        let globalKey = globalAPIKey(for: providerSettings.provider)
        let globalModel = userDefaults.activeGlobalModelID
        let globalTemp = userDefaults.double(for: .temperature)
        let globalMaxTokens = userDefaults.integer(for: .maxTokens)

        if let config = moduleAIConfig(for: module.id),
           !config.useGlobal {
            return ResolvedAIConfig(
                apiKey: config.usesModuleAPIKey && !isStreamReplay && !providerSettings.provider.isSubscription
                    ? (keychainService.getModuleAPIKey(moduleId: module.id) ?? globalKey)
                    : globalKey,
                model: config.customModel ?? globalModel,
                temperature: config.customTemperature ?? (globalTemp > 0 ? globalTemp : AIModelDefaults.defaultTemperature),
                maxTokens: config.customMaxTokens ?? (globalMaxTokens > 0 ? globalMaxTokens : AIModelDefaults.defaultMaxTokens)
            )
        }

        return ResolvedAIConfig(
            apiKey: globalKey,
            model: globalModel,
            temperature: globalTemp > 0 ? globalTemp : AIModelDefaults.defaultTemperature,
            maxTokens: globalMaxTokens > 0 ? globalMaxTokens : AIModelDefaults.defaultMaxTokens
        )
    }

    func resolveAIModelID(for module: any TextModule) -> String {
        let globalModel = userDefaults.activeGlobalModelID
        guard let config = moduleAIConfig(for: module.id), !config.useGlobal else {
            return globalModel
        }
        return config.customModel ?? globalModel
    }

    func showSettings(tab: SettingsTab = .general) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                environment: self,
                state: settingsState
            )
        }
        settingsWindowController?.show(tab: tab)
    }
}
