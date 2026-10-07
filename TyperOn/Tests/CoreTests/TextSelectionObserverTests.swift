// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Testing
@testable import Typer_On

@Test
@MainActor
func testSelectionObserverClearsWhenRangeCollapsesButRawTextStaysStale() async {
    var polled: AXTextSelectionSnapshot?
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in polled },
        frontmostPIDReader: { 123 }
    )
    var changedSelections: [String] = []
    var clearedCount = 0

    observer.onSelectionChanged = { result in
        changedSelections.append(result.selection.text)
    }
    observer.onSelectionCleared = {
        clearedCount += 1
    }

    polled = makeSelectionSnapshot(
        rawText: "Hello",
        selectedTextRangeEvidence: makeRangeEvidence(
            text: "Hello",
            range: AXTextSelectionRange(location: 3, length: 5)
        )
    )
    await poll(observer)
    polled = makeSelectionSnapshot(
        rawText: "Hello",
        selectedTextRangeEvidence: .empty
    )
    await poll(observer)

    #expect(changedSelections == ["Hello"])
    #expect(clearedCount == 1)
    #expect(observer.currentSelection == nil)
}

@Test
@MainActor
func testSelectionObserverClearsWhenRangeBackedSourcesTurnEmptyButRawTextStaysStale() async {
    var polled: AXTextSelectionSnapshot?
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in polled },
        frontmostPIDReader: { 123 }
    )
    var clearedCount = 0

    observer.onSelectionCleared = {
        clearedCount += 1
    }

    polled = makeSelectionSnapshot(
        rawText: "Hello",
        selectedTextRangeEvidence: makeRangeEvidence(
            text: "Hello",
            range: AXTextSelectionRange(location: 0, length: 5)
        ),
        selectedTextMarkerRangeEvidence: makeMarkerEvidence(text: "Hello")
    )
    await poll(observer)
    polled = makeSelectionSnapshot(
        rawText: "Hello",
        selectedTextRangeEvidence: .empty,
        selectedTextMarkerRangeEvidence: .empty
    )
    await poll(observer)

    #expect(clearedCount == 1)
    #expect(observer.currentSelection == nil)
}

@Test
@MainActor
func testSelectionObserverClearsWhenOnlyOneRangeBackedSourceStaysStale() async {
    var polled: AXTextSelectionSnapshot?
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in polled },
        frontmostPIDReader: { 123 }
    )
    var clearedCount = 0

    observer.onSelectionCleared = {
        clearedCount += 1
    }

    polled = makeSelectionSnapshot(
        rawText: "Hello",
        selectedTextRangesEvidence: makeRangeEvidence(
            text: "Hello",
            range: AXTextSelectionRange(location: 2, length: 5)
        ),
        selectedTextRangeEvidence: makeRangeEvidence(
            text: "Hello",
            range: AXTextSelectionRange(location: 2, length: 5)
        ),
        selectedTextMarkerRangeEvidence: makeMarkerEvidence(text: "Hello")
    )
    await poll(observer)
    polled = makeSelectionSnapshot(
        rawText: "Hello",
        selectedTextRangesEvidence: .empty,
        selectedTextRangeEvidence: makeRangeEvidence(
            text: "Hello",
            range: AXTextSelectionRange(location: 2, length: 5)
        ),
        selectedTextMarkerRangeEvidence: .empty
    )
    await poll(observer)

    #expect(clearedCount == 1)
    #expect(observer.currentSelection == nil)
}

@Test
@MainActor
func testSelectionObserverDoesNotClearOrReemitUnchangedRangeBackedSelection() async {
    var polled: AXTextSelectionSnapshot?
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in polled },
        frontmostPIDReader: { 123 }
    )
    let range = AXTextSelectionRange(location: 2, length: 5)
    let snapshot = makeSelectionSnapshot(
        rawText: "Hello",
        selectedTextRangeEvidence: makeRangeEvidence(
            text: "Hello",
            range: range
        )
    )
    var changedCount = 0
    var clearedCount = 0

    observer.onSelectionChanged = { _ in
        changedCount += 1
    }
    observer.onSelectionCleared = {
        clearedCount += 1
    }

    polled = snapshot
    await poll(observer)
    await poll(observer)

    #expect(changedCount == 1)
    #expect(clearedCount == 0)
    #expect(observer.currentSelection?.text == "Hello")
    #expect(observer.currentSelection?.selectedTextRange == range)
}

