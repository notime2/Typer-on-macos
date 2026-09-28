// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Foundation
import Testing
@testable import Typer_On

@Test
@MainActor
func testBackgroundProcessingReleasesUIWithoutEndingSessionAndCanPresentFailure() throws {
    let replay = try StreamReplayFixture(chunks: ["Synthetic result"], intervalMilliseconds: 10)
    let environment = AppEnvironment(streamReplayFixture: replay)
    environment.bootstrap()
    let manager = PanelLifecycleManager(environment: environment)
    manager.setup()
    defer { manager.teardown() }
    let selection = TextSelection(text: "Synthetic input", cursorPosition: .zero)
    manager.showProcessing(module: TranslationModule(), selection: selection)
    let model = manager.processingVM
    let panel = try #require(manager.processingPanel)
    #expect(panel.contentView != nil)

    manager.showProcessing(module: TranslationModule(), selection: selection, mode: .automaticReplacement)
    #expect(panel.contentView == nil)
    #expect(!panel.isVisible)
    #expect(!manager.isProcessingVisible)
    #expect(manager.isProcessingActive)
    #expect(manager.processingVM === model)
    #expect(model?.isStreaming == true)

    model?.onAutomaticProcessingEvent?(.requiresPresentation)
    #expect(manager.processingPanel === panel)
    #expect(panel.contentView != nil)
    #expect(manager.isProcessingVisible)
    #expect(manager.isProcessingActive)

    model?.onAutomaticProcessingEvent?(.succeeded)
    #expect(!manager.isProcessingVisible)
    #expect(manager.isProcessingActive)
    manager.completeAutomaticProcessing()
    #expect(!manager.isProcessingActive)
}

@Test
@MainActor
func testChatReopenRebuildsUIAndPreservesDraftUnlessResetRequested() throws {
    let environment = AppEnvironment(streamReplayFixture: try StreamReplayFixture(chunks: ["Synthetic"], intervalMilliseconds: 10))
    let manager = PanelLifecycleManager(environment: environment)
    manager.setup()
    defer { manager.teardown() }
    manager.showChat(.continueCurrentOrMostRecent)
    let panel = try #require(manager.chatPanel)
    let previousHost = try #require(panel.contentView)
    manager.chatVM?.messages = [ChatConversationMessage(role: .user, text: "Synthetic history")]
    manager.chatVM?.inputText = "Synthetic draft"
    manager.chatVM?.dismiss()
    manager.showChat(.continueCurrentOrMostRecent)
    #expect(panel.contentView !== previousHost)
    #expect(manager.chatVM?.inputText == "Synthetic draft")
    #expect(manager.chatVM?.messages.count == 1)
    manager.chatVM?.dismiss()
    manager.showChat(.newDraft(pendingSelectionText: nil))
    #expect(manager.chatVM?.inputText.isEmpty == true)
    #expect(manager.chatVM?.messages.isEmpty == true)
}

@Test
@MainActor
func testPanelLifecycleSetupIsIdempotentUntilTeardown() {
    let environment = AppEnvironment()
    let manager = PanelLifecycleManager(environment: environment)

    manager.setup()
    let firstProcessingVM = manager.processingVM
    let firstChatVM = manager.chatVM

    #expect(firstProcessingVM != nil)
    #expect(firstChatVM != nil)

    manager.setup()

    #expect(manager.processingVM === firstProcessingVM)
    #expect(manager.chatVM === firstChatVM)
}

@Test
@MainActor
func testPanelLifecycleTeardownClearsViewModelsAndVisibilityState() {
    let environment = AppEnvironment()
    let manager = PanelLifecycleManager(environment: environment)

    manager.setup()
    #expect(manager.processingVM != nil)
    #expect(manager.chatVM != nil)

    manager.teardown()

    #expect(manager.processingVM == nil)
    #expect(manager.chatVM == nil)
    #expect(manager.isProcessingVisible == false)
    #expect(manager.isChatVisible == false)
}

