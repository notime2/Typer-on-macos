// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import Typer_On

@Test
@MainActor
func testLatestComposerMeasurementSupersedesQueuedHeightEvenWhenItMatchesCurrentHeight() async {
    let metrics = AutoGrowingTextInputMetrics()
    var height = metrics.minHeight
    var appliedHeights: [CGFloat] = []
    let parent = AutoGrowingTextViewRepresentable(
        text: .constant(""),
        measuredHeight: Binding(get: { height }, set: { height = $0; appliedHeights.append($0) }),
        metrics: metrics,
        theme: DialogTheme(style: .glassDot),
        focusRequestID: nil,
        onSubmit: {}
    )
    let coordinator = parent.makeCoordinator()
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
    editor.font = metrics.font
    editor.isVerticallyResizable = true
    scroll.documentView = editor
    editor.string = Array(repeating: "Synthetic line", count: 20).joined(separator: "\n")
    coordinator.recalculateHeight(for: editor, in: scroll)
    editor.string = "Short"
    coordinator.recalculateHeight(for: editor, in: scroll)
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(height == metrics.minHeight)
    #expect(appliedHeights.isEmpty)
}

@Test(arguments: [false, true])
@MainActor
func testComposerPendingMeasurementIsDiscardedForDismantleOrInvalidWidth(dismantle: Bool) async {
    let metrics = AutoGrowingTextInputMetrics()
    var writes = 0
    let parent = AutoGrowingTextViewRepresentable(
        text: .constant(""),
        measuredHeight: Binding(get: { metrics.minHeight }, set: { _ in writes += 1 }),
        metrics: metrics, theme: DialogTheme(style: .glassDot), focusRequestID: nil, onSubmit: {}
    )
    let coordinator = parent.makeCoordinator()
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
    let editor = NSTextView(frame: scroll.bounds)
    editor.font = metrics.font
    scroll.documentView = editor
    editor.string = Array(repeating: "Synthetic", count: 20).joined(separator: "\n")
    for _ in 0..<10 { coordinator.recalculateHeight(for: editor, in: scroll) }
    if dismantle {
        AutoGrowingTextViewRepresentable.dismantleNSView(scroll, coordinator: coordinator)
    } else {
        editor.setFrameSize(NSSize(width: 0, height: 32))
        coordinator.recalculateHeight(for: editor, in: scroll)
    }
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(writes == 0)
}

@Test
@MainActor
func testComposerAppliesOnlyLatestFocusAndDiscardsFocusAfterDismantle() async {
    let first = UUID()
    let latest = UUID()
    let parent = AutoGrowingTextViewRepresentable(
        text: .constant(""), measuredHeight: .constant(32),
        metrics: AutoGrowingTextInputMetrics(), theme: DialogTheme(style: .glassDot),
        focusRequestID: first, onSubmit: {}
    )
    let coordinator = parent.makeCoordinator()
    let window = ComposerFocusProbeWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
    let editor = NSTextView(frame: scroll.bounds)
    scroll.documentView = editor
    window.contentView = scroll
    window.orderFront(nil)
    window.editorFocusRequests = 0
    coordinator.requestFocus(for: editor, in: scroll)
    coordinator.parent = AutoGrowingTextViewRepresentable(
        text: .constant(""), measuredHeight: .constant(32),
        metrics: AutoGrowingTextInputMetrics(), theme: DialogTheme(style: .glassDot),
        focusRequestID: latest, onSubmit: {}
    )
    coordinator.requestFocus(for: editor, in: scroll)
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(coordinator.lastAppliedFocusRequestID == latest)
    #expect(window.editorFocusRequests == 1)

    coordinator.parent = parent
    coordinator.requestFocus(for: editor, in: scroll)
    AutoGrowingTextViewRepresentable.dismantleNSView(scroll, coordinator: coordinator)
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    #expect(coordinator.lastAppliedFocusRequestID == latest)
    #expect(window.editorFocusRequests == 1)
}

@MainActor
private final class ComposerFocusProbeWindow: NSWindow {
    var editorFocusRequests = 0
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder is NSTextView { editorFocusRequests += 1 }
        return super.makeFirstResponder(responder)
    }
}

@Test
func testAutoGrowingInputResolvedHeightClampsToMinimumAndMaximum() {
    let minHeight: CGFloat = 32
    let maxHeight: CGFloat = 110

    let belowMinimum = AutoGrowingTextInputMetrics.resolvedHeight(
        for: 18,
        minHeight: minHeight,
        maxHeight: maxHeight
    )
    let withinRange = AutoGrowingTextInputMetrics.resolvedHeight(
        for: 64.2,
        minHeight: minHeight,
        maxHeight: maxHeight
    )
    let aboveMaximum = AutoGrowingTextInputMetrics.resolvedHeight(
        for: 160,
        minHeight: minHeight,
        maxHeight: maxHeight
    )

    #expect(belowMinimum == minHeight)
    #expect(withinRange == 65)
    #expect(aboveMaximum == maxHeight)
}

