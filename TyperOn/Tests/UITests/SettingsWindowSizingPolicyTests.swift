// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import CoreGraphics
import Foundation
import Testing
@testable import Typer_On

@Test
func testSettingsFirstOpenUsesCompactDefaultAndRecordsMigration() {
    withSettingsDefaults { defaults in
        let preferences = SettingsWindowSizePreferences(defaults: defaults, persistsChanges: true)
        #expect(preferences.preferredContentSize() == CGSize(width: 760, height: 620))
        #expect(defaults.integer(for: .settingsWindowSizingVersion) == 1)
        #expect(defaults.double(for: .settingsWindowWidth) == 760)
        #expect(defaults.double(for: .settingsWindowHeight) == 620)
    }
}

@Test
func testSettingsLegacySizeResetsOnlyOnceThenRestoresManualSize() {
    withSettingsDefaults { defaults in
        defaults.set(1134.0, for: .settingsWindowWidth)
        defaults.set(894.0, for: .settingsWindowHeight)
        defaults.set("synthetic-model", for: .selectedModel)
        let preferences = SettingsWindowSizePreferences(defaults: defaults, persistsChanges: true)
        #expect(preferences.preferredContentSize() == CGSize(width: 760, height: 620))
        preferences.save(CGSize(width: 680, height: 590))
        let reopened = SettingsWindowSizePreferences(defaults: defaults, persistsChanges: true)
        #expect(reopened.preferredContentSize() == CGSize(width: 680, height: 590))
        #expect(defaults.string(for: .selectedModel) == "synthetic-model")
    }
}

@Test(arguments: [false, true])
func testSettingsReplayDoesNotPersistMigrationOrManualResize(alreadyMigrated: Bool) {
    withSettingsDefaults { defaults in
        defaults.set(1134.0, for: .settingsWindowWidth)
        defaults.set(894.0, for: .settingsWindowHeight)
        if alreadyMigrated { defaults.set(1, for: .settingsWindowSizingVersion) }
        let preferences = SettingsWindowSizePreferences(defaults: defaults, persistsChanges: false)
        let expected = alreadyMigrated ? CGSize(width: 1134, height: 894) : CGSize(width: 760, height: 620)
        #expect(preferences.preferredContentSize() == expected)
        preferences.save(CGSize(width: 680, height: 590))
        #expect(defaults.double(for: .settingsWindowWidth) == 1134)
        #expect(defaults.double(for: .settingsWindowHeight) == 894)
        #expect(defaults.integer(for: .settingsWindowSizingVersion) == (alreadyMigrated ? 1 : 0))
    }
}

@Test
func testSettingsReplayWithoutSavedSizeLeavesPreferencesAbsent() {
    withSettingsDefaults { defaults in
        let preferences = SettingsWindowSizePreferences(defaults: defaults, persistsChanges: false)
        #expect(preferences.preferredContentSize() == CGSize(width: 760, height: 620))
        #expect(defaults.object(forKey: SettingsKey.settingsWindowWidth.rawValue) == nil)
        #expect(defaults.object(forKey: SettingsKey.settingsWindowHeight.rawValue) == nil)
        #expect(defaults.object(forKey: SettingsKey.settingsWindowSizingVersion.rawValue) == nil)
    }
}

@Test(arguments: [0.0, -1.0, Double.infinity])
func testSettingsInvalidSavedSizeFallsBackToCompactDefault(width: Double) {
    withSettingsDefaults { defaults in
        defaults.set(1, for: .settingsWindowSizingVersion)
        defaults.set(width, for: .settingsWindowWidth)
        defaults.set(620.0, for: .settingsWindowHeight)
        let preferences = SettingsWindowSizePreferences(defaults: defaults, persistsChanges: true)
        #expect(preferences.preferredContentSize() == CGSize(width: 760, height: 620))
    }
}

@Test(arguments: [CGSize(width: 680, height: 590), CGSize(width: 900, height: 760)])
func testSettingsRestoresManualSizeAboveAndBelowDefault(size: CGSize) {
    let resolved = SettingsWindowSizingPolicy.resolvedContentSize(
        savedContentSize: size,
        availableContentSize: CGSize(width: 1400, height: 1000)
    )
    #expect(resolved == size)
}

@Test
func testSettingsEnforcesMinimumForUndersizedPreference() {
    let resolved = SettingsWindowSizingPolicy.resolvedContentSize(
        savedContentSize: CGSize(width: 300, height: 200),
        availableContentSize: CGSize(width: 1400, height: 1000)
    )
    #expect(resolved == CGSize(width: 580, height: 576))
}

@Test
func testSettingsSmallScreenClampsBothDefaultAndMinimum() {
    let available = CGSize(width: 500, height: 400)
    let resolved = SettingsWindowSizingPolicy.resolvedContentSize(
        savedContentSize: nil,
        availableContentSize: available
    )
    let minimum = SettingsWindowSizingPolicy.clampedContentSize(
        SettingsWindowSizingPolicy.defaultMinimumContentSize,
        minimumContentSize: SettingsWindowSizingPolicy.defaultMinimumContentSize,
        availableContentSize: available
    )
    #expect(resolved == available)
    #expect(minimum == available)
}

@Test
func testSettingsScreenClampDoesNotOverwriteLargerPreference() {
    withSettingsDefaults { defaults in
        let preferences = SettingsWindowSizePreferences(defaults: defaults, persistsChanges: true)
        _ = preferences.preferredContentSize()
        preferences.save(CGSize(width: 1200, height: 900))
        let compactScreenSize = SettingsWindowSizingPolicy.resolvedContentSize(
            savedContentSize: preferences.preferredContentSize(),
            availableContentSize: CGSize(width: 800, height: 700)
        )
        #expect(compactScreenSize == CGSize(width: 800, height: 700))
        #expect(preferences.preferredContentSize() == CGSize(width: 1200, height: 900))
    }
}

private func withSettingsDefaults(_ body: (UserDefaults) -> Void) {
    let suite = "SettingsWindowSizingTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    body(defaults)
}

@MainActor
@Test
func testCustomModuleCreationOpensPromptEditorAndReturnsToModules() {
    let state = SettingsWindowState()
    state.selectedTab = .modules

    state.beginCustomPromptCreation(returnToModules: true)

    #expect(state.selectedTab == .customPrompts)
    #expect(state.isAddingCustomPrompt)

    state.completeCustomPromptCreation()

    #expect(state.selectedTab == .modules)
    #expect(!state.isAddingCustomPrompt)
}

@MainActor
@Test
func testDirectPromptCreationStaysOnCustomPromptsAfterCompletion() {
    let state = SettingsWindowState()

    state.beginCustomPromptCreation(returnToModules: false)
    state.completeCustomPromptCreation()

    #expect(state.selectedTab == .customPrompts)
    #expect(!state.isAddingCustomPrompt)
}

@MainActor
@Test
func testCancelCustomPromptCreationClearsPendingReturnToModules() {
    let state = SettingsWindowState()

    state.beginCustomPromptCreation(returnToModules: true)
    state.cancelCustomPromptCreation()
    state.beginCustomPromptCreation(returnToModules: false)
    state.completeCustomPromptCreation()

    #expect(state.selectedTab == .customPrompts)
    #expect(!state.isAddingCustomPrompt)
}
