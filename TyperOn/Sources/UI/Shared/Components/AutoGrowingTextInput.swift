// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
struct AutoGrowingTextInput: View {
    @Binding var text: String
    @Environment(\.dialogTheme) private var theme

    let placeholder: String
    let focusRequestID: UUID?
    let onSubmit: () -> Void

    @State private var measuredHeight: CGFloat

    private let metrics: AutoGrowingTextInputMetrics

    init(
        text: Binding<String>,
        placeholder: String,
        maxVisibleLines: Int = 6,
        focusRequestID: UUID? = nil,
        onSubmit: @escaping () -> Void
    ) {
        self._text = text
        self.placeholder = placeholder
        self.focusRequestID = focusRequestID
        self.onSubmit = onSubmit

        let metrics = AutoGrowingTextInputMetrics(maxVisibleLines: maxVisibleLines)
        self.metrics = metrics
        self._measuredHeight = State(initialValue: metrics.minHeight)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            AutoGrowingTextViewRepresentable(
                text: $text,
                measuredHeight: $measuredHeight,
                metrics: metrics,
                theme: theme,
                focusRequestID: focusRequestID,
                onSubmit: onSubmit
            )
            .padding(.horizontal, DS.Spacing.sm)
            .frame(height: measuredHeight)

            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, metrics.verticalInset)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: measuredHeight)
        .dialogControlSurface(
            RoundedRectangle(cornerRadius: surfaceRadius, style: theme.cornerStyle),
            fill: theme.surface,
            isInteractive: false
        )
        .animation(DS.Animation.quick, value: measuredHeight)
    }

    /// A single-line glass composer is a capsule; taller drafts settle at a fixed radius.
    private var surfaceRadius: CGFloat {
        theme.usesNativeGlass
            ? min(theme.controlRadius(height: metrics.minHeight), 18)
            : theme.buttonRadius
    }
}

struct AutoGrowingTextInputMetrics {
    let font: NSFont
    let verticalInset: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    init(
        font: NSFont = .systemFont(ofSize: 13),
        verticalInset: CGFloat = 7,
        maxVisibleLines: Int = 6,
        minimumControlHeight: CGFloat = 32
    ) {
        self.font = font
        self.verticalInset = verticalInset

        let lineHeight = Self.lineHeight(for: font)
        self.minHeight = max(minimumControlHeight, ceil(lineHeight + verticalInset * 2))
        self.maxHeight = max(
            self.minHeight,
            ceil(lineHeight * CGFloat(maxVisibleLines) + verticalInset * 2)
        )
    }

    static func resolvedHeight(
        for contentHeight: CGFloat,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) -> CGFloat {
        max(minHeight, min(maxHeight, ceil(contentHeight)))
    }

    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}

enum AutoGrowingTextInputBehavior {
    static func shouldSubmit(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        hasMarkedText: Bool
    ) -> Bool {
        guard !hasMarkedText else { return false }
        guard keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter) else { return false }

        let relevantModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        return !relevantModifiers.contains(.shift) && !relevantModifiers.contains(.option)
    }
}

