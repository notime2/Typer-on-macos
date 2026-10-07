// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI
import Testing
@testable import Typer_On

@Test
@MainActor
func testChatLayoutSettlesAfterStreamingCursorIsRemoved() async throws {
    let fixture = try StreamReplayFixture(chunks: ["Synthetic"], intervalMilliseconds: 1)
    let environment = AppEnvironment(streamReplayFixture: fixture)
    let model = ChatViewModel(
        environment: environment,
        aiServiceProvider: { nil }, cachedModelProvider: { _ in nil },
        modelResolver: { _, _ in nil }, configuredModelIDProvider: { "diagnostic/text-only" }
    )
    let suite = "ChatLayoutStabilityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(SelectionTriggerStyle.glassDot.rawValue, forKey: SettingsKey.selectionTriggerStyle.rawValue)
    defer { defaults.removePersistentDomain(forName: suite) }
    let panel = ChatPanel()
    let host = ChatLayoutCountingHost(rootView: DialogThemeRoot { ChatView(viewModel: model) }.defaultAppStorage(defaults))
    panel.contentView = host
    panel.showCentered(on: NSScreen.main)
    defer { panel.hideAndReleaseContent() }

    // This checks real display-link/layout convergence, not an application's timer.
    // Never force layout while sampling: doing so would manufacture the updates.
    try await waitForLayoutQuiet(host)
    let markdown = (0..<35).map {
        "## Synthetic section \($0)\n\nA stable paragraph with **emphasis**, inline `code`, and wrapping text.\n\n- First item\n- Second item\n\n```swift\nlet value = 42\n```\n"
    }.joined(separator: "\n")
    model.messages = [.init(role: .user, text: "Synthetic prompt"), .init(role: .assistant, text: markdown)]
    for lines in [1, 6, 12] {
        model.inputText = Array(repeating: "Synthetic composer line", count: lines).joined(separator: "\n")
        try await waitForLayoutQuiet(host)
    }
    panel.setContentSize(NSSize(width: 420, height: 370))
    try await waitForLayoutQuiet(host)
    panel.setContentSize(ChatPanel.defaultContentSize)
    try await waitForLayoutQuiet(host)
    // Other UI tests may have brought their own windows forward during suspension.
    panel.makeKeyAndOrderFront(nil)
    model.isStreaming = true
    // Long enough for the streaming cursor to render and start animating.
    try await Task.sleep(for: .milliseconds(200))
    model.isStreaming = false
    panel.makeKeyAndOrderFront(nil)
    // Times out (without failing) if the regression keeps layout busy; the sample below catches it.
    try await waitForLayoutQuiet(host)

    let countBefore = host.layoutPasses
    try await Task.sleep(for: .milliseconds(250))
    let quietPasses = host.layoutPasses - countBefore
    // A little slack permits an unrelated AppKit update; the regression continually
    // laid out this host about 60 times per half-second (~30 in this window) on a 120 Hz screen.
    #expect(quietPasses <= 2)
}

@MainActor
private final class ChatLayoutCountingHost<Content: View>: NSHostingView<Content> {
    var layoutPasses = 0
    override func layout() {
        layoutPasses += 1
        super.layout()
    }
}

/// Waits until the host has settled: first up to `firstPassTimeout` for the preceding
/// action to reach layout, then until no pass happens for `quiet`, bounded by `timeout`.
/// Only reads the counter, so it never manufactures layout passes.
@MainActor
private func waitForLayoutQuiet<Content: View>(
    _ host: ChatLayoutCountingHost<Content>,
    firstPassTimeout: Duration = .milliseconds(250),
    quiet: Duration = .milliseconds(100),
    timeout: Duration = .seconds(1)
) async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let initialPasses = host.layoutPasses
    while host.layoutPasses == initialPasses, clock.now - start < firstPassTimeout {
        try await Task.sleep(for: .milliseconds(10))
    }
    var lastPasses = host.layoutPasses
    var lastChange = clock.now
    while clock.now - lastChange < quiet, clock.now - start < timeout {
        try await Task.sleep(for: .milliseconds(10))
        if host.layoutPasses != lastPasses {
            lastPasses = host.layoutPasses
            lastChange = clock.now
        }
    }
}
