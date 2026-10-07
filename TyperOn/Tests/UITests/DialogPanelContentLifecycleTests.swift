// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI
import Testing
@testable import Typer_On

@Suite("Dialog panel content lifetime", .serialized)
@MainActor
struct DialogPanelContentLifecycleTests {
    @Test(arguments: [false, true])
    func terminalDismissReleasesOnlyAfterCompletion(chat: Bool) {
        let fixture = PanelFixture(chat: chat)
        defer { fixture.release() }
        fixture.installContent()
        weak var host = fixture.window.contentView
        fixture.dismiss()
        #expect(fixture.window.contentView === host)
        fixture.animation.complete(0)
        #expect(fixture.window.contentView == nil)
        #expect(!fixture.window.isVisible)
    }

    @Test(arguments: [false, true])
    func reopenInvalidatesOldCompletionEvenWithSameContent(chat: Bool) {
        let fixture = PanelFixture(chat: chat)
        defer { fixture.release() }
        fixture.installContent()
        fixture.dismiss()
        let host = fixture.window.contentView
        fixture.show()
        fixture.animation.complete(0)
        #expect(fixture.window.isVisible)
        #expect(fixture.window.contentView === host)
    }

    @Test(arguments: [false, true])
    func replacingContentProtectsNewHostBeforePresentation(chat: Bool) {
        let fixture = PanelFixture(chat: chat)
        defer { fixture.release() }
        fixture.installContent()
        fixture.dismiss()
        fixture.installContent()
        let newHost = fixture.window.contentView
        fixture.animation.complete(0)
        #expect(fixture.window.contentView === newHost)
    }

    @Test(arguments: [false, true])
    func repeatedDismissAndImmediateReleaseInvalidatePendingCallbacks(chat: Bool) {
        let fixture = PanelFixture(chat: chat)
        defer { fixture.release() }
        fixture.installContent()
        fixture.dismiss()
        fixture.dismiss()
        fixture.animation.complete(0)
        #expect(fixture.window.contentView != nil)
        fixture.release()
        #expect(fixture.window.contentView == nil)
        fixture.installContent()
        let newHost = fixture.window.contentView
        fixture.animation.complete(1)
        #expect(fixture.window.contentView === newHost)
    }

    @Test(arguments: [false, true])
    func screenshotHidePreservesHost(chat: Bool) {
        let fixture = PanelFixture(chat: chat)
        defer { fixture.release() }
        fixture.installContent()
        fixture.show()
        let host = fixture.window.contentView
        fixture.window.hideForScreenshot()
        #expect(!fixture.window.isVisible)
        #expect(fixture.window.contentView === host)
        fixture.window.orderFrontAfterScreenshot()
        #expect(fixture.window.isVisible)
        #expect(fixture.window.contentView === host)
    }

    @Test(arguments: [false, true])
    func completedCallbacksDoNotClearSubsequentContent(chat: Bool) {
        let fixture = PanelFixture(chat: chat)
        defer { fixture.release() }
        for _ in 0..<100 {
            fixture.installContent()
            fixture.dismiss()
            fixture.animation.complete(fixture.animation.completions.count - 1)
            #expect(fixture.window.contentView == nil)
        }
        fixture.installContent()
        let newHost = fixture.window.contentView
        for index in fixture.animation.completions.indices {
            fixture.animation.complete(index)
        }
        #expect(fixture.window.contentView === newHost)
    }
}

@MainActor
private final class ManualDismissAnimation {
    var completions: [@MainActor () -> Void] = []

    func animate(_ window: NSWindow, completion: @escaping @MainActor () -> Void) {
        window.alphaValue = 0
        completions.append(completion)
    }

    func complete(_ index: Int) { completions[index]() }
}

@MainActor
private final class PanelFixture {
    let animation = ManualDismissAnimation()
    let window: NSWindow
    let show: () -> Void
    let dismiss: () -> Void
    let release: () -> Void

    init(chat: Bool) {
        if chat {
            let panel = ChatPanel(animateDismissal: animation.animate)
            window = panel
            show = { panel.showCentered(on: NSScreen.main) }
            dismiss = { panel.dismiss() }
            release = { panel.hideAndReleaseContent() }
        } else {
            let panel = ProcessingPanel(animateDismissal: animation.animate)
            window = panel
            show = { panel.showCentered(on: NSScreen.main) }
            dismiss = { panel.dismiss() }
            release = { panel.hideAndReleaseContent() }
        }
    }

    func installContent() {
        window.contentView = NSHostingView(rootView: Text("Synthetic dialog"))
    }
}
