// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Testing
@testable import Typer_On

@Test
@MainActor
func testReplacementHelperReplacesAtBeginning() {
    let replacement = AccessibilityManager.replacingValue(
        "Hello world",
        replacing: AXTextSelectionRange(location: 0, length: 5),
        with: "Hi"
    )

    #expect(replacement?.updatedValue == "Hi world")
    #expect(replacement?.insertionRange == AXTextSelectionRange(location: 2, length: 0))
}

@Test
@MainActor
func testReplacementHelperReplacesInMiddle() {
    let replacement = AccessibilityManager.replacingValue(
        "Hello world",
        replacing: AXTextSelectionRange(location: 6, length: 5),
        with: "Typer On"
    )

    #expect(replacement?.updatedValue == "Hello Typer On")
    #expect(replacement?.insertionRange == AXTextSelectionRange(location: 14, length: 0))
}

@Test
@MainActor
func testReplacementHelperReplacesAtEnd() {
    let replacement = AccessibilityManager.replacingValue(
        "Hello world",
        replacing: AXTextSelectionRange(location: 6, length: 5),
        with: "there"
    )

    #expect(replacement?.updatedValue == "Hello there")
    #expect(replacement?.insertionRange == AXTextSelectionRange(location: 11, length: 0))
}

@Test
@MainActor
func testReplacementHelperRejectsCollapsedRange() {
    let replacement = AccessibilityManager.replacingValue(
        "Hello world",
        replacing: AXTextSelectionRange(location: 6, length: 0),
        with: "there"
    )

    #expect(replacement == nil)
}

@Test
@MainActor
func testReplacementHelperRejectsOutOfBoundsRange() {
    let replacement = AccessibilityManager.replacingValue(
        "Hello world",
        replacing: AXTextSelectionRange(location: 20, length: 1),
        with: "there"
    )

    #expect(replacement == nil)
}

@Test
@MainActor
func testReplacementHelperUsesUTF16OffsetsForEmoji() {
    let currentValue = "Hello 👋🏽 world"
    let currentNSString = currentValue as NSString
    let selectedRange = currentNSString.range(of: "👋🏽")

    let replacement = AccessibilityManager.replacingValue(
        currentValue,
        replacing: AXTextSelectionRange(location: selectedRange.location, length: selectedRange.length),
        with: "wave"
    )

    #expect(replacement?.updatedValue == "Hello wave world")
    #expect(replacement?.insertionRange == AXTextSelectionRange(location: selectedRange.location + 4, length: 0))
}

@Test
@MainActor
func testReplacementHelperUsesUTF16OffsetsForCombiningMarks() {
    let currentValue = "Cafe\u{301} noir"
    let currentNSString = currentValue as NSString
    let selectedRange = currentNSString.range(of: "e\u{301}")

    let replacement = AccessibilityManager.replacingValue(
        currentValue,
        replacing: AXTextSelectionRange(location: selectedRange.location, length: selectedRange.length),
        with: "E"
    )

    #expect(replacement?.updatedValue == "CafE noir")
    #expect(replacement?.insertionRange == AXTextSelectionRange(location: selectedRange.location + 1, length: 0))
}

@Test
@MainActor
func testReplacementHelperUsesUTF16OffsetsForZWJSequences() {
    let currentValue = "A👨‍👩‍👧‍👦B"
    let currentNSString = currentValue as NSString
    let selectedRange = currentNSString.range(of: "👨‍👩‍👧‍👦")

    let replacement = AccessibilityManager.replacingValue(
        currentValue,
        replacing: AXTextSelectionRange(location: selectedRange.location, length: selectedRange.length),
        with: "family"
    )

    #expect(replacement?.updatedValue == "AfamilyB")
    #expect(replacement?.insertionRange == AXTextSelectionRange(location: selectedRange.location + 6, length: 0))
}

@Test
@MainActor
func testDirectReplacementContextRejectsFocusedElementDrift() {
    let isValid = AccessibilityManager.isDirectReplacementContextValid(
        expectedFocusedElementID: 11,
        currentFocusedElementID: 12,
        preferredSelectionRange: AXTextSelectionRange(location: 2, length: 3),
        currentSelectionRange: AXTextSelectionRange(location: 2, length: 3)
    )

    #expect(isValid == false)
}

@Test
@MainActor
func testDirectReplacementContextRejectsSelectionDrift() {
    let isValid = AccessibilityManager.isDirectReplacementContextValid(
        expectedFocusedElementID: 11,
        currentFocusedElementID: 11,
        preferredSelectionRange: AXTextSelectionRange(location: 2, length: 3),
        currentSelectionRange: AXTextSelectionRange(location: 4, length: 3)
    )

    #expect(isValid == false)
}

@Test
@MainActor
func testReplacementHelperRejectsChangedTextAtCapturedRange() {
    let replacement = AccessibilityManager.replacingValue(
        "Other world",
        replacing: AXTextSelectionRange(location: 0, length: 5),
        with: "Updated",
        expectedSelectedText: "Hello"
    )

    #expect(replacement == nil)
}

@Test
@MainActor
func testReplacementHelperVerifiesExactUTF16SelectedText() {
    let original = "A👋🏽B"
    let range = (original as NSString).range(of: "👋🏽")
    let replacement = AccessibilityManager.replacingValue(
        original,
        replacing: AXTextSelectionRange(location: range.location, length: range.length),
        with: "wave",
        expectedSelectedText: "👋🏽"
    )

    #expect(replacement?.updatedValue == "AwaveB")
}

@Test
@MainActor
func testDirectReplacementContextRejectsUnknownFocusedElement() {
    #expect(AccessibilityManager.isDirectReplacementContextValid(
        expectedFocusedElementID: 0,
        currentFocusedElementID: 11,
        preferredSelectionRange: AXTextSelectionRange(location: 2, length: 3),
        currentSelectionRange: AXTextSelectionRange(location: 2, length: 3)
    ) == false)
}
