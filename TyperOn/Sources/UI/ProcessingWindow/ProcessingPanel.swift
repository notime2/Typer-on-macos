// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI

@MainActor
final class ProcessingPanel: NSWindow {
    private let contentLifecycle: DialogPanelContentLifecycle

    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func close() {
        onEscape?()
    }

    init(animateDismissal: DialogPanelContentLifecycle.DismissAnimation? = nil) {
        contentLifecycle = animateDismissal.map { DialogPanelContentLifecycle(animateDismissal: $0) }
            ?? DialogPanelContentLifecycle()
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 360, height: 300)
        animationBehavior = .documentWindow

        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.closeButton)?.isHidden = false
    }

    func showCentered(on screen: NSScreen?) {
        contentLifecycle.willPresent()
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = targetScreen.visibleFrame

        let origin = NSPoint(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.midY - frame.height / 2
        )

        setFrameOrigin(origin)
        alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    func dismiss() {
        contentLifecycle.dismiss(self)
    }

    func hideAndReleaseContent() {
        contentLifecycle.hideAndReleaseContent(self)
    }
}
