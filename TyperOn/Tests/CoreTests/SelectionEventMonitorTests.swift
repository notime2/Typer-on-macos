// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Carbon
import CoreGraphics
import Testing
@testable import Typer_On

@Test
@MainActor
func testSelectionEventMonitorHandlesMouseUp() {
    #expect(SelectionEventMonitor.shouldHandleEvent(type: .leftMouseUp, keyCode: nil, flags: []))
}

@Test
@MainActor
func testSelectionEventMonitorHandlesShiftKeyUp() {
    #expect(SelectionEventMonitor.shouldHandleEvent(type: .keyUp, keyCode: nil, flags: .maskShift))
}

@Test
@MainActor
func testSelectionEventMonitorHandlesDeleteKeyUp() {
    #expect(
        SelectionEventMonitor.shouldHandleEvent(
            type: .keyUp,
            keyCode: CGKeyCode(kVK_Delete),
            flags: []
        )
    )
}

@Test
@MainActor
func testSelectionEventMonitorHandlesForwardDeleteKeyUp() {
    #expect(
        SelectionEventMonitor.shouldHandleEvent(
            type: .keyUp,
            keyCode: CGKeyCode(kVK_ForwardDelete),
            flags: []
        )
    )
}

@Test
@MainActor
func testSelectionEventMonitorIgnoresCommandShiftKeyUp() {
    #expect(
        !SelectionEventMonitor.shouldHandleEvent(
            type: .keyUp,
            keyCode: CGKeyCode(kVK_Delete),
            flags: [.maskShift, .maskCommand]
        )
    )
}

@Test
@MainActor
func testSelectionEventMonitorIgnoresModifierKeyKeyUp() {
    #expect(
        !SelectionEventMonitor.shouldHandleEvent(
            type: .keyUp,
            keyCode: CGKeyCode(kVK_Shift),
            flags: .maskShift
        )
    )
}

@Test
@MainActor
func testSelectionEventMonitorHandlesShiftArrowKeyUp() {
    #expect(
        SelectionEventMonitor.shouldHandleEvent(
            type: .keyUp,
            keyCode: CGKeyCode(kVK_RightArrow),
            flags: .maskShift
        )
    )
}

@Test
@MainActor
func testSelectionEventMonitorIgnoresPlainKeyUp() {
    #expect(
        !SelectionEventMonitor.shouldHandleEvent(
            type: .keyUp,
            keyCode: CGKeyCode(kVK_ANSI_A),
            flags: []
        )
    )
}

@Test
@MainActor
func testSelectionEventMonitorIgnoresModifiedDeleteKeyUp() {
    #expect(
        !SelectionEventMonitor.shouldHandleEvent(
            type: .keyUp,
            keyCode: CGKeyCode(kVK_ForwardDelete),
            flags: .maskAlternate
        )
    )
}

@Test
@MainActor
func testSelectionEventMonitorIgnoresOtherEventTypes() {
    #expect(
        !SelectionEventMonitor.shouldHandleEvent(
            type: .leftMouseDown,
            keyCode: nil,
            flags: []
        )
    )
}

@Test
@MainActor
func testTextSelectionObserverSuppressesImmediateAutomaticClearAfterExplicitCapture() {
    let now = Date()
    let selection = TextSelection(
        text: "Telegram selection",
        cursorPosition: .zero,
        sourceAppPID: 42,
        capturedAt: now
    )

    #expect(
        TextSelectionObserver.shouldSuppressAutomaticClear(
            currentSelection: selection,
            until: now.addingTimeInterval(0.5),
            now: now
        )
    )
}

@Test
@MainActor
func testTextSelectionObserverStopsSuppressingAutomaticClearAfterGracePeriod() {
    let now = Date()
    let selection = TextSelection(
        text: "Telegram selection",
        cursorPosition: .zero,
        sourceAppPID: 42,
        capturedAt: now
    )

    #expect(
        !TextSelectionObserver.shouldSuppressAutomaticClear(
            currentSelection: selection,
            until: now.addingTimeInterval(-0.1),
            now: now
        )
    )
}