@MainActor
struct AutoGrowingTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat

    let metrics: AutoGrowingTextInputMetrics
    let theme: DialogTheme
    let focusRequestID: UUID?
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onWidthChange = { [weak coordinator = context.coordinator, weak scrollView, weak textView] in
            guard let scrollView, let textView else { return }
            coordinator?.recalculateHeight(for: textView, in: scrollView)
        }
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = metrics.font
        updateAppearance(of: textView)
        textView.textContainerInset = NSSize(width: 0, height: metrics.verticalInset)
        textView.minSize = NSSize(width: 0, height: metrics.minHeight)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.recalculateHeight(for: textView, in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self

        guard let textView = scrollView.documentView as? ComposerTextView else { return }

        if textView.string != text {
            textView.string = text
        }

        textView.onSubmit = onSubmit
        updateAppearance(of: textView)
        if textView.font != metrics.font {
            textView.font = metrics.font
        }
        let inset = NSSize(width: 0, height: metrics.verticalInset)
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
        }

        context.coordinator.recalculateHeight(for: textView, in: scrollView)

        context.coordinator.requestFocus(for: textView, in: scrollView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        textView.delegate = nil
        textView.onSubmit = nil
        textView.onWidthChange = nil
    }

    private func updateAppearance(of textView: NSTextView) {
        // Updating colors in place keeps the text system, selection and Undo stack alive.
        let textColor = NSColor(theme.textPrimary)
        if textView.textColor != textColor {
            textView.textColor = textColor
        }
        let insertionPointColor = NSColor(theme.accent)
        if textView.insertionPointColor != insertionPointColor {
            textView.insertionPointColor = insertionPointColor
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AutoGrowingTextViewRepresentable
        var lastAppliedFocusRequestID: UUID?
        private var isActive = true
        private var pendingHeight: CGFloat?
        private var heightUpdateScheduled = false
        private var pendingFocusRequestID: UUID?

        init(parent: AutoGrowingTextViewRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard isActive,
                  let textView = notification.object as? NSTextView,
                  let scrollView = textView.enclosingScrollView else { return }

            let updatedText = textView.string
            if parent.text != updatedText {
                parent.text = updatedText
            }

            recalculateHeight(for: textView, in: scrollView)
        }

        func recalculateHeight(for textView: NSTextView, in scrollView: NSScrollView) {
            guard isActive else { return }
            guard textView.bounds.width.isFinite, textView.bounds.width > 0,
                  let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager else {
                pendingHeight = nil
                return
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let contentHeight = usedHeight + parent.metrics.verticalInset * 2
            let resolvedHeight = AutoGrowingTextInputMetrics.resolvedHeight(
                for: contentHeight,
                minHeight: parent.metrics.minHeight,
                maxHeight: parent.metrics.maxHeight
            )

            let isClamped = contentHeight > parent.metrics.maxHeight + 0.5
            if scrollView.hasVerticalScroller != isClamped {
                scrollView.hasVerticalScroller = isClamped
            }

            // The latest measurement must supersede a queued value even when it
            // already equals the published height (e.g. long draft -> short draft).
            pendingHeight = resolvedHeight
            guard !heightUpdateScheduled,
                  abs(parent.measuredHeight - resolvedHeight) > 0.5 else { return }
            heightUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightUpdateScheduled = false
                guard self.isActive, let height = self.pendingHeight else { return }
                self.pendingHeight = nil
                if abs(self.parent.measuredHeight - height) > 0.5 {
                    self.parent.measuredHeight = height
                }
            }
        }

        func requestFocus(for textView: NSTextView, in scrollView: NSScrollView) {
            guard isActive, let requestID = parent.focusRequestID,
                  requestID != lastAppliedFocusRequestID,
                  requestID != pendingFocusRequestID else { return }
            pendingFocusRequestID = requestID
            DispatchQueue.main.async { [weak self, weak scrollView, weak textView] in
                guard let self, self.isActive,
                      self.pendingFocusRequestID == requestID else { return }
                self.pendingFocusRequestID = nil
                guard self.parent.focusRequestID == requestID,
                      let scrollView, let textView,
                      let window = scrollView.window, window.isVisible,
                      textView.window === window,
                      window.makeFirstResponder(textView) else { return }
                self.lastAppliedFocusRequestID = requestID
            }
        }

        func invalidate() {
            isActive = false
            pendingHeight = nil
            pendingFocusRequestID = nil
        }
    }
}

@MainActor
private final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onWidthChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let previousWidth = frame.width
        super.setFrameSize(newSize)

        if abs(previousWidth - newSize.width) > 0.5 {
            onWidthChange?()
        }
    }

    override func doCommand(by selector: Selector) {
        guard selector == #selector(insertNewline(_:)) || selector == #selector(insertNewlineIgnoringFieldEditor(_:)) else {
            super.doCommand(by: selector)
            return
        }

        let currentEvent = NSApp.currentEvent
        let keyCode = currentEvent?.keyCode ?? UInt16.max
        let modifiers = currentEvent?.modifierFlags ?? []

        if AutoGrowingTextInputBehavior.shouldSubmit(
            keyCode: keyCode,
            modifiers: modifiers,
            hasMarkedText: hasMarkedText()
        ) {
            onSubmit?()
        } else {
            super.doCommand(by: selector)
        }
    }
}
