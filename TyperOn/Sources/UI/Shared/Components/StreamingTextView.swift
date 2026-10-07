// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI

struct StreamingTextView: View {
    @Environment(\.dialogTheme) private var theme
    let text: String
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Text(text)
                .font(.body)
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isStreaming {
                StreamingCursor()
            }
        }
    }
}

struct StreamingCursor: View {
    @Environment(\.dialogTheme) private var theme

    var body: some View {
        StreamingCursorLayer(color: NSColor(theme.accent))
            .frame(width: 2, height: 16)
    }
}

/// Opacity belongs to the render layer, not to a repeating SwiftUI transaction.
@MainActor
struct StreamingCursorLayer: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> CursorView {
        let view = CursorView()
        view.color = color
        return view
    }

    func updateNSView(_ view: CursorView, context: Context) {
        view.color = color
    }

    static func dismantleNSView(_ view: CursorView, coordinator: ()) {
        view.stopBlinking()
    }

    final class CursorView: NSView {
        static let animationKey = "streamingCursorOpacity"
        var color: NSColor = .clear {
            didSet { updateColor() }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else {
                stopBlinking()
                return
            }
            guard layer?.animation(forKey: Self.animationKey) == nil else { return }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 0
            animation.duration = 0.5
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(animation, forKey: Self.animationKey)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColor()
        }

        func stopBlinking() {
            layer?.removeAnimation(forKey: Self.animationKey)
        }

        private func updateColor() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer?.backgroundColor = color.cgColor
                CATransaction.commit()
            }
        }
    }
}