@Test
@MainActor
func testSelectionObserverKeepsRawOnlyAppSelectionActive() async {
    var polled: AXTextSelectionSnapshot?
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in polled },
        frontmostPIDReader: { 123 }
    )
    let snapshot = makeSelectionSnapshot(rawText: "Hello")
    var changedCount = 0
    var clearedCount = 0

    observer.onSelectionChanged = { _ in
        changedCount += 1
    }
    observer.onSelectionCleared = {
        clearedCount += 1
    }

    polled = snapshot
    await poll(observer)
    await poll(observer)

    #expect(changedCount == 1)
    #expect(clearedCount == 0)
    #expect(observer.currentSelection?.text == "Hello")
}

@Test
@MainActor
func testCaptureSelectionUsesRawAXTextWhenRangeBackedEvidenceIsEmpty() async {
    var clipboardFallbackCalls = 0
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in
            makeSelectionSnapshot(
                rawText: "Raw AX text",
                selectedTextRangeEvidence: .empty,
                selectedTextMarkerRangeEvidence: .empty
            )
        },
        clipboardSelectionCapture: { _ in
            clipboardFallbackCalls += 1
            return TextSelection(
                text: "Clipboard fallback",
                cursorPosition: NSPoint(x: 20, y: 40),
                sourceAppPID: 321
            )
        }
    )

    let capturedSelection = await observer.captureSelection()

    #expect(capturedSelection?.text == "Raw AX text")
    #expect(observer.currentSelection?.text == "Raw AX text")
    #expect(clipboardFallbackCalls == 0)
}

@Test
@MainActor
func testCaptureSelectionFallsBackToExplicitClipboardPathWhenSnapshotIsUnavailable() async {
    let fallbackSelection = TextSelection(
        text: "Clipboard fallback",
        cursorPosition: NSPoint(x: 20, y: 40),
        sourceAppPID: 321
    )
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in
            makeSelectionSnapshot(
                rawText: nil,
                selectedTextRangeEvidence: .empty
            )
        },
        clipboardSelectionCapture: { _ in
            fallbackSelection
        }
    )

    let capturedSelection = await observer.captureSelection()

    #expect(capturedSelection?.text == fallbackSelection.text)
    #expect(capturedSelection?.selectedTextRange == nil)
    #expect(observer.currentSelection?.text == fallbackSelection.text)
    #expect(observer.currentSelection?.selectedTextRange == nil)
}

@Test
@MainActor
func testConfirmSelectionCaptureReturnsConfirmedResultForSameTextAndFocusedElement() async {
    let snapshot = makeSelectionSnapshot(
        rawText: "Hello",
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot }
    )

    _ = await observer.captureSelection()
    let pendingResult = observer.currentCaptureResult
    #expect(pendingResult != nil)

    let confirmedResult = pendingResult.flatMap { observer.confirmSelectionCapture($0) }

    #expect(confirmedResult?.selection.text == "Hello")
    #expect(confirmedResult?.focusedElementID == pendingResult?.focusedElementID)
}

@Test
@MainActor
func testConfirmSelectionCaptureRejectsChangedFocusedElement() async {
    var snapshot = makeSelectionSnapshot(
        rawText: "Hello",
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot }
    )

    _ = await observer.captureSelection()
    let pendingResult = observer.currentCaptureResult
    #expect(pendingResult != nil)
    snapshot = makeSelectionSnapshot(
        rawText: "Hello",
        elementID: 99,
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )

    let confirmedResult = pendingResult.flatMap { observer.confirmSelectionCapture($0) }

    #expect(confirmedResult == nil)
}

@Test
@MainActor
func testExplicitTelegramCaptureIgnoresPollingClearWhileHeld() async {
    var snapshot: AXTextSelectionSnapshot? = makeSelectionSnapshot(
        rawText: "Hello",
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot },
        frontmostPIDReader: { 123 }
    )
    var clearedCount = 0

    observer.onSelectionCleared = {
        clearedCount += 1
    }

    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    snapshot = makeSelectionSnapshot(
        rawText: nil,
        selectedTextRangeEvidence: .empty,
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )
    await poll(observer)

    #expect(clearedCount == 0)
    #expect(observer.currentSelection?.text == "Hello")
}

