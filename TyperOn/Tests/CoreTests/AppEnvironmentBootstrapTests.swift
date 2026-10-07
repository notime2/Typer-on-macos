// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

private let explainMigrationKey = "didMigrateExplainModule"
private let factCheckMigrationKey = "didMigrateFactCheckModule"

@Test
@MainActor
func testModuleIndexRebuildDropsRemovedCustomModulesAndUpdatesExistingNames() {
    withCleanModuleRegistryState { registry in
        let custom = (0..<200).map {
            CustomPromptModule(id: "custom-index-\($0)", name: "Module \($0)", icon: "star", shortDescription: nil, systemPrompt: "Test")
        }
        registry.bootstrap(customModules: custom)
        #expect(custom.allSatisfy { registry.module(byId: $0.id)?.name == $0.name })
        let originalCount = registry.modules.count
        registry.register(custom[0])
        #expect(registry.modules.count == originalCount)
        let updated = CustomPromptModule(id: custom[0].id, name: "Renamed", icon: "star", shortDescription: nil, systemPrompt: "Test")
        registry.bootstrap(customModules: [updated])
        #expect(registry.module(byId: custom[0].id)?.name == "Renamed")
        #expect(registry.module(byId: custom[1].id) == nil)
        #expect(registry.modules.count == 9)
    }
}

@Test
func testAppRuntimeDetectsXCTestConfigurationEnvironment() {
    #expect(AppRuntime.isRunningTests(environment: ["XCTestConfigurationFilePath": "/tmp/config.xctestconfiguration"]))
}

@Test
func testAppRuntimeDetectsXCTestSessionEnvironment() {
    #expect(AppRuntime.isRunningTests(environment: ["XCTestSessionIdentifier": "session-id"]))
}

@Test
func testAppRuntimeIgnoresRegularEnvironment() {
    #expect(!AppRuntime.isRunningTests(environment: ["PATH": "/usr/bin"]))
}

@Test
@MainActor
func testBootstrapKeepsTextSelectionObserverIdentity() {
    let environment = AppEnvironment()
    environment.bootstrap()

    let firstObserver = environment.textSelectionObserver
    #expect(firstObserver != nil)

    environment.bootstrap()
    #expect(environment.textSelectionObserver === firstObserver)
}

@Test
@MainActor
func testBootstrapKeepsSelectionEventMonitorIdentity() {
    let environment = AppEnvironment()
    environment.bootstrap()

    let firstMonitor = environment.selectionEventMonitor
    #expect(firstMonitor != nil)

    environment.bootstrap()
    #expect(environment.selectionEventMonitor === firstMonitor)
}

@Test
@MainActor
func testBootstrapKeepsSelectionNotificationMonitorIdentity() {
    let environment = AppEnvironment()
    environment.bootstrap()

    let firstMonitor = environment.selectionNotificationMonitor
    #expect(firstMonitor != nil)

    environment.bootstrap()
    #expect(environment.selectionNotificationMonitor === firstMonitor)
}

@Test
@MainActor
func testBootstrapKeepsHotkeyManagerIdentity() {
    let environment = AppEnvironment()
    environment.bootstrap()

    let firstManager = environment.hotkeyManager
    #expect(firstManager != nil)

    environment.bootstrap()
    #expect(environment.hotkeyManager === firstManager)
}

@Test
@MainActor
func testBootstrapKeepsTextReplacerIdentity() {
    let environment = AppEnvironment()
    environment.bootstrap()

    let firstReplacer = environment.textReplacer
    #expect(firstReplacer != nil)

    environment.bootstrap()
    #expect(environment.textReplacer === firstReplacer)
}

@Test
@MainActor
func testBootstrapUsesGeminiDefaultModelWhenSelectedModelIsMissing() {
    UserDefaults.standard.removeObject(forKey: SettingsKey.selectedModel.rawValue)
    defer { UserDefaults.standard.removeObject(forKey: SettingsKey.selectedModel.rawValue) }

    let environment = AppEnvironment()
    environment.bootstrap()

    #expect((environment.aiService as? AIEndpointService)?.defaultModel == AIModelDefaults.defaultModelID)
    #expect(UserDefaults.standard.string(for: .selectedModel) == nil)
}

