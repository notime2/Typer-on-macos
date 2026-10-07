// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Testing
@testable import Typer_On

@Test
@MainActor
func testSelectionCaptureEnginePrefersMarkerForSafariWebProfile() {
    let engine = SelectionCaptureEngine()
    let snapshot = makeSelectionCaptureSnapshot(
        rawText: "Raw",
        selectedTextRangeEvidence: makeSelectionCaptureRangeEvidence(
            text: "Range",
            range: AXTextSelectionRange(location: 1, length: 5)
        ),
        selectedTextMarkerRangeEvidence: .nonEmpty(text: "Marker", range: nil),
        bundleIdentifier: "com.apple.Safari",
        focusedElementRole: "AXWebArea",
        isValueAttributeWritable: false,
        boundsMode: .topLeftNeedsConversion
    )

    let result = engine.resolveCaptureResult(from: snapshot, mode: .event)

    #expect(result?.appProfileID == "safari-web")
    #expect(result?.winningEvidenceSource == .marker)
    #expect(result?.confidence == .high)
}

@Test
@MainActor
func testSelectionCaptureEngineUsesChromiumProfileWithRangeEvidence() {
    let engine = SelectionCaptureEngine()
    let snapshot = makeSelectionCaptureSnapshot(
        rawText: "Raw fallback",
        selectedTextRangeEvidence: makeSelectionCaptureRangeEvidence(
            text: "Hello",
            range: AXTextSelectionRange(location: 0, length: 5)
        ),
        bundleIdentifier: "com.google.Chrome",
        focusedElementRole: "AXWebArea",
        isValueAttributeWritable: false,
        boundsMode: .alreadyAppKit
    )

    let result = engine.resolveCaptureResult(from: snapshot, mode: .polling)

    #expect(result?.appProfileID == "chromium-browser")
    #expect(result?.winningEvidenceSource == .range)
    #expect(result?.selection.text == "Hello")
    #expect(result?.boundsMode == .alreadyAppKit)
    #expect(result?.confidence == .high)
}

@Test
@MainActor
func testSelectionCaptureEngineUsesElectronProfileAndAlreadyAppKitBounds() {
    let engine = SelectionCaptureEngine()
    let snapshot = makeSelectionCaptureSnapshot(
        rawText: "Hello",
        selectedTextRangeEvidence: makeSelectionCaptureRangeEvidence(
            text: "Hello",
            range: AXTextSelectionRange(location: 3, length: 5)
        ),
        bundleIdentifier: "com.microsoft.VSCode",
        focusedElementRole: "AXTextArea",
        isValueAttributeWritable: true,
        boundsMode: .alreadyAppKit
    )

    let result = engine.resolveCaptureResult(from: snapshot, mode: .event)

    #expect(result?.appProfileID == "electron-editor")
    #expect(result?.boundsMode == .alreadyAppKit)
    #expect(result?.confidence == .low)
}

@Test
@MainActor
func testSelectionCaptureEngineUsesElectronProfileForClaudeDesktop() {
    let engine = SelectionCaptureEngine()
    let bundleIdentifier = "com.anthropic.claudefordesktop"
    let boundsMode = AccessibilityManager.coordinateMode(forBundleIdentifier: bundleIdentifier)
    let snapshot = makeSelectionCaptureSnapshot(
        rawText: "Hello",
        selectedTextRangeEvidence: makeSelectionCaptureRangeEvidence(
            text: "Hello",
            range: AXTextSelectionRange(location: 6350, length: 5)
        ),
        selectedTextMarkerRangeEvidence: .nonEmpty(text: "Hello", range: nil),
        bundleIdentifier: bundleIdentifier,
        focusedElementRole: "AXGroup",
        isValueAttributeWritable: false,
        boundsMode: boundsMode
    )

    let result = engine.resolveCaptureResult(from: snapshot, mode: .event)

    #expect(boundsMode == .alreadyAppKit)
    #expect(result?.appProfileID == "electron-editor")
    #expect(result?.winningEvidenceSource == .range)
    #expect(result?.selection.text == "Hello")
    #expect(result?.boundsMode == .alreadyAppKit)
    #expect(result?.confidence == .low)
}

@Test
@MainActor
func testSelectionCaptureEngineMarksTelegramRawOnlyCaptureLowConfidence() {
    let engine = SelectionCaptureEngine()
    let snapshot = makeSelectionCaptureSnapshot(
        rawText: "Hello",
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )

    let result = engine.resolveCaptureResult(from: snapshot, mode: .event)

    #expect(result?.appProfileID == "telegram-editor")
    #expect(result?.winningEvidenceSource == .raw)
    #expect(result?.confidence == .low)
}

