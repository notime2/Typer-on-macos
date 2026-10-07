// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import CoreGraphics
import Carbon.HIToolbox

enum KeySimulator {
    static func simulateCopy() {
        simulateKeyPress(keyCode: UInt16(kVK_ANSI_C), flags: .maskCommand)
    }

    static func simulatePaste() {
        simulateKeyPress(keyCode: UInt16(kVK_ANSI_V), flags: .maskCommand)
    }

    static func simulateUndo() {
        simulateKeyPress(keyCode: UInt16(kVK_ANSI_Z), flags: .maskCommand)
    }

    private static func simulateKeyPress(keyCode: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }

        keyDown.flags = flags
        keyUp.flags = flags

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