@Test
@MainActor
func testBootstrapKeepsExistingSelectedModelValue() {
    let existingModel = "anthropic/claude-sonnet-4-20250514"
    UserDefaults.standard.set(existingModel, for: .selectedModel)
    defer { UserDefaults.standard.removeObject(forKey: SettingsKey.selectedModel.rawValue) }

    let environment = AppEnvironment()
    environment.bootstrap()

    #expect((environment.aiService as? AIEndpointService)?.defaultModel == existingModel)
    #expect(UserDefaults.standard.string(for: .selectedModel) == existingModel)
}

@Test
@MainActor
func testModuleRegistryDefaultOrderMatchesRegistrationOrder() {
    withCleanModuleRegistryState { registry in
        let expectedOrder = registry.modules.map(\.id)
        #expect(registry.activeModules.map(\.id) == expectedOrder)
    }
}

@Test
@MainActor
func testContentGenerationModuleUsesChatModeDisplayName() {
    let environment = AppEnvironment()
    environment.bootstrap()

    let module = environment.moduleRegistry.module(byId: "content-generation")
    #expect(module?.name == "Chat Mode")
}

@Test
@MainActor
func testBuiltInModulesExposeShortDescriptionsThroughRegistry() {
    let environment = AppEnvironment()
    environment.bootstrap()

    let moduleDescriptions = [
        ("translation", "Translate to target language"),
        ("rephrasing", "Rewrite without changing meaning"),
        ("summarization", "Condense to key points"),
        ("explain", "Explain in simple terms"),
        ("fact-check", "Check claims for accuracy"),
        ("grammar-fix", "Fix grammar and spelling"),
        ("content-generation", "Chat on any topic or with context"),
        ("tone-adjustment", "Change tone, keep meaning"),
    ]

    for (moduleID, expected) in moduleDescriptions {
        #expect(environment.moduleRegistry.module(byId: moduleID)?.shortDescription == expected)
    }
}

@Test
@MainActor
func testModuleRegistrySetOrderReordersActiveModules() {
    withCleanModuleRegistryState { registry in
        let ids = registry.modules.map(\.id)
        let reordered = Array(ids.prefix(3).reversed()) + Array(ids.dropFirst(3))

        registry.setOrder(reordered)

        #expect(registry.activeModules.map(\.id) == reordered)
    }
}

@Test
@MainActor
func testModuleRegistryDisableRemovesFromOrderAndEnableAppendsToEnd() {
    withCleanModuleRegistryState { registry in
        let ids = registry.modules.map(\.id)
        #expect(ids.count >= 3)

        let targetID = ids[1]
        registry.setEnabled(false, for: targetID)

        let storedAfterDisable: [String] = UserDefaults.standard.value(for: .moduleOrder) ?? []
        #expect(!storedAfterDisable.contains(targetID))
        #expect(!registry.activeModules.map(\.id).contains(targetID))

        registry.setEnabled(true, for: targetID)

        let activeAfterEnable = registry.activeModules.map(\.id)
        #expect(activeAfterEnable.last == targetID)
    }
}

@Test
@MainActor
func testModuleRegistryIgnoresInvalidAndDuplicateOrderIDs() {
    withCleanModuleRegistryState { registry in
        let ids = registry.modules.map(\.id)
        #expect(ids.count >= 4)

        registry.setEnabled(false, for: ids[0])
        registry.setOrder(["legacy-module", ids[2], ids[2], ids[0]])

        let storedOrder: [String] = UserDefaults.standard.value(for: .moduleOrder) ?? []
        let enabledIDs = Set(registry.activeModules.map(\.id))

        #expect(!storedOrder.contains("legacy-module"))
        #expect(!storedOrder.contains(ids[0]))
        #expect(storedOrder.filter { $0 == ids[2] }.count == 1)
        #expect(Set(storedOrder) == enabledIDs)
        #expect(registry.activeModules.map(\.id) == storedOrder)
    }
}

@Test
@MainActor
func testModuleRegistryLegacyEnabledAutoEnablesExplain() {
    withModuleRegistryState(
        enabledIDs: ["translation", "grammar-fix", "summarization"],
        moduleOrder: nil,
        explainMigrated: false,
        factCheckMigrated: true
    ) { registry in
        let storedEnabled: [String] = UserDefaults.standard.value(for: .enabledModuleIDs) ?? []
        #expect(storedEnabled.contains("explain"))
        #expect(registry.activeModules.map(\.id).contains("explain"))
    }
}