@Test
@MainActor
func testPanelLifecycleSetupCreatesFreshViewModelsAfterTeardown() {
    let environment = AppEnvironment()
    let manager = PanelLifecycleManager(environment: environment)

    manager.setup()
    let firstProcessingVM = manager.processingVM
    let firstChatVM = manager.chatVM

    manager.teardown()
    manager.setup()

    #expect(manager.processingVM != nil)
    #expect(manager.chatVM != nil)
    #expect(manager.processingVM !== firstProcessingVM)
    #expect(manager.chatVM !== firstChatVM)
}

@Test
@MainActor
func testAutomaticProcessingKeepsBackgroundActivityUntilCancelled() {
    let environment = AppEnvironment()
    environment.bootstrap()
    let manager = PanelLifecycleManager(environment: environment)

    manager.setup()
    manager.showProcessing(
        module: TranslationModule(),
        selection: TextSelection(text: "Hello", cursorPosition: .zero),
        mode: .automaticReplacement
    )

    #expect(manager.isProcessingActive)
    #expect(manager.isProcessingVisible == false)

    manager.cancelProcessing()

    #expect(manager.isProcessingActive == false)
}

@Test
@MainActor
func testShowChatSeedsPendingSelectionAndRequestsInputFocus() {
    let environment = AppEnvironment()
    let manager = PanelLifecycleManager(environment: environment)

    manager.setup()

    let initialFocusRequestID = manager.chatVM?.inputFocusRequestID
    manager.showChat(.newDraft(pendingSelectionText: "Selected context"))

    #expect(manager.chatVM?.pendingSelectionText == "Selected context")
    #expect(manager.chatVM?.messages.isEmpty == true)
    #expect(manager.chatVM?.inputFocusRequestID != initialFocusRequestID)
}

@Test
@MainActor
func testShowChatPreservesConversationWhenRequestDoesNotResetAndHasNoPendingSelection() {
    let environment = AppEnvironment()
    let manager = PanelLifecycleManager(environment: environment)

    manager.setup()
    manager.chatVM?.messages = [
        ChatConversationMessage(role: .user, text: "Hello"),
        ChatConversationMessage(role: .assistant, text: "Hi")
    ]
    manager.chatVM?.conversationContextText = "Existing context"

    manager.showChat(.continueCurrentOrMostRecent)

    #expect(manager.chatVM?.messages.map(\.text) == ["Hello", "Hi"])
    #expect(manager.chatVM?.conversationContextText == "Existing context")
    #expect(manager.chatVM?.pendingSelectionText == nil)
}

@Test
@MainActor
func testProcessingHistoryActionClosesProcessingAndOpensTheConversationInChat() throws {
    let environment = AppEnvironment()
    let stored = StoredChatConversation(
        moduleName: "Translate",
        messages: [
            ChatConversationMessage(role: .user, text: "Original"),
            ChatConversationMessage(role: .assistant, text: "Translated")
        ]
    )
    environment.chatHistoryStore.upsert(stored)
    let manager = PanelLifecycleManager(environment: environment)
    manager.setup()
    defer { manager.teardown() }
    manager.showProcessing(
        module: TranslationModule(),
        selection: TextSelection(text: "Hello", cursorPosition: .zero)
    )
    #expect(manager.isProcessingVisible)

    let processingVM = try #require(manager.processingVM)
    processingVM.openChat(.existing(stored.id))

    #expect(!manager.isProcessingVisible)
    #expect(manager.isChatVisible)
    #expect(manager.chatVM?.currentConversationID == stored.id)
    #expect(manager.chatVM?.messages.map(\.text) == ["Original", "Translated"])
}

