// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Carbon.HIToolbox
import Testing
@testable import Typer_On

@Test
@MainActor
func testModuleShortcutResolverAcceptsCommandDigits() {
    let firstModule = FloatingToolbarViewModel.moduleIndexForShortcut(
        keyCode: UInt16(kVK_ANSI_1),
        modifiers: [.command]
    )
    let ninthModule = FloatingToolbarViewModel.moduleIndexForShortcut(
        keyCode: UInt16(kVK_ANSI_9),
        modifiers: [.command]
    )

    #expect(firstModule == 0)
    #expect(ninthModule == 8)
}

@Test
@MainActor
func testModuleShortcutResolverRejectsPlainDigitsAndExtraModifiers() {
    let plainDigit = FloatingToolbarViewModel.moduleIndexForShortcut(
        keyCode: UInt16(kVK_ANSI_1),
        modifiers: []
    )
    let commandShiftDigit = FloatingToolbarViewModel.moduleIndexForShortcut(
        keyCode: UInt16(kVK_ANSI_1),
        modifiers: [.command, .shift]
    )
    let nonDigitWithCommand = FloatingToolbarViewModel.moduleIndexForShortcut(
        keyCode: UInt16(kVK_ANSI_A),
        modifiers: [.command]
    )

    #expect(plainDigit == nil)
    #expect(commandShiftDigit == nil)
    #expect(nonDigitWithCommand == nil)
}

@Test
@MainActor
func testKeyboardActionResolvesEscapeAndValidModuleShortcut() {
    let escapeAction = FloatingToolbarViewModel.keyboardAction(
        keyCode: UInt16(kVK_Escape),
        modifiers: [],
        moduleCount: 3
    )
    let firstModuleAction = FloatingToolbarViewModel.keyboardAction(
        keyCode: UInt16(kVK_ANSI_1),
        modifiers: [.command],
        moduleCount: 3
    )

    #expect(escapeAction == .dismiss)
    #expect(firstModuleAction == .invokeModule(0))
}

@Test
@MainActor
func testKeyboardActionResolvesEscapeWithModifiers() {
    let escapeWithModifiers = FloatingToolbarViewModel.keyboardAction(
        keyCode: UInt16(kVK_Escape),
        modifiers: [.command, .shift],
        moduleCount: 3
    )

    #expect(escapeWithModifiers == .dismiss)
}

@Test
@MainActor
func testKeyboardActionRejectsOutOfRangeAndInvalidModifiers() {
    let outOfRangeAction = FloatingToolbarViewModel.keyboardAction(
        keyCode: UInt16(kVK_ANSI_9),
        modifiers: [.command],
        moduleCount: 3
    )
    let plainDigitAction = FloatingToolbarViewModel.keyboardAction(
        keyCode: UInt16(kVK_ANSI_1),
        modifiers: [],
        moduleCount: 3
    )
    let commandShiftAction = FloatingToolbarViewModel.keyboardAction(
        keyCode: UInt16(kVK_ANSI_1),
        modifiers: [.command, .shift],
        moduleCount: 3
    )

    #expect(outOfRangeAction == nil)
    #expect(plainDigitAction == nil)
    #expect(commandShiftAction == nil)
}