@Test
@MainActor
func testModuleRegistryLegacyOrderInsertsExplainAfterSummarization() {
    withModuleRegistryState(
        enabledIDs: [
            "translation",
            "grammar-fix",
            "rephrasing",
            "tone-adjustment",
            "summarization",
            "content-generation",
        ],
        moduleOrder: [
            "translation",
            "grammar-fix",
            "rephrasing",
            "tone-adjustment",
            "summarization",
            "content-generation",
        ],
        explainMigrated: false,
        factCheckMigrated: true
    ) { registry in
        let storedOrder: [String] = UserDefaults.standard.value(for: .moduleOrder) ?? []
        let summaryIndex = storedOrder.firstIndex(of: "summarization")
        let explainIndex = storedOrder.firstIndex(of: "explain")

        #expect(summaryIndex != nil)
        #expect(explainIndex != nil)
        #expect(explainIndex == summaryIndex.map { $0 + 1 })
        #expect(registry.activeModules.map(\.id) == storedOrder)
    }
}

@Test
@MainActor
func testModuleRegistryKeepsExistingExplainPositionWhenAlreadyPresent() {
    let legacyOrder = [
        "translation",
        "explain",
        "grammar-fix",
        "rephrasing",
        "tone-adjustment",
        "summarization",
        "content-generation",
    ]

    withModuleRegistryState(
        enabledIDs: legacyOrder,
        moduleOrder: legacyOrder,
        explainMigrated: false,
        factCheckMigrated: true
    ) { registry in
        let storedOrder: [String] = UserDefaults.standard.value(for: .moduleOrder) ?? []
        #expect(storedOrder == legacyOrder)
        #expect(registry.activeModules.map(\.id) == legacyOrder)
    }
}

@Test
@MainActor
func testModuleRegistryDoesNotReenableExplainAfterUserDisablesIt() {
    withModuleRegistryState(
        enabledIDs: ["translation", "grammar-fix", "summarization", "explain"],
        moduleOrder: ["translation", "grammar-fix", "summarization", "explain"],
        explainMigrated: true,
        factCheckMigrated: true
    ) { registry in
        registry.setEnabled(false, for: "explain")
        registry.bootstrap()

        let storedEnabled: [String] = UserDefaults.standard.value(for: .enabledModuleIDs) ?? []
        #expect(!storedEnabled.contains("explain"))
        #expect(!registry.activeModules.map(\.id).contains("explain"))
    }
}

@Test
@MainActor
func testModuleRegistryLegacyEnabledAutoEnablesFactCheck() {
    withModuleRegistryState(
        enabledIDs: ["translation", "grammar-fix", "summarization", "explain"],
        moduleOrder: nil,
        explainMigrated: true,
        factCheckMigrated: false
    ) { registry in
        let storedEnabled: [String] = UserDefaults.standard.value(for: .enabledModuleIDs) ?? []
        #expect(storedEnabled.contains("fact-check"))
        #expect(registry.activeModules.map(\.id).contains("fact-check"))
        #expect(UserDefaults.standard.bool(forKey: factCheckMigrationKey))
    }
}

@Test
@MainActor
func testModuleRegistryLegacyOrderInsertsFactCheckAfterExplain() {
    let legacyOrder = [
        "translation",
        "grammar-fix",
        "rephrasing",
        "tone-adjustment",
        "summarization",
        "explain",
        "content-generation",
    ]

    withModuleRegistryState(
        enabledIDs: legacyOrder,
        moduleOrder: legacyOrder,
        explainMigrated: true,
        factCheckMigrated: false
    ) { registry in
        let storedOrder: [String] = UserDefaults.standard.value(for: .moduleOrder) ?? []
        let explainIndex = storedOrder.firstIndex(of: "explain")
        #expect(explainIndex != nil)
        #expect(storedOrder.firstIndex(of: "fact-check") == explainIndex.map { $0 + 1 })
        #expect(registry.activeModules.map(\.id) == storedOrder)
    }
}

@Test
@MainActor
func testModuleRegistryLegacyOrderInsertsFactCheckAfterSummarizationWithoutExplain() {
    withModuleRegistryState(
        enabledIDs: ["translation", "summarization", "content-generation"],
        moduleOrder: ["translation", "summarization", "content-generation"],
        explainMigrated: true,
        factCheckMigrated: false
    ) { _ in
        let storedOrder: [String] = UserDefaults.standard.value(for: .moduleOrder) ?? []
        #expect(storedOrder == ["translation", "summarization", "fact-check", "content-generation"])
    }
}

