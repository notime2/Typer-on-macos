// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Carbon.HIToolbox
import Testing
@testable import Typer_On

@Test
func testModelMenuStateNoOverridesShowsNoModuleEntries() {
    let modules = [
        ModelMenuModuleInfo(id: "translation", name: "Translation", isEnabled: true),
        ModelMenuModuleInfo(id: "grammar", name: "Grammar Fix", isEnabled: false),
    ]
    let configs: [String: ModuleAIConfig] = [
        "translation": ModuleAIConfig(useGlobal: true, customModel: "openai/gpt-4o"),
        "grammar": ModuleAIConfig(useGlobal: false, customModel: "   "),
    ]

    let entries = ModelMenuStateBuilder.moduleOverrideEntries(modules: modules, configs: configs)
    #expect(entries.isEmpty)
}

@Test
func testModelMenuStateDeduplicatesSameModelAcrossModules() {
    let modules = [
        ModelMenuModuleInfo(id: "translation", name: "Translation", isEnabled: true),
        ModelMenuModuleInfo(id: "summary", name: "Summarization", isEnabled: true),
    ]
    let configs: [String: ModuleAIConfig] = [
        "translation": ModuleAIConfig(useGlobal: false, customModel: "openai/gpt-4o"),
        "summary": ModuleAIConfig(useGlobal: false, customModel: "openai/gpt-4o"),
    ]

    let entries = ModelMenuStateBuilder.moduleOverrideEntries(modules: modules, configs: configs)

    #expect(entries.count == 1)
    #expect(entries.first?.modelId == "openai/gpt-4o")
    #expect(entries.first?.moduleLabels == ["Summarization", "Translation"])
}

@Test
func testModelMenuStateMarksDisabledModules() {
    let modules = [
        ModelMenuModuleInfo(id: "translation", name: "Translation", isEnabled: false),
    ]
    let configs: [String: ModuleAIConfig] = [
        "translation": ModuleAIConfig(useGlobal: false, customModel: "openai/gpt-4o-mini"),
    ]

    let entries = ModelMenuStateBuilder.moduleOverrideEntries(modules: modules, configs: configs)
    #expect(entries == [ModelMenuOverrideEntry(modelId: "openai/gpt-4o-mini", moduleLabels: ["Translation (disabled)"])])
}

@Test
@MainActor
func testSelectingModuleModelUpdatesGlobalModelAndBootstrapsEnvironment() {
    let previousModel = UserDefaults.standard.string(for: .selectedModel)
    defer {
        if let previousModel {
            UserDefaults.standard.set(previousModel, for: .selectedModel)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.selectedModel.rawValue)
        }
    }

    let environment = AppEnvironment()
    let coordinator = AppCoordinator(environment: environment)
    let onboardingController = OnboardingWindowController(environment: environment)
    let controller = StatusBarController(
        environment: environment,
        coordinator: coordinator,
        onboardingController: onboardingController
    )

    controller.applyModelSelection("openai/gpt-4o")

    #expect(UserDefaults.standard.string(for: .selectedModel) == "openai/gpt-4o")
    #expect((environment.aiService as? AIEndpointService)?.defaultModel == "openai/gpt-4o")
    #expect(
        controller.modelMenuTitleForTesting()
            == "Model: \(environment.modelCatalog.displayName(for: "openai/gpt-4o"))"
    )
}

@Test
@MainActor
func testStatusBarMenuUsesOpenChatWindowLabel() {
    let environment = AppEnvironment()
    let coordinator = AppCoordinator(environment: environment)
    let onboardingController = OnboardingWindowController(environment: environment)
    let controller = StatusBarController(
        environment: environment,
        coordinator: coordinator,
        onboardingController: onboardingController
    )

    let menu = controller.statusMenuForTesting()
    #expect(menu != nil)
    #expect(menu?.items.contains(where: { $0.title == "Open Chat Window" }) == true)
    #expect(menu?.items.contains(where: { $0.title == "Open Generate Window" }) == false)
}

@Test
@MainActor
func testStatusBarCaptureItemUsesDefaultOptionFWithoutSavedHotkey() {
    let previousHotkey = KeyCombo.load()
    UserDefaults.standard.removeObject(forKey: SettingsKey.globalHotkey.rawValue)
    defer {
        if let previousHotkey {
            previousHotkey.save()
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.globalHotkey.rawValue)
        }
    }

    let environment = AppEnvironment()
    let coordinator = AppCoordinator(environment: environment)
    let onboardingController = OnboardingWindowController(environment: environment)
    let controller = StatusBarController(
        environment: environment,
        coordinator: coordinator,
        onboardingController: onboardingController
    )

    let menu = controller.statusMenuForTesting()
    let captureItem = menu?.items.first(where: { $0.title == "Capture Selected Text" })

    #expect(captureItem != nil)
    #expect(captureItem?.keyEquivalent == "f")
    #expect(captureItem?.keyEquivalentModifierMask == [.option])
}

@Test
@MainActor
func testStatusBarCaptureItemUsesSavedHotkeyOverride() {
    let previousHotkey = KeyCombo.load()
    let savedHotkey = KeyCombo(
        keyCode: UInt16(kVK_ANSI_Z),
        modifiers: UInt(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
    )
    savedHotkey.save()
    defer {
        if let previousHotkey {
            previousHotkey.save()
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.globalHotkey.rawValue)
        }
    }

    let environment = AppEnvironment()
    let coordinator = AppCoordinator(environment: environment)
    let onboardingController = OnboardingWindowController(environment: environment)
    let controller = StatusBarController(
        environment: environment,
        coordinator: coordinator,
        onboardingController: onboardingController
    )

    let menu = controller.statusMenuForTesting()
    let captureItem = menu?.items.first(where: { $0.title == "Capture Selected Text" })

    #expect(captureItem != nil)
    #expect(captureItem?.keyEquivalent == "z")
    #expect(captureItem?.keyEquivalentModifierMask == [.command, .shift])
}

@Test
@MainActor
func testMenuWillOpenRefreshesModelTitleAfterSettingsChange() {
    let previousModel = UserDefaults.standard.string(for: .selectedModel)
    defer {
        if let previousModel {
            UserDefaults.standard.set(previousModel, for: .selectedModel)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.selectedModel.rawValue)
        }
    }

    UserDefaults.standard.set("anthropic/claude-sonnet-4-20250514", for: .selectedModel)

    let environment = AppEnvironment()
    let coordinator = AppCoordinator(environment: environment)
    let onboardingController = OnboardingWindowController(environment: environment)
    let controller = StatusBarController(
        environment: environment,
        coordinator: coordinator,
        onboardingController: onboardingController
    )

    #expect(controller.modelMenuTitleForTesting() == "Model: Claude Sonnet 4")

    UserDefaults.standard.set("openai/gpt-4o-mini", for: .selectedModel)

    let menu = controller.statusMenuForTesting()
    #expect(menu != nil)
    if let menu {
        controller.menuWillOpen(menu)
    }

    #expect(controller.modelMenuTitleForTesting() == "Model: GPT-4o Mini")
}