@Test
@MainActor
func testSelectionCaptureEngineFallsBackToUnknownProfileForRawOnlyWebArea() {
    let engine = SelectionCaptureEngine()
    let snapshot = makeSelectionCaptureSnapshot(
        rawText: "Hello",
        bundleIdentifier: "com.example.browser",
        focusedElementRole: "AXWebArea",
        isValueAttributeWritable: false
    )

    let result = engine.resolveCaptureResult(from: snapshot, mode: .polling)

    #expect(result?.appProfileID == "unknown")
    #expect(result?.winningEvidenceSource == .raw)
    #expect(result?.confidence == .low)
}

@Test
@MainActor
func testSelectionCaptureEngineMarksMultiRangeSelectionDiscontiguous() {
    let engine = SelectionCaptureEngine()
    let firstRange = AXTextSelectionRange(location: 0, length: 5)
    let secondRange = AXTextSelectionRange(location: 12, length: 5)
    let snapshot = makeSelectionCaptureSnapshot(
        rawText: nil,
        selectedTextRangesEvidence: .nonEmpty(text: "HelloWorld", range: nil),
        bundleIdentifier: "com.microsoft.VSCode",
        focusedElementRole: "AXTextArea",
        isValueAttributeWritable: true
    )

    let resolvedSnapshot = AXTextSelectionSnapshot(
        rawSelectedTextEvidence: snapshot.rawSelectedTextEvidence,
        selectedTextRangesEvidence: snapshot.selectedTextRangesEvidence,
        selectedTextRangeEvidence: snapshot.selectedTextRangeEvidence,
        selectedTextMarkerRangeEvidence: snapshot.selectedTextMarkerRangeEvidence,
        selectedTextRanges: [firstRange, secondRange],
        cursorPosition: snapshot.cursorPosition,
        selectionBounds: snapshot.selectionBounds,
        sourceAppPID: snapshot.sourceAppPID,
        appBundleIdentifier: snapshot.appBundleIdentifier,
        focusedElementRole: snapshot.focusedElementRole,
        focusedElementSubrole: snapshot.focusedElementSubrole,
        isValueAttributeWritable: snapshot.isValueAttributeWritable,
        boundsMode: snapshot.boundsMode,
        focusedElementID: snapshot.focusedElementID
    )

    let result = engine.resolveCaptureResult(from: resolvedSnapshot, mode: .event)

    #expect(result?.selection.hasDiscontiguousSelection == true)
    #expect(result?.selection.selectedTextRange == nil)
    #expect(result?.selection.text == "HelloWorld")
}

@MainActor
private func makeSelectionCaptureSnapshot(
    rawText: String?,
    selectedTextRangesEvidence: AXSelectionEvidence = .unsupported,
    selectedTextRangeEvidence: AXSelectionEvidence = .unsupported,
    selectedTextMarkerRangeEvidence: AXSelectionEvidence = .unsupported,
    bundleIdentifier: String?,
    focusedElementRole: String?,
    focusedElementSubrole: String? = nil,
    isValueAttributeWritable: Bool = true,
    boundsMode: AccessibilityManager.SelectionBoundsCoordinateMode = .topLeftNeedsConversion
) -> AXTextSelectionSnapshot {
    AXTextSelectionSnapshot(
        rawSelectedTextEvidence: makeSelectionCaptureRawEvidence(text: rawText),
        selectedTextRangesEvidence: selectedTextRangesEvidence,
        selectedTextRangeEvidence: selectedTextRangeEvidence,
        selectedTextMarkerRangeEvidence: selectedTextMarkerRangeEvidence,
        cursorPosition: NSPoint(x: 40, y: 80),
        selectionBounds: NSRect(x: 20, y: 60, width: 100, height: 20),
        sourceAppPID: 123,
        appBundleIdentifier: bundleIdentifier,
        focusedElementRole: focusedElementRole,
        focusedElementSubrole: focusedElementSubrole,
        isValueAttributeWritable: isValueAttributeWritable,
        boundsMode: boundsMode,
        focusedElementID: 11
    )
}

private func makeSelectionCaptureRawEvidence(text: String?) -> AXSelectionEvidence {
    guard let text, !text.isEmpty else {
        return .empty
    }
    return .nonEmpty(text: text, range: nil)
}

private func makeSelectionCaptureRangeEvidence(text: String?, range: AXTextSelectionRange?) -> AXSelectionEvidence {
    guard let range, range.length > 0 else {
        return .empty
    }
    return .nonEmpty(text: text, range: range)
}
