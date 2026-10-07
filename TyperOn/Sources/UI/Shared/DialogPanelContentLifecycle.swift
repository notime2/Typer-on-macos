// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit

/// Terminal dismissal only. Screenshot capture uses orderOut and retains its UI.
@MainActor
final class DialogPanelContentLifecycle {
    typealias DismissAnimation = @MainActor (NSWindow, @escaping @MainActor () -> Void) -> Void

    private var generation = 0
    private let animateDismissal: DismissAnimation

    init(animateDismissal: @escaping DismissAnimation = DialogPanelContentLifecycle.animateDismissal) {
        self.animateDismissal = animateDismissal
    }

    func willPresent() {
        generation += 1
    }

    func dismiss(_ window: NSWindow) {
        generation += 1
        let dismissalGeneration = generation
        let contentID = window.contentView.map(ObjectIdentifier.init)
        animateDismissal(window) { [weak self, weak window] in
            guard let self, let window,
                  self.generation == dismissalGeneration,
                  window.contentView.map(ObjectIdentifier.init) == contentID,
                  window.alphaValue == 0 else { return }
            self.hideAndReleaseContent(window)
        }
    }

    /// Also invalidates a fade-out when entering background processing or tearing down.
    func hideAndReleaseContent(_ window: NSWindow) {
        generation += 1
        window.orderOut(nil)
        window.makeFirstResponder(nil)
        window.contentView = nil
    }

    private static func animateDismissal(_ window: NSWindow, completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            DispatchQueue.main.async { completion() }
        })
    }
}
