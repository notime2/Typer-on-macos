// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI

/// Tracks user scrolling, rather than treating content growth during streaming
/// as the user leaving the bottom, using native AppKit scrolling notifications.
@MainActor
struct ChatScrollPositionObserver: NSViewRepresentable {
    var onUserScroll: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onUserScroll = onUserScroll
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onUserScroll = onUserScroll
        view.observeEnclosingScrollView()
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.stopObserving()
    }

    final class ObserverView: NSView {
        var onUserScroll: ((Bool) -> Void)?
        private weak var observedScrollView: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeEnclosingScrollView()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            observeEnclosingScrollView()
        }

        func observeEnclosingScrollView() {
            guard observedScrollView !== enclosingScrollView else { return }
            stopObserving()
            guard let scrollView = enclosingScrollView else { return }
            observedScrollView = scrollView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(didScroll(_:)),
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView
            )
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            observedScrollView = nil
        }

        @objc private func didScroll(_ notification: Notification) {
            guard let scrollView = observedScrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.documentVisibleRect
            let distance = document.isFlipped
                ? document.bounds.maxY - visible.maxY
                : visible.minY - document.bounds.minY
            onUserScroll?(distance <= 80)
        }
    }
}
