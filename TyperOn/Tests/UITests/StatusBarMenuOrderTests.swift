// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Testing
@testable import Typer_On

@MainActor
private func makeStatusBarController(environment: AppEnvironment) -> StatusBarController {
    StatusBarController(
        environment: environment,
        coordinator: AppCoordinator(environment: environment),
        onboardingController: OnboardingWindowController(environment: environment)
    )
}

@Test
@MainActor
func testStatusBarMenuOpensWithSettingsDirectlyUnderTheHeader() throws {
    let controller = makeStatusBarController(environment: AppEnvironment())
    let menu = try #require(controller.statusMenuForTesting())

    let header = try #require(menu.items.first)
    #expect(header.title == "Typer On")
    #expect(header.isEnabled == false)
    #expect(menu.items[1].isSeparatorItem)

    let settingsItem = menu.items[2]
    #expect(settingsItem.title == "Settings...")
    #expect(settingsItem.keyEquivalent == ",")
    #expect(settingsItem.keyEquivalentModifierMask == [.command])
    #expect(settingsItem.action.map(NSStringFromSelector) == "showSettings")
    #expect(settingsItem.target as? StatusBarController === controller)

    #expect(menu.items[3].isSeparatorItem)
    #expect(menu.items[4].title == "Capture Selected Text")
}

@Test
@MainActor
func testStatusBarMenuKeepsOneSettingsEntryAndTrailingItemOrder() throws {
    let controller = makeStatusBarController(environment: AppEnvironment())
    let menu = try #require(controller.statusMenuForTesting())

    let settingsIndexes = menu.items.indices.filter { menu.items[$0].title == "Settings..." }
    #expect(settingsIndexes == [2])

    let titles = menu.items.map(\.title)
    let onboardingIndex = try #require(titles.firstIndex(of: "Reopen Onboarding"))
    let quitIndex = try #require(titles.firstIndex(of: "Quit"))
    #expect(onboardingIndex < quitIndex)
    #expect(quitIndex == menu.items.count - 1)
    #expect(menu.items[quitIndex - 1].isSeparatorItem)
    #expect(menu.items[onboardingIndex - 1].isSeparatorItem)

    let accessibilityIndex = try #require(
        titles.firstIndex(where: { $0.hasPrefix("Accessibility") || $0.hasPrefix("Grant Accessibility") })
    )
    #expect(accessibilityIndex < onboardingIndex)
}

@Test
@MainActor
func testStatusBarMenuRebuildKeepsSettingsAtTheTop() throws {
    let controller = makeStatusBarController(environment: AppEnvironment())
    let menu = try #require(controller.statusMenuForTesting())

    controller.menuWillOpen(menu)

    #expect(menu.items[0].title == "Typer On")
    #expect(menu.items[2].title == "Settings...")
    #expect(menu.items.filter { $0.title == "Settings..." }.count == 1)
}

@Test
@MainActor
func testStatusBarShowsLocalEndpointHostInsteadOfAMissingKeyState() throws {
    let suiteName = "StatusBarProvider.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.setAIProvider(.openAICompatible)
    defaults.setLocalEndpointBaseURL("http://localhost:11434/v1")

    let environment = AppEnvironment(userDefaults: defaults, catalogSession: offlineCatalogSession())
    var keyReads = 0
    let controller = StatusBarController(
        environment: environment,
        coordinator: AppCoordinator(environment: environment),
        onboardingController: OnboardingWindowController(environment: environment),
        globalAPIKeyProvider: {
            keyReads += 1
            return nil
        }
    )

    let menu = try #require(controller.statusMenuForTesting())
    let titles = menu.items.map(\.title)
    #expect(titles.contains("Local Endpoint: localhost:11434"))
    #expect(!titles.contains("Set API Key..."))
    #expect(!titles.contains("API Key: Configured"))
    #expect(keyReads == 0)
}

@Test
@MainActor
func testStatusBarReportsAnUnconfiguredLocalEndpoint() throws {
    let suiteName = "StatusBarProvider.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.setAIProvider(.openAICompatible)
    defaults.setLocalEndpointBaseURL("http://models.example.com/v1")

    let environment = AppEnvironment(userDefaults: defaults, catalogSession: offlineCatalogSession())
    let controller = StatusBarController(
        environment: environment,
        coordinator: AppCoordinator(environment: environment),
        onboardingController: OnboardingWindowController(environment: environment),
        globalAPIKeyProvider: { nil }
    )

    let menu = try #require(controller.statusMenuForTesting())
    #expect(menu.items.map(\.title).contains("Local Endpoint: Not Configured"))
}

@MainActor
private func offlineCatalogSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OfflineCatalogProtocol.self]
    return URLSession(configuration: configuration)
}

private final class OfflineCatalogProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

@Test
@MainActor
func testChatHistorySubmenuFollowsOpenChatWindowAndShowsEmptyState() throws {
    let controller = makeStatusBarController(environment: AppEnvironment())
    let menu = try #require(controller.statusMenuForTesting())

    let titles = menu.items.map(\.title)
    let openChatIndex = try #require(titles.firstIndex(of: "Open Chat Window"))
    let historyItem = menu.items[openChatIndex + 1]
    #expect(historyItem.title == "Chat History")

    let submenu = try #require(historyItem.submenu)
    #expect(submenu.items.map(\.title) == ["New Chat", "", "No saved chats", "", "Open History..."])
    #expect(submenu.items[2].isEnabled == false)
}

@Test
@MainActor
func testChatHistorySubmenuListsTenMostRecentChatsAndOpensThem() throws {
    let environment = AppEnvironment()
    for index in 1...12 {
        environment.chatHistoryStore.upsert(StoredChatConversation(
            updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            messages: [ChatConversationMessage(role: .user, text: "Chat \(index)")]
        ))
    }
    let coordinator = AppCoordinator(environment: environment)
    coordinator.panelManagerForTesting.setup()
    defer { coordinator.panelManagerForTesting.teardown() }
    let controller = StatusBarController(
        environment: environment,
        coordinator: coordinator,
        onboardingController: OnboardingWindowController(environment: environment)
    )
    let menu = try #require(controller.statusMenuForTesting())
    controller.menuWillOpen(menu)

    let submenu = try #require(menu.items.first { $0.title == "Chat History" }?.submenu)
    let chatItems = submenu.items.filter { $0.title.hasPrefix("Chat ") }
    #expect(chatItems.map(\.title) == (3...12).reversed().map { "Chat \($0)" })

    let target = try #require(chatItems.first)
    let action = try #require(target.action)
    NSApp.sendAction(action, to: target.target, from: target)
    #expect(coordinator.panelManagerForTesting.chatVM?.messages.map(\.text) == ["Chat 12"])
}