@Test
@MainActor
func testExplicitTelegramClipboardFallbackOriginActivatesHold() async {
    let fallbackSelection = TextSelection(
        text: "Clipboard fallback",
        cursorPosition: NSPoint(x: 20, y: 40)
    )
    // The poll sees a real focused element while the clipboard capture carries the unknown ID 0.
    let focusedMessage = makeSelectionSnapshot(
        rawText: nil,
        selectedTextRangeEvidence: .empty,
        elementID: 42,
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )
    var outcome: AXSelectionReadOutcome = .snapshot(focusedMessage)
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in
            makeSelectionSnapshot(
                rawText: nil,
                selectedTextRangeEvidence: .empty,
                bundleIdentifier: nil
            )
        },
        clipboardSelectionCapture: { _ in
            fallbackSelection
        },
        bundleIdentifierReader: { _ in
            "ru.keepcoder.Telegram"
        },
        scheduler: ManualSelectionScheduler(),
        automaticSnapshotReader: { _ in outcome },
        frontmostPIDReader: { 123 }
    )
    var clearedCount = 0

    observer.onSelectionCleared = {
        clearedCount += 1
    }

    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    #expect(observer.currentSelection?.focusedElementID == 0)
    await poll(observer)
    outcome = .unavailable(focusedElementID: 42)
    await poll(observer)

    #expect(clearedCount == 0)
    #expect(observer.currentSelection?.text == "Clipboard fallback")
    #expect(observer.currentSelection?.appBundleIdentifier == "ru.keepcoder.Telegram")
    #expect(observer.currentSelection?.sourceAppPID == 123)

    // An authoritative event-driven clear still releases the hold.
    observer.processReadOutcomeForTesting(.snapshot(focusedMessage), pid: 123)
    #expect(clearedCount == 1)
    #expect(observer.currentSelection == nil)
    observer.stopPolling()
}

@Test
@MainActor
func testExplicitTelegramHoldClearsOnEventDrivenClear() async {
    var snapshot: AXTextSelectionSnapshot? = makeSelectionSnapshot(
        rawText: "Hello",
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot }
    )
    var clearedCount = 0

    observer.onSelectionCleared = {
        clearedCount += 1
    }

    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    snapshot = makeSelectionSnapshot(
        rawText: nil,
        selectedTextRangeEvidence: .empty,
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )
    observer.processReadOutcomeForTesting(.snapshot(snapshot!), pid: 123)

    #expect(clearedCount == 1)
    #expect(observer.currentSelection == nil)
}

@Test
@MainActor
func testExplicitTelegramHoldIgnoresUnavailableSample() async {
    var snapshot: AXTextSelectionSnapshot? = makeSelectionSnapshot(
        rawText: "Hello",
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot },
        frontmostPIDReader: { 123 }
    )
    var clearedCount = 0

    observer.onSelectionCleared = {
        clearedCount += 1
    }

    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    snapshot = makeSelectionSnapshot(
        rawText: nil,
        selectedTextRangeEvidence: .nonEmpty(
            text: nil,
            range: AXTextSelectionRange(location: 0, length: 5)
        ),
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )
    await poll(observer)

    #expect(clearedCount == 0)
    #expect(observer.currentSelection?.text == "Hello")
}

@Test
@MainActor
func testNewActiveSelectionReplacesTelegramHoldAndClearsNormally() async {
    var snapshot: AXTextSelectionSnapshot? = makeSelectionSnapshot(
        rawText: "Hello",
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot },
        frontmostPIDReader: { 123 }
    )
    var changedSelections: [String] = []
    var clearedCount = 0

    observer.onSelectionChanged = { result in
        changedSelections.append(result.selection.text)
    }
    observer.onSelectionCleared = {
        clearedCount += 1
    }

    _ = await observer.captureSelection(preferredSourceAppPID: 123)

    snapshot = makeSelectionSnapshot(
        rawText: "Updated",
        selectedTextRangeEvidence: makeRangeEvidence(
            text: "Updated",
            range: AXTextSelectionRange(location: 5, length: 7)
        ),
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )
    await poll(observer)

    snapshot = makeSelectionSnapshot(
        rawText: nil,
        selectedTextRangeEvidence: .empty,
        bundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXTextArea"
    )
    await poll(observer)

    #expect(changedSelections == ["Updated"])
    #expect(clearedCount == 1)
    #expect(observer.currentSelection == nil)
}

