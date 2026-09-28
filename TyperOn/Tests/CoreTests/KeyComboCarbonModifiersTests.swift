// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Carbon.HIToolbox
import Testing
@testable import Typer_On

@Test
func testDefaultGlobalHotkeyIsOptionF() {
    let combo = KeyCombo.defaultGlobalHotkey

    #expect(combo.keyCode == UInt16(kVK_ANSI_F))
    #expect(combo.nsEventModifierFlags == [.option])
    #expect(combo.keyEquivalentCharacter == "f")
    #expect(combo.displayString == "⌥F")
}

@Test
func testCarbonModifiersCommand() {
    let combo = KeyCombo(
        keyCode: UInt16(kVK_ANSI_X),
        modifiers: UInt(CGEventFlags.maskCommand.rawValue)
    )
    #expect(combo.carbonModifiers == UInt32(cmdKey))
}

@Test
func testCarbonModifiersCommandShift() {
    let combo = KeyCombo(
        keyCode: UInt16(kVK_ANSI_X),
        modifiers: UInt(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
    )
    #expect(combo.carbonModifiers == UInt32(cmdKey) | UInt32(shiftKey))
}

@Test
func testCarbonModifiersOptionControl() {
    let combo = KeyCombo(
        keyCode: UInt16(kVK_ANSI_A),
        modifiers: UInt(CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue)
    )
    #expect(combo.carbonModifiers == UInt32(optionKey) | UInt32(controlKey))
}

@Test
func testCarbonModifiersAllModifiers() {
    let combo = KeyCombo(
        keyCode: UInt16(kVK_ANSI_Z),
        modifiers: UInt(
            CGEventFlags.maskCommand.rawValue |
            CGEventFlags.maskShift.rawValue |
            CGEventFlags.maskAlternate.rawValue |
            CGEventFlags.maskControl.rawValue
        )
    )
    let expected = UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey) | UInt32(controlKey)
    #expect(combo.carbonModifiers == expected)
}

@Test
func testCarbonModifiersNoModifiers() {
    let combo = KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: 0)
    #expect(combo.carbonModifiers == 0)
}