@Suite("Auto-Detect Selection Defaults", .serialized)
struct AutoDetectSelectionDefaultsTests {
    @Test
    func testAutoDetectSelectionDefaultsToEnabled() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.autoDetectSelection.rawValue)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKey.autoDetectSelection.rawValue) }

        #expect(UserDefaults.standard.autoDetectSelectionEnabled == true)
    }

    @Test
    func testAutoDetectSelectionReadsStoredValue() {
        UserDefaults.standard.setAutoDetectSelectionEnabled(false)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKey.autoDetectSelection.rawValue) }

        #expect(UserDefaults.standard.autoDetectSelectionEnabled == false)
    }

    @Test
    @MainActor
    func testExplicitCaptureCancelsPendingAutoDetectLowConfidenceWork() async {
        let previousValue = UserDefaults.standard.autoDetectSelectionEnabled
        UserDefaults.standard.setAutoDetectSelectionEnabled(true)
        defer { UserDefaults.standard.setAutoDetectSelectionEnabled(previousValue) }

        var snapshot: AXTextSelectionSnapshot? = makeAutoDetectSnapshot(
            rawText: "Hello",
            bundleIdentifier: "ru.keepcoder.Telegram",
            focusedElementRole: "AXTextArea"
        )
        let observer = TextSelectionObserver(
            accessibilityManager: AccessibilityManager(),
            clipboardManager: ClipboardManager(),
            selectionSnapshotReader: { _ in snapshot },
            frontmostPIDReader: { 123 }
        )
        let environment = AppEnvironment()
        environment.installTextSelectionObserverForTesting(observer)
        let panelVisibility = TestPanelVisibilityProvider()
        let scheduler = ManualSelectionScheduler()
        let coordinator = AutoDetectCoordinator(
            environment: environment,
            panelVisibility: panelVisibility,
            scheduler: scheduler
        )
        var detectedCount = 0

        coordinator.onSelectionDetected = { _ in
            detectedCount += 1
        }
        coordinator.bindAutoDetectionCallbacks(to: observer)

        let pendingResult = SelectionCaptureEngine().resolveCaptureResult(
            from: makeAutoDetectSnapshot(
                rawText: "Hello",
                bundleIdentifier: "ru.keepcoder.Telegram",
                focusedElementRole: "AXTextArea"
            ),
            mode: .polling
        )
        #expect(pendingResult != nil)

        observer.onSelectionChanged?(pendingResult!)
        _ = await observer.captureSelection(preferredSourceAppPID: 123)
        coordinator.cancelPendingSelectionWork()

        scheduler.advance(by: 0.4)

        #expect(detectedCount == 0)
        #expect(observer.currentSelection?.text == "Hello")

        snapshot = makeAutoDetectSnapshot(
            rawText: nil,
            selectedTextRangeEvidence: .empty,
            bundleIdentifier: "ru.keepcoder.Telegram",
            focusedElementRole: "AXTextArea"
        )
        observer.pollForTesting()
        await observer.waitForPendingSelectionReadForTesting()

        #expect(observer.currentSelection?.text == "Hello")
    }
}

@MainActor
private final class TestPanelVisibilityProvider: PanelVisibilityProvider {
    var isProcessingVisible = false
    var isProcessingActive = false
    var isChatVisible = false
}

@MainActor
private func makeAutoDetectSnapshot(
    rawText: String?,
    selectedTextRangeEvidence: AXSelectionEvidence = .unsupported,
    bundleIdentifier: String?,
    focusedElementRole: String?
) -> AXTextSelectionSnapshot {
    AXTextSelectionSnapshot(
        rawSelectedTextEvidence: makeAutoDetectRawEvidence(text: rawText),
        selectedTextRangesEvidence: .unsupported,
        selectedTextRangeEvidence: selectedTextRangeEvidence,
        selectedTextMarkerRangeEvidence: .unsupported,
        cursorPosition: .zero,
        selectionBounds: nil,
        sourceAppPID: 123,
        appBundleIdentifier: bundleIdentifier,
        focusedElementRole: focusedElementRole,
        focusedElementSubrole: nil,
        isValueAttributeWritable: true,
        boundsMode: .topLeftNeedsConversion,
        focusedElementID: 11
    )
}

private func makeAutoDetectRawEvidence(text: String?) -> AXSelectionEvidence {
    guard let text, !text.isEmpty else {
        return .empty
    }
    return .nonEmpty(text: text, range: nil)
}