@Test
@MainActor
func testModuleRegistryDoesNotReenableFactCheckAfterUserDisablesIt() {
    withModuleRegistryState(
        enabledIDs: ["translation", "summarization", "explain"],
        moduleOrder: ["translation", "summarization", "explain"],
        explainMigrated: true,
        factCheckMigrated: false
    ) { registry in
        #expect(registry.activeModules.map(\.id).contains("fact-check"))

        registry.setEnabled(false, for: "fact-check")
        registry.bootstrap()

        let storedEnabled: [String] = UserDefaults.standard.value(for: .enabledModuleIDs) ?? []
        #expect(!storedEnabled.contains("fact-check"))
        #expect(!registry.activeModules.map(\.id).contains("fact-check"))
    }
}

@Test
@MainActor
func testResolveAIConfigUsesUnifiedDefaultMaxTokens() {
    let defaults = UserDefaults.standard
    let previousMaxTokens = defaults.object(forKey: SettingsKey.maxTokens.rawValue)
    defer { restoreDefaultsValue(previousMaxTokens, for: .maxTokens) }
    defaults.removeObject(forKey: SettingsKey.maxTokens.rawValue)

    let environment = AppEnvironment()
    environment.bootstrap()

    let module = TranslationModule()
    let moduleConfig = environment.resolveAIConfig(for: module)

    #expect(moduleConfig.maxTokens == AIModelDefaults.defaultMaxTokens)
}

@Test
@MainActor
func testBootstrapRegistersCustomPromptModulesFromStore() throws {
    let defaults = UserDefaults.standard
    let previousCustomPrompts = defaults.object(forKey: SettingsKey.customPrompts.rawValue)
    let previousEnabled = defaults.object(forKey: SettingsKey.enabledModuleIDs.rawValue)
    let previousOrder = defaults.object(forKey: SettingsKey.moduleOrder.rawValue)

    defer {
        restoreDefaultsValue(previousCustomPrompts, for: .customPrompts)
        restoreDefaultsValue(previousEnabled, for: .enabledModuleIDs)
        restoreDefaultsValue(previousOrder, for: .moduleOrder)
    }

    defaults.removeObject(forKey: SettingsKey.enabledModuleIDs.rawValue)
    defaults.removeObject(forKey: SettingsKey.moduleOrder.rawValue)

    let prompt = CustomPromptDefinition(
        name: "Custom Summary",
        icon: "star",
        shortDescription: "Summarize with extra rules",
        systemPrompt: "Summarize with constraints."
    )
    let encoded = try JSONEncoder().encode([prompt])
    defaults.set(encoded, for: .customPrompts)

    let environment = AppEnvironment()
    environment.bootstrap()

    #expect(environment.moduleRegistry.module(byId: prompt.id) != nil)
    #expect(environment.moduleRegistry.activeModules.map(\.id).contains(prompt.id))
    #expect(environment.moduleRegistry.module(byId: prompt.id)?.shortDescription == "Summarize with extra rules")
}

