// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Foundation
import Testing
@testable import Typer_On

@Test
@MainActor
func testOpenChatWithSelectionResetsConversationAndSeedsPendingContext() async {
    let selection = TextSelection(text: "New context", cursorPosition: .zero)
    let coordinator = AppCoordinator(
        environment: AppEnvironment(),
        chatSelectionCaptureOverride: { _ in selection }
    )

    coordinator.panelManagerForTesting.setup()
    coordinator.panelManagerForTesting.chatVM?.messages = [
        ChatConversationMessage(role: .user, text: "Old"),
        ChatConversationMessage(role: .assistant, text: "Conversation")
    ]
    coordinator.panelManagerForTesting.chatVM?.conversationContextText = "Old context"

    await coordinator.openChat()

    #expect(coordinator.panelManagerForTesting.chatVM?.messages.isEmpty == true)
    #expect(coordinator.panelManagerForTesting.chatVM?.conversationContextText == nil)
    #expect(coordinator.panelManagerForTesting.chatVM?.pendingSelectionText == "New context")
}

@Test
@MainActor
func testOpenChatWithoutSelectionPreservesConversation() async {
    let coordinator = AppCoordinator(
        environment: AppEnvironment(),
        chatSelectionCaptureOverride: { _ in nil }
    )

    coordinator.panelManagerForTesting.setup()
    coordinator.panelManagerForTesting.chatVM?.messages = [
        ChatConversationMessage(role: .user, text: "Old"),
        ChatConversationMessage(role: .assistant, text: "Conversation")
    ]
    coordinator.panelManagerForTesting.chatVM?.conversationContextText = "Existing context"

    await coordinator.openChat()

    #expect(coordinator.panelManagerForTesting.chatVM?.messages.map(\.text) == ["Old", "Conversation"])
    #expect(coordinator.panelManagerForTesting.chatVM?.conversationContextText == "Existing context")
    #expect(coordinator.panelManagerForTesting.chatVM?.pendingSelectionText == nil)
}

@Test
@MainActor
func testOpenChatWithoutSelectionRestoresMostRecentChatWhenWindowIsEmpty() async {
    let environment = AppEnvironment()
    let recent = StoredChatConversation(
        messages: [
            ChatConversationMessage(role: .user, text: "Recent"),
            ChatConversationMessage(role: .assistant, text: "Saved")
        ],
        conversationContextText: "Stored context"
    )
    environment.chatHistoryStore.upsert(recent)
    let coordinator = AppCoordinator(environment: environment, chatSelectionCaptureOverride: { _ in nil })
    coordinator.panelManagerForTesting.setup()

    await coordinator.openChat()

    #expect(coordinator.panelManagerForTesting.chatVM?.currentConversationID == recent.id)
    #expect(coordinator.panelManagerForTesting.chatVM?.messages.map(\.text) == ["Recent", "Saved"])
    #expect(coordinator.panelManagerForTesting.chatVM?.conversationContextText == "Stored context")
}

@Test
@MainActor
func testOpenChatTargetOpensThatConversationAndNewChatClearsIt() {
    let environment = AppEnvironment()
    let older = StoredChatConversation(
        updatedAt: Date(timeIntervalSince1970: 1_000),
        messages: [ChatConversationMessage(role: .user, text: "Older")]
    )
    environment.chatHistoryStore.upsert(older)
    environment.chatHistoryStore.upsert(StoredChatConversation(
        messages: [ChatConversationMessage(role: .user, text: "Newer")]
    ))
    let coordinator = AppCoordinator(environment: environment)
    coordinator.panelManagerForTesting.setup()
    defer { coordinator.panelManagerForTesting.teardown() }

    coordinator.openChat(.existing(older.id))
    #expect(coordinator.panelManagerForTesting.chatVM?.messages.map(\.text) == ["Older"])

    coordinator.openChat(.newDraft(pendingSelectionText: nil))
    #expect(coordinator.panelManagerForTesting.chatVM?.messages.isEmpty == true)
    #expect(coordinator.panelManagerForTesting.chatVM?.currentConversationID == nil)
    #expect(environment.chatHistoryStore.conversations.count == 2)
}

@Test
@MainActor
func testChatModeModuleRoutesToChatWindow() {
    let coordinator = AppCoordinator(environment: AppEnvironment())
    coordinator.panelManagerForTesting.setup()

    coordinator.presentModuleForTesting(
        ContentGenerationModule(),
        selection: TextSelection(text: "Selected context", cursorPosition: .zero)
    )

    #expect(coordinator.panelManagerForTesting.chatVM?.pendingSelectionText == "Selected context")
    #expect(coordinator.panelManagerForTesting.processingVM?.currentModule == nil)
}

@Test
@MainActor
func testNonChatModuleRoutesToProcessingWindow() {
    let coordinator = AppCoordinator(environment: AppEnvironment())
    coordinator.panelManagerForTesting.setup()

    coordinator.presentModuleForTesting(
        TranslationModule(),
        selection: TextSelection(text: "Hello", cursorPosition: .zero)
    )

    #expect(coordinator.panelManagerForTesting.processingVM?.currentModule?.id == "translation")
    #expect(coordinator.panelManagerForTesting.chatVM?.pendingSelectionText == nil)
}

@Test
func testCaptureLogMetadataOmitsSelectionText() {
    let selection = TextSelection(
        text: "secret token",
        cursorPosition: .zero,
        focusedElementID: 11,
        sourceAppPID: 42,
        appBundleIdentifier: "com.example.Editor",
        captureConfidence: .high,
        winningEvidenceSource: .range
    )

    let metadata = AppCoordinator.captureLogMetadata(for: selection)

    #expect(!metadata.contains("secret token"))
    #expect(metadata.contains("utf16len=12"))
    #expect(metadata.contains("pid=42"))
    #expect(metadata.contains("bundle=com.example.Editor"))
    #expect(metadata.contains("confidence=high"))
    #expect(metadata.contains("source=range"))
}