@Test
func testAutoGrowingInputMetricsKeepSingleLineBaselineAndMultiLineCap() {
    let metrics = AutoGrowingTextInputMetrics(maxVisibleLines: 6)

    #expect(metrics.minHeight >= 32)
    #expect(metrics.maxHeight > metrics.minHeight)
}

@Test
func testAutoGrowingInputPlainReturnSubmits() {
    let plainReturn = AutoGrowingTextInputBehavior.shouldSubmit(
        keyCode: UInt16(kVK_Return),
        modifiers: [],
        hasMarkedText: false
    )
    let keypadEnter = AutoGrowingTextInputBehavior.shouldSubmit(
        keyCode: UInt16(kVK_ANSI_KeypadEnter),
        modifiers: [.command],
        hasMarkedText: false
    )

    #expect(plainReturn)
    #expect(keypadEnter)
}

@Test
func testAutoGrowingInputModifiersAndMarkedTextPreventSubmit() {
    let shiftReturn = AutoGrowingTextInputBehavior.shouldSubmit(
        keyCode: UInt16(kVK_Return),
        modifiers: [.shift],
        hasMarkedText: false
    )
    let optionReturn = AutoGrowingTextInputBehavior.shouldSubmit(
        keyCode: UInt16(kVK_Return),
        modifiers: [.option],
        hasMarkedText: false
    )
    let markedTextReturn = AutoGrowingTextInputBehavior.shouldSubmit(
        keyCode: UInt16(kVK_Return),
        modifiers: [],
        hasMarkedText: true
    )
    let unrelatedKey = AutoGrowingTextInputBehavior.shouldSubmit(
        keyCode: UInt16(kVK_ANSI_A),
        modifiers: [],
        hasMarkedText: false
    )

    #expect(!shiftReturn)
    #expect(!optionReturn)
    #expect(!markedTextReturn)
    #expect(!unrelatedKey)
}


@MainActor
@Test
func testOpenComposerThemeChangesPreserveEditorTextSelectionScrollAndUndo() throws {
    let initialText = (0..<20).map { "Synthetic line \($0)" }.joined(separator: "\n")
    var draft = initialText
    let binding = Binding(get: { draft }, set: { draft = $0 })
    func content(_ style: SelectionTriggerStyle) -> some View {
        AutoGrowingTextInput(text: binding, placeholder: "Message", onSubmit: {})
            .environment(\.dialogTheme, DialogTheme(style: style))
            .frame(width: 320, height: 140)
    }

    let hostingView = NSHostingView(rootView: content(.glassDot))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    defer { window.close() }
    hostingView.layoutSubtreeIfNeeded()

    let editor = try #require(findComposerEditor(in: hostingView))
    let scrollView = try #require(editor.enclosingScrollView)
    let undoManager = try #require(editor.undoManager)
    undoManager.beginUndoGrouping()
    editor.insertText(" added", replacementRange: NSRange(location: (initialText as NSString).length, length: 0))
    undoManager.endUndoGrouping()
    let editedText = initialText + " added"
    #expect(draft == editedText)
    #expect(undoManager.canUndo)

    let selection = NSRange(location: 3, length: 8)
    editor.setSelectedRange(selection)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 40))
    let scrollOrigin = scrollView.contentView.bounds.origin

    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = try #require(NSAppearance(named: appearanceName))
        window.appearance = appearance
        for style in SelectionTriggerStyle.allCases {
            hostingView.rootView = content(style)
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            let currentEditor = try #require(findComposerEditor(in: hostingView))
            #expect(currentEditor === editor)
            #expect(editor.string == editedText)
            #expect(draft == editedText)
            #expect(editor.selectedRange() == selection)
            #expect(scrollView.contentView.bounds.origin == scrollOrigin)
            #expect(editor.undoManager === undoManager)
            #expect(undoManager.canUndo)
            let theme = DialogTheme(style: style)
            appearance.performAsCurrentDrawingAppearance {
                #expect(editor.textColor?.usingColorSpace(.deviceRGB) == NSColor(theme.textPrimary).usingColorSpace(.deviceRGB))
                #expect(editor.insertionPointColor.usingColorSpace(.deviceRGB) == NSColor(theme.accent).usingColorSpace(.deviceRGB))
            }
        }
    }

    undoManager.undo()
    #expect(editor.string == initialText)
    #expect(draft == initialText)
}

@MainActor
private func findComposerEditor(in view: NSView) -> NSTextView? {
    if let editor = view as? NSTextView { return editor }
    for child in view.subviews {
        if let editor = findComposerEditor(in: child) { return editor }
    }
    return nil
}