@Test
@MainActor
func testClearedReadOutcomeNotifiesOnlyWhenSelectionStateExists() {
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager()
    )
    let snapshot = makeSelectionSnapshot(
        rawText: "Hello",
        selectedTextRangeEvidence: makeRangeEvidence(
            text: "Hello",
            range: AXTextSelectionRange(location: 0, length: 5)
        )
    )
    var changedCount = 0
    var clearedCount = 0

    observer.onSelectionChanged = { _ in
        changedCount += 1
    }
    observer.onSelectionCleared = {
        clearedCount += 1
    }

    // No focused element and nothing captured: repeated polls stay silent.
    for _ in 0..<3 {
        observer.processReadOutcomeForTesting(.cleared, pid: 123)
    }
    #expect(clearedCount == 0)

    observer.processReadOutcomeForTesting(.snapshot(snapshot), pid: 123)
    for _ in 0..<3 {
        observer.processReadOutcomeForTesting(.cleared, pid: 123)
    }

    #expect(changedCount == 1)
    #expect(clearedCount == 1)
    #expect(observer.currentSelection == nil)

    // The clear still resets deduplication, so the same selection is rediscovered.
    observer.processReadOutcomeForTesting(.snapshot(snapshot), pid: 123)
    #expect(changedCount == 2)
}

@Test
@MainActor
func testClearedReadOutcomeNotifiesOnceForRetainedDeduplicationState() async {
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(),
        clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in
            makeSelectionSnapshot(
                rawText: "Hello",
                bundleIdentifier: "ru.keepcoder.Telegram",
                focusedElementRole: "AXTextArea"
            )
        }
    )
    var clearedCount = 0

    observer.onSelectionCleared = {
        clearedCount += 1
    }

    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    observer.dismissExplicitSelectionHold()
    #expect(observer.currentSelection == nil)
    #expect(clearedCount == 1)

    observer.processReadOutcomeForTesting(.cleared, pid: 123)
    observer.processReadOutcomeForTesting(.cleared, pid: 123)

    #expect(clearedCount == 2)
}

/// Drives one read through the production polling path, including its PID and focus guards.
@MainActor
private func poll(_ observer: TextSelectionObserver) async {
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
}

@MainActor
private func makeSelectionSnapshot(
    rawText: String?,
    selectedTextRangesEvidence: AXSelectionEvidence = .unsupported,
    selectedTextRangeEvidence: AXSelectionEvidence = .unsupported,
    selectedTextMarkerRangeEvidence: AXSelectionEvidence = .unsupported,
    elementID: Int = 11,
    sourceAppPID: pid_t? = 123,
    bundleIdentifier: String? = "com.apple.TextEdit",
    focusedElementRole: String? = "AXTextArea",
    focusedElementSubrole: String? = nil,
    isValueAttributeWritable: Bool = true,
    boundsMode: AccessibilityManager.SelectionBoundsCoordinateMode = .topLeftNeedsConversion
) -> AXTextSelectionSnapshot {
    AXTextSelectionSnapshot(
        rawSelectedTextEvidence: makeRawEvidence(text: rawText),
        selectedTextRangesEvidence: selectedTextRangesEvidence,
        selectedTextRangeEvidence: selectedTextRangeEvidence,
        selectedTextMarkerRangeEvidence: selectedTextMarkerRangeEvidence,
        cursorPosition: NSPoint(x: 120, y: 240),
        selectionBounds: NSRect(x: 100, y: 220, width: 80, height: 20),
        sourceAppPID: sourceAppPID,
        appBundleIdentifier: bundleIdentifier,
        focusedElementRole: focusedElementRole,
        focusedElementSubrole: focusedElementSubrole,
        isValueAttributeWritable: isValueAttributeWritable,
        boundsMode: boundsMode,
        focusedElementID: elementID
    )
}

private func makeRawEvidence(text: String?) -> AXSelectionEvidence {
    guard let text, !text.isEmpty else {
        return .empty
    }
    return .nonEmpty(text: text, range: nil)
}

private func makeRangeEvidence(text: String? = nil, range: AXTextSelectionRange?) -> AXSelectionEvidence {
    guard let range else {
        return .empty
    }
    guard range.length > 0 else {
        return .empty
    }
    return .nonEmpty(text: text, range: range)
}

private func makeMarkerEvidence(text: String?) -> AXSelectionEvidence {
    guard let text, !text.isEmpty else {
        return .empty
    }
    return .nonEmpty(text: text, range: nil)
}