@Test
func testCustomPromptDefinitionDecodesLegacyPayloadWithoutShortDescription() throws {
    let data = Data(#"{"id":"custom-legacy","name":"Legacy Prompt","icon":"star","systemPrompt":"Legacy system prompt"}"#.utf8)
    let decoded = try JSONDecoder().decode(CustomPromptDefinition.self, from: data)

    #expect(decoded.shortDescription == nil)
}

@Test
@MainActor
func testCustomPromptStoreNormalizesDescriptionAndTransfersItToModules() {
    let defaults = UserDefaults.standard
    let previousCustomPrompts = defaults.object(forKey: SettingsKey.customPrompts.rawValue)

    defer { restoreDefaultsValue(previousCustomPrompts, for: .customPrompts) }

    defaults.removeObject(forKey: SettingsKey.customPrompts.rawValue)

    let store = CustomPromptStore()
    let prompt = CustomPromptDefinition(
        name: "Custom Summary",
        icon: "star",
        shortDescription: "  Helpful summary helper  ",
        systemPrompt: "Summarize with constraints."
    )

    store.add(prompt)

    #expect(store.prompts.first?.shortDescription == "Helpful summary helper")
    #expect(store.toModules().first?.shortDescription == "Helpful summary helper")
}

@Test
@MainActor
func testCustomPromptStoreTreatsBlankDescriptionAsMissing() {
    let defaults = UserDefaults.standard
    let previousCustomPrompts = defaults.object(forKey: SettingsKey.customPrompts.rawValue)

    defer { restoreDefaultsValue(previousCustomPrompts, for: .customPrompts) }

    defaults.removeObject(forKey: SettingsKey.customPrompts.rawValue)

    let store = CustomPromptStore()
    let prompt = CustomPromptDefinition(
        name: "Custom Summary",
        icon: "star",
        shortDescription: "   ",
        systemPrompt: "Summarize with constraints."
    )

    store.add(prompt)

    #expect(store.prompts.first?.shortDescription == nil)
    #expect(store.toModules().first?.shortDescription == nil)
}

@Test
@MainActor
func testReloadModulesReflectsUpdatedCustomPromptDescription() {
    let defaults = UserDefaults.standard
    let previousCustomPrompts = defaults.object(forKey: SettingsKey.customPrompts.rawValue)
    let previousEnabled = defaults.object(forKey: SettingsKey.enabledModuleIDs.rawValue)
    let previousOrder = defaults.object(forKey: SettingsKey.moduleOrder.rawValue)

    defer {
        restoreDefaultsValue(previousCustomPrompts, for: .customPrompts)
        restoreDefaultsValue(previousEnabled, for: .enabledModuleIDs)
        restoreDefaultsValue(previousOrder, for: .moduleOrder)
    }

    defaults.removeObject(forKey: SettingsKey.customPrompts.rawValue)
    defaults.removeObject(forKey: SettingsKey.enabledModuleIDs.rawValue)
    defaults.removeObject(forKey: SettingsKey.moduleOrder.rawValue)

    let environment = AppEnvironment()
    environment.bootstrap()

    let initialPrompt = CustomPromptDefinition(
        name: "Custom Summary",
        icon: "star",
        shortDescription: nil,
        systemPrompt: "Summarize with constraints."
    )

    environment.customPromptStore.add(initialPrompt)
    environment.reloadModules()
    #expect(environment.moduleRegistry.module(byId: initialPrompt.id)?.shortDescription == nil)

    var updatedPrompt = environment.customPromptStore.prompts[0]
    updatedPrompt.shortDescription = "Updated custom summary"
    environment.customPromptStore.update(updatedPrompt)
    environment.reloadModules()

    #expect(environment.moduleRegistry.module(byId: initialPrompt.id)?.shortDescription == "Updated custom summary")
}

@Test
@MainActor
func testBootstrapAndDeletionPruneUnknownCustomModuleIDsFromEnabledState() throws {
    let defaults = UserDefaults.standard
    let previousCustomPrompts = defaults.object(forKey: SettingsKey.customPrompts.rawValue)
    let previousEnabled = defaults.object(forKey: SettingsKey.enabledModuleIDs.rawValue)
    let previousOrder = defaults.object(forKey: SettingsKey.moduleOrder.rawValue)
    let previousMigrationState = defaults.object(forKey: explainMigrationKey)
    let previousFactCheckMigrationState = defaults.object(forKey: factCheckMigrationKey)

    defer {
        restoreDefaultsValue(previousCustomPrompts, for: .customPrompts)
        restoreDefaultsValue(previousEnabled, for: .enabledModuleIDs)
        restoreDefaultsValue(previousOrder, for: .moduleOrder)
        restoreRawDefaultsValue(previousMigrationState, forKey: explainMigrationKey)
        restoreRawDefaultsValue(previousFactCheckMigrationState, forKey: factCheckMigrationKey)
    }

    let kept = CustomPromptDefinition(name: "Kept", systemPrompt: "Keep.")
    let deleted = CustomPromptDefinition(name: "Deleted", systemPrompt: "Delete.")
    defaults.set(try JSONEncoder().encode([kept, deleted]), for: .customPrompts)
    let stale = ["custom-0f50c534", "custom-ebe7e347"]
    defaults.set(["translation", kept.id, deleted.id] + stale, for: .enabledModuleIDs)
    defaults.set(["translation", kept.id, "translation", deleted.id] + stale, for: .moduleOrder)
    defaults.set(true, forKey: explainMigrationKey)
    defaults.set(true, forKey: factCheckMigrationKey)

    let environment = AppEnvironment()
    environment.bootstrap()

    let healedEnabled: [String] = defaults.value(for: .enabledModuleIDs) ?? []
    #expect(Set(healedEnabled) == ["translation", kept.id, deleted.id])
    let healedOrder: [String]? = defaults.value(for: .moduleOrder)
    #expect(healedOrder == ["translation", kept.id, deleted.id])

    environment.customPromptStore.delete(id: deleted.id)
    environment.reloadModules()

    let enabledAfterDelete: [String] = defaults.value(for: .enabledModuleIDs) ?? []
    #expect(Set(enabledAfterDelete) == ["translation", kept.id])
    let orderAfterDelete: [String]? = defaults.value(for: .moduleOrder)
    #expect(orderAfterDelete == ["translation", kept.id])
}

@MainActor
private func withCleanModuleRegistryState(_ body: (ModuleRegistry) -> Void) {
    let defaults = UserDefaults.standard
    let previousEnabled = defaults.object(forKey: SettingsKey.enabledModuleIDs.rawValue)
    let previousOrder = defaults.object(forKey: SettingsKey.moduleOrder.rawValue)
    let previousMigrationState = defaults.object(forKey: explainMigrationKey)
    let previousFactCheckMigrationState = defaults.object(forKey: factCheckMigrationKey)

    defer {
        restoreDefaultsValue(previousEnabled, for: .enabledModuleIDs)
        restoreDefaultsValue(previousOrder, for: .moduleOrder)
        restoreRawDefaultsValue(previousMigrationState, forKey: explainMigrationKey)
        restoreRawDefaultsValue(previousFactCheckMigrationState, forKey: factCheckMigrationKey)
    }

    defaults.removeObject(forKey: SettingsKey.enabledModuleIDs.rawValue)
    defaults.removeObject(forKey: SettingsKey.moduleOrder.rawValue)
    defaults.removeObject(forKey: explainMigrationKey)
    defaults.removeObject(forKey: factCheckMigrationKey)

    let registry = ModuleRegistry()
    registry.bootstrap()
    body(registry)
}

@MainActor
private func withModuleRegistryState(
    enabledIDs: [String]?,
    moduleOrder: [String]?,
    explainMigrated: Bool? = nil,
    factCheckMigrated: Bool? = nil,
    _ body: (ModuleRegistry) -> Void
) {
    let defaults = UserDefaults.standard
    let previousEnabled = defaults.object(forKey: SettingsKey.enabledModuleIDs.rawValue)
    let previousOrder = defaults.object(forKey: SettingsKey.moduleOrder.rawValue)
    let previousMigrationState = defaults.object(forKey: explainMigrationKey)
    let previousFactCheckMigrationState = defaults.object(forKey: factCheckMigrationKey)

    defer {
        restoreDefaultsValue(previousEnabled, for: .enabledModuleIDs)
        restoreDefaultsValue(previousOrder, for: .moduleOrder)
        restoreRawDefaultsValue(previousMigrationState, forKey: explainMigrationKey)
        restoreRawDefaultsValue(previousFactCheckMigrationState, forKey: factCheckMigrationKey)
    }

    if let enabledIDs {
        defaults.set(enabledIDs, for: .enabledModuleIDs)
    } else {
        defaults.removeObject(forKey: SettingsKey.enabledModuleIDs.rawValue)
    }

    if let moduleOrder {
        defaults.set(moduleOrder, for: .moduleOrder)
    } else {
        defaults.removeObject(forKey: SettingsKey.moduleOrder.rawValue)
    }

    if let explainMigrated {
        defaults.set(explainMigrated, forKey: explainMigrationKey)
    } else {
        defaults.removeObject(forKey: explainMigrationKey)
    }

    if let factCheckMigrated {
        defaults.set(factCheckMigrated, forKey: factCheckMigrationKey)
    } else {
        defaults.removeObject(forKey: factCheckMigrationKey)
    }

    let registry = ModuleRegistry()
    registry.bootstrap()
    body(registry)
}

@MainActor
private func restoreDefaultsValue(_ value: Any?, for key: SettingsKey) {
    let defaults = UserDefaults.standard
    if let value {
        defaults.set(value, forKey: key.rawValue)
    } else {
        defaults.removeObject(forKey: key.rawValue)
    }
}

@MainActor
private func restoreRawDefaultsValue(_ value: Any?, forKey key: String) {
    let defaults = UserDefaults.standard
    if let value {
        defaults.set(value, forKey: key)
    } else {
        defaults.removeObject(forKey: key)
    }
}
