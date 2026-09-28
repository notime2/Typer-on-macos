// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Testing
@testable import Typer_On

@Test
@MainActor
func testTextReplacerFailsWhenFrontmostPIDNeverMatches() async {
    let pasteboard = NSPasteboard.withUniqueName()
    let clipboardManager = ClipboardManager(pasteboard: pasteboard)
    var sleepCalls: [Int] = []
    var pasteCalls = 0
    let replacer = TextReplacer(
        clipboardManager: clipboardManager,
        sourceAppActivator: { _ in true },
        frontmostPIDProvider: { ProcessInfo.processInfo.processIdentifier },
        sleepClosure: { milliseconds in
            sleepCalls.append(milliseconds)
        },
        pasteAction: {
            pasteCalls += 1
        }
    )
    let selection = TextSelection(
        text: "Hello",
        cursorPosition: .zero,
        sourceAppPID: 321
    )

    let outcome = await replacer.replace(with: "Updated", selection: selection)

    #expect(outcome == .failed)
    #expect(pasteCalls == 0)
    #expect(sleepCalls == Array(repeating: 20, count: 20))
}

@Test
@MainActor
func testTextReplacerReappliesSelectionRangeBeforeClipboardFallback() async {
    let pasteboard = NSPasteboard.withUniqueName()
    let clipboardManager = ClipboardManager(pasteboard: pasteboard)
    let accessibilityManager = AccessibilityManager()
    let selectionRange = AXTextSelectionRange(location: 2, length: 5)
    var events: [String] = []
    var preferredRanges: [AXTextSelectionRange?] = []

    let replacer = TextReplacer(
        clipboardManager: clipboardManager,
        sourceAppActivator: { _ in true },
        frontmostPIDProvider: { 321 },
        sleepClosure: { _ in },
        pasteAction: {
            events.append("paste")
        },
        selectionRangeRestorer: { range, pid, _ in
            events.append("restore:\(range.location):\(range.length):\(pid ?? -1)")
            return true
        },
        accessibilityReplaceHandler: { _, pid, _, preferredRange, _ in
            preferredRanges.append(preferredRange)
            events.append("replace:\(pid ?? -1)")
            return false
        },
        selectionSnapshotReader: { _ in replacementSnapshot(selectedTextRange: selectionRange) }
    )
    let selection = TextSelection(
        text: "Hello",
        cursorPosition: .zero,
        selectedTextRange: selectionRange,
        focusedElementID: 11,
        sourceAppPID: 321
    )

    let outcome = await replacer.replace(
        with: "Updated",
        selection: selection,
        using: accessibilityManager
    )

    #expect(outcome == .replaced(.clipboard))
    #expect(
        events == [
            "restore:2:5:321",
            "replace:321",
            "paste",
        ]
    )
    #expect(preferredRanges == [selectionRange])
}

@Test
@MainActor
func testTextReplacerReturnsClipboardOutcomeWhenFocusAndPasteSucceed() async {
    let pasteboard = NSPasteboard.withUniqueName()
    let clipboardManager = ClipboardManager(pasteboard: pasteboard)
    var pasteCalls = 0
    let replacer = TextReplacer(
        clipboardManager: clipboardManager,
        sourceAppActivator: { _ in true },
        frontmostPIDProvider: { 321 },
        sleepClosure: { _ in },
        pasteAction: {
            pasteCalls += 1
        },
        selectionSnapshotReader: { _ in replacementSnapshot() }
    )
    let selection = TextSelection(
        text: "Hello",
        cursorPosition: .zero,
        focusedElementID: 11,
        sourceAppPID: 321
    )

    let outcome = await replacer.replace(with: "Updated", selection: selection)

    #expect(outcome == .replaced(.clipboard))
    #expect(pasteCalls == 1)
}

@Test
@MainActor
func testTextReplacerSkipsAccessibilityReplaceForDiscontiguousSelection() async {
    let pasteboard = NSPasteboard.withUniqueName()
    let clipboardManager = ClipboardManager(pasteboard: pasteboard)
    let accessibilityManager = AccessibilityManager()
    var pasteCalls = 0
    var replaceCalls = 0
    let ranges = [AXTextSelectionRange(location: 0, length: 5), AXTextSelectionRange(location: 8, length: 5)]

    let replacer = TextReplacer(
        clipboardManager: clipboardManager,
        sourceAppActivator: { _ in true },
        frontmostPIDProvider: { 321 },
        sleepClosure: { _ in },
        pasteAction: {
            pasteCalls += 1
        },
        accessibilityReplaceHandler: { _, _, _, _, _ in
            replaceCalls += 1
            return true
        },
        selectionSnapshotReader: { _ in replacementSnapshot(text: "HelloWorld", selectedTextRanges: ranges) }
    )
    let selection = TextSelection(
        text: "HelloWorld",
        cursorPosition: .zero,
        selectedTextRange: nil,
        selectedTextRanges: ranges,
        focusedElementID: 11,
        sourceAppPID: 321,
        hasDiscontiguousSelection: true
    )

    let outcome = await replacer.replace(
        with: "Updated",
        selection: selection,
        using: accessibilityManager
    )

    #expect(outcome == .replaced(.clipboard))
    #expect(replaceCalls == 0)
    #expect(pasteCalls == 1)
}

@Test
@MainActor
func testTextReplacerFallsBackWhenSelectionRangeRestoreFails() async {
    let pasteboard = NSPasteboard.withUniqueName()
    let clipboardManager = ClipboardManager(pasteboard: pasteboard)
    let accessibilityManager = AccessibilityManager()
    let selectionRange = AXTextSelectionRange(location: 2, length: 5)
    var pasteCalls = 0
    var replaceCalls = 0

    let replacer = TextReplacer(
        clipboardManager: clipboardManager,
        sourceAppActivator: { _ in true },
        frontmostPIDProvider: { 321 },
        sleepClosure: { _ in },
        pasteAction: {
            pasteCalls += 1
        },
        selectionRangeRestorer: { _, _, _ in
            false
        },
        accessibilityReplaceHandler: { _, _, _, _, _ in
            replaceCalls += 1
            return true
        },
        selectionSnapshotReader: { _ in replacementSnapshot(selectedTextRange: selectionRange) }
    )
    let selection = TextSelection(
        text: "Hello",
        cursorPosition: .zero,
        selectedTextRange: selectionRange,
        focusedElementID: 11,
        sourceAppPID: 321
    )

    let outcome = await replacer.replace(
        with: "Updated",
        selection: selection,
        using: accessibilityManager
    )

    #expect(outcome == .replaced(.clipboard))
    #expect(replaceCalls == 0)
    #expect(pasteCalls == 1)
}

@Test
@MainActor
func testTextReplacerRejectsExternalAppBeforeActivation() async {
    var activationCalls = 0
    var pasteCalls = 0
    let replacer = TextReplacer(
        clipboardManager: ClipboardManager(pasteboard: .withUniqueName()),
        sourceAppActivator: { _ in activationCalls += 1; return true },
        frontmostPIDProvider: { 999 },
        sleepClosure: { _ in },
        pasteAction: { pasteCalls += 1 },
        selectionSnapshotReader: { _ in replacementSnapshot() }
    )

    let outcome = await replacer.replace(with: "Updated", selection: replacementSelection())

    #expect(outcome == .failed)
    #expect(activationCalls == 0)
    #expect(pasteCalls == 0)
}

@Test
@MainActor
func testTextReplacerRestoresSourceFocusFromOwnProcessingWindow() async {
    var frontmostPID = ProcessInfo.processInfo.processIdentifier
    var pasteCalls = 0
    let replacer = TextReplacer(
        clipboardManager: ClipboardManager(pasteboard: .withUniqueName()),
        sourceAppActivator: { _ in frontmostPID = 321; return true },
        frontmostPIDProvider: { frontmostPID },
        sleepClosure: { _ in },
        pasteAction: { pasteCalls += 1 },
        selectionSnapshotReader: { _ in replacementSnapshot() }
    )

    let outcome = await replacer.replace(with: "Updated", selection: replacementSelection())

    #expect(outcome == .replaced(.clipboard))
    #expect(pasteCalls == 1)
}

@Test
@MainActor
func testTextReplacerRejectsUnknownOrChangedTargetBeforeRestoringRange() async {
    let range = AXTextSelectionRange(location: 2, length: 5)
    let invalidSnapshots: [AXTextSelectionSnapshot?] = [
        nil,
        replacementSnapshot(text: "World", selectedTextRange: range),
        replacementSnapshot(selectedTextRange: AXTextSelectionRange(location: 8, length: 5)),
        replacementSnapshot(selectedTextRange: range, focusedElementID: 12),
        replacementSnapshot(selectedTextRange: range, sourceAppPID: 999),
        replacementSnapshot(selectedTextRange: range, rawText: "stale value"),
    ]
    for snapshot in invalidSnapshots {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original clipboard", forType: .string)
        var restoreCalls = 0
        var writeCalls = 0
        let replacer = TextReplacer(
            clipboardManager: ClipboardManager(pasteboard: pasteboard),
            sourceAppActivator: { _ in true },
            frontmostPIDProvider: { 321 },
            sleepClosure: { _ in },
            pasteAction: { writeCalls += 1 },
            selectionRangeRestorer: { _, _, _ in restoreCalls += 1; return true },
            accessibilityReplaceHandler: { _, _, _, _, _ in writeCalls += 1; return true },
            selectionSnapshotReader: { _ in snapshot }
        )

        let outcome = await replacer.replace(
            with: "Updated",
            selection: replacementSelection(selectedTextRange: range),
            using: AccessibilityManager()
        )

        #expect(outcome == .failed)
        #expect(restoreCalls == 0)
        #expect(writeCalls == 0)
        #expect(pasteboard.string(forType: .string) == "original clipboard")
    }
}

@Test
@MainActor
func testTextReplacerRevalidatesTargetAfterClipboardSettle() async {
    let invalidSnapshots: [AXTextSelectionSnapshot?] = [
        nil,
        replacementSnapshot(text: "World"),
        replacementSnapshot(focusedElementID: 12),
    ]
    for changedSnapshot in invalidSnapshots {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original clipboard", forType: .string)
        var snapshot: AXTextSelectionSnapshot? = replacementSnapshot()
        var pasteCalls = 0
        var settleCalls = 0
        let replacer = TextReplacer(
            clipboardManager: ClipboardManager(pasteboard: pasteboard),
            sourceAppActivator: { _ in true },
            frontmostPIDProvider: { 321 },
            sleepClosure: { milliseconds in
                if milliseconds == 80 {
                    settleCalls += 1
                    snapshot = changedSnapshot
                }
            },
            pasteAction: { pasteCalls += 1 },
            selectionSnapshotReader: { _ in snapshot }
        )

        let outcome = await replacer.replace(with: "Updated", selection: replacementSelection())

        #expect(outcome == .failed)
        #expect(settleCalls == 1)
        #expect(pasteCalls == 0)
        #expect(pasteboard.string(forType: .string) == "original clipboard")
    }
}

@Test
@MainActor
func testTextReplacerNeverPastesIntoAppFocusedDuringClipboardSettle() async {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.setString("original clipboard", forType: .string)
    var focusedPID: pid_t = 321
    var pasteCalls = 0
    var settleCalls = 0
    let replacer = TextReplacer(
        clipboardManager: ClipboardManager(pasteboard: pasteboard),
        sourceAppActivator: { _ in true },
        frontmostPIDProvider: { focusedPID },
        sleepClosure: { milliseconds in
            if milliseconds == 80 {
                settleCalls += 1
                focusedPID = 999
            }
        },
        pasteAction: { pasteCalls += 1 },
        selectionSnapshotReader: { _ in replacementSnapshot() }
    )

    let outcome = await replacer.replace(with: "Updated", selection: replacementSelection())

    #expect(outcome == .failed)
    #expect(settleCalls == 1)
    #expect(pasteCalls == 0)
    #expect(pasteboard.string(forType: .string) == "original clipboard")
}

@Test
@MainActor
func testTextReplacerPreservesExternalClipboardChangesBeforeAndAfterPaste() async {
    for changeBeforePaste in [true, false] {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original clipboard", forType: .string)
        var pasteCalls = 0
        let replacer = TextReplacer(
            clipboardManager: ClipboardManager(pasteboard: pasteboard),
            sourceAppActivator: { _ in true },
            frontmostPIDProvider: { 321 },
            sleepClosure: { milliseconds in
                if milliseconds == (changeBeforePaste ? 80 : 200) {
                    pasteboard.clearContents()
                    pasteboard.setString("externally copied", forType: .string)
                }
            },
            pasteAction: { pasteCalls += 1 },
            selectionSnapshotReader: { _ in replacementSnapshot() }
        )

        let outcome = await replacer.replace(with: "Updated", selection: replacementSelection())

        #expect(outcome == (changeBeforePaste ? .failed : .replaced(.clipboard)))
        #expect(pasteCalls == (changeBeforePaste ? 0 : 1))
        #expect(pasteboard.string(forType: .string) == "externally copied")
    }
}

@Test
@MainActor
func testTextReplacerCancellationDuringClipboardSettleDoesNotPaste() async {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.setString("original clipboard", forType: .string)
    var pasteCalls = 0
    let replacer = TextReplacer(
        clipboardManager: ClipboardManager(pasteboard: pasteboard),
        sourceAppActivator: { _ in true },
        frontmostPIDProvider: { 321 },
        sleepClosure: { milliseconds in
            if milliseconds == 80 { withUnsafeCurrentTask { $0?.cancel() } }
        },
        pasteAction: { pasteCalls += 1 },
        selectionSnapshotReader: { _ in replacementSnapshot() }
    )
    let task = Task { await replacer.replace(with: "Updated", selection: replacementSelection()) }

    let outcome = await task.value

    #expect(outcome == .failed)
    #expect(pasteCalls == 0)
    #expect(pasteboard.string(forType: .string) == "original clipboard")
}

@Test
@MainActor
func testTextReplacerRejectsOverlappingReplacementWithoutOverwritingClipboardBackup() async {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.setString("original clipboard", forType: .string)
    var pasteCalls = 0
    var overlappingOutcome: ReplaceOutcome?
    var replacer: TextReplacer!
    replacer = TextReplacer(
        clipboardManager: ClipboardManager(pasteboard: pasteboard),
        sourceAppActivator: { _ in true },
        frontmostPIDProvider: { 321 },
        sleepClosure: { milliseconds in
            if milliseconds == 80 {
                overlappingOutcome = await replacer.replace(with: "Repeated", selection: replacementSelection())
            }
        },
        pasteAction: { pasteCalls += 1 },
        selectionSnapshotReader: { _ in replacementSnapshot() }
    )

    let outcome = await replacer.replace(with: "Updated", selection: replacementSelection())

    #expect(outcome == .replaced(.clipboard))
    #expect(overlappingOutcome == .failed)
    #expect(pasteCalls == 1)
    #expect(pasteboard.string(forType: .string) == "original clipboard")
}

@Test
@MainActor
func testTextReplacerRevalidatesAfterRangeRestoreBeforeDirectWrite() async {
    let range = AXTextSelectionRange(location: 2, length: 5)
    for changeTarget in [false, true] {
        var focusedElementID = 11
        var directWrites = 0
        var pasteCalls = 0
        let replacer = TextReplacer(
            clipboardManager: ClipboardManager(pasteboard: .withUniqueName()),
            sourceAppActivator: { _ in true },
            frontmostPIDProvider: { 321 },
            sleepClosure: { _ in },
            pasteAction: { pasteCalls += 1 },
            selectionRangeRestorer: { _, _, _ in
                if changeTarget { focusedElementID = 12 }
                return true
            },
            accessibilityReplaceHandler: { _, _, _, _, _ in directWrites += 1; return true },
            selectionSnapshotReader: { _ in
                replacementSnapshot(selectedTextRange: range, focusedElementID: focusedElementID)
            }
        )

        let outcome = await replacer.replace(
            with: "Updated",
            selection: replacementSelection(selectedTextRange: range),
            using: AccessibilityManager()
        )

        #expect(outcome == (changeTarget ? .failed : .replaced(.accessibility)))
        #expect(directWrites == (changeTarget ? 0 : 1))
        #expect(pasteCalls == 0)
    }
}

@Test
@MainActor
func testReplacementContextRejectsMissingIdentityAndChangedDiscontiguousRanges() {
    let unknownIdentity = TextSelection(text: "Hello", cursorPosition: .zero, sourceAppPID: 321)
    #expect(AccessibilityManager.isReplacementContextValid(
        selection: unknownIdentity,
        snapshot: replacementSnapshot()
    ) == false)

    let ranges = [AXTextSelectionRange(location: 0, length: 5), AXTextSelectionRange(location: 8, length: 5)]
    let selection = TextSelection(
        text: "HelloWorld",
        cursorPosition: .zero,
        selectedTextRanges: ranges,
        focusedElementID: 11,
        sourceAppPID: 321,
        hasDiscontiguousSelection: true
    )
    let changedRanges = [ranges[0], AXTextSelectionRange(location: 16, length: 5)]
    #expect(AccessibilityManager.isReplacementContextValid(
        selection: selection,
        snapshot: replacementSnapshot(text: "HelloWorld", selectedTextRanges: changedRanges)
    ) == false)
}

@Test
@MainActor
func testTextReplacerUsesClipboardOnlyForExactAyuGramBundleToPreserveUndo() async {
    let range = AXTextSelectionRange(location: 2, length: 5)
    let cases: [(bundleIdentifier: String, prefersClipboard: Bool)] = [
        ("one.ayugram.AyuGramDesktop", true),
        ("ONE.AYUGRAM.AYUGRAMDESKTOP", true),
        ("one.ayugram.AyuGramDesktop.beta", false),
        ("ru.keepcoder.Telegram", false),
        ("com.apple.TextEdit", false),
    ]
    for testCase in cases {
        var directWrites = 0
        var rangeRestores = 0
        var pasteCalls = 0
        var editorValue = "xxHello tail"
        let replacer = TextReplacer(
            clipboardManager: ClipboardManager(pasteboard: .withUniqueName()),
            sourceAppActivator: { _ in true },
            frontmostPIDProvider: { 321 },
            sleepClosure: { _ in },
            pasteAction: { pasteCalls += 1; editorValue = "xxUpdated tail" },
            selectionRangeRestorer: { _, _, _ in rangeRestores += 1; return true },
            accessibilityReplaceHandler: { _, _, _, _, _ in directWrites += 1; return true },
            selectionSnapshotReader: { _ in replacementSnapshot(selectedTextRange: range) },
            editableValueReader: { _, _ in editorValue }
        )
        let selection = TextSelection(
            text: "Hello",
            cursorPosition: .zero,
            selectedTextRange: range,
            focusedElementID: 11,
            sourceAppPID: 321,
            appBundleIdentifier: testCase.bundleIdentifier
        )

        let outcome = await replacer.replace(with: "Updated", selection: selection, using: AccessibilityManager())

        #expect(outcome == .replaced(testCase.prefersClipboard ? .clipboard : .accessibility))
        #expect(directWrites == (testCase.prefersClipboard ? 0 : 1))
        #expect(rangeRestores == (testCase.prefersClipboard ? 0 : 1))
        #expect(pasteCalls == (testCase.prefersClipboard ? 1 : 0))
    }
}

@Test
@MainActor
func testTextReplacerAyuGramClipboardPreferenceStillRejectsChangedTarget() async {
    let range = AXTextSelectionRange(location: 2, length: 5)
    for changeDuringWait in [false, true] {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original clipboard", forType: .string)
        var focusedElementID = changeDuringWait ? 11 : 12
        var writeCalls = 0
        let replacer = TextReplacer(
            clipboardManager: ClipboardManager(pasteboard: pasteboard),
            sourceAppActivator: { _ in true },
            frontmostPIDProvider: { 321 },
            sleepClosure: { milliseconds in
                if milliseconds == 80 { focusedElementID = 12 }
            },
            pasteAction: { writeCalls += 1 },
            accessibilityReplaceHandler: { _, _, _, _, _ in writeCalls += 1; return true },
            selectionSnapshotReader: { _ in
                replacementSnapshot(selectedTextRange: range, focusedElementID: focusedElementID)
            },
            editableValueReader: { _, _ in "xxHello tail" }
        )
        let selection = TextSelection(
            text: "Hello",
            cursorPosition: .zero,
            selectedTextRange: range,
            focusedElementID: 11,
            sourceAppPID: 321,
            appBundleIdentifier: "one.ayugram.AyuGramDesktop"
        )

        let outcome = await replacer.replace(with: "Updated", selection: selection, using: AccessibilityManager())

        #expect(outcome == .failed)
        #expect(writeCalls == 0)
        #expect(pasteboard.string(forType: .string) == "original clipboard")
    }
}

@Test
@MainActor
func testReplacementContextRejectsConflictingNumericRangesWithIdenticalText() {
    let capturedRange = AXTextSelectionRange(location: 2, length: 5)
    let otherRange = AXTextSelectionRange(location: 8, length: 5)
    let selection = replacementSelection(selectedTextRange: capturedRange, selectedTextRanges: [capturedRange])
    let conflicting = replacementSnapshot(selectedTextRange: otherRange, selectedTextRanges: [capturedRange])

    // Priority resolution still returns the captured range and text; the other evidence must reject it.
    #expect(conflicting.selectedTextRange == capturedRange)
    #expect(conflicting.selectedText == selection.text)
    #expect(AccessibilityManager.isReplacementContextValid(selection: selection, snapshot: conflicting) == false)
    #expect(AccessibilityManager.isReplacementContextValid(
        selection: selection,
        snapshot: replacementSnapshot(selectedTextRange: capturedRange, selectedTextRanges: [capturedRange])
    ))
    #expect(AccessibilityManager.isReplacementContextValid(
        selection: selection,
        snapshot: replacementSnapshot(selectedTextRange: capturedRange)
    ))
}

@Test
@MainActor
func testTextReplacerRejectsContradictoryRangesBeforeClipboardWrite() async {
    let capturedRange = AXTextSelectionRange(location: 2, length: 5)
    let otherRange = AXTextSelectionRange(location: 8, length: 5)
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.setString("original clipboard", forType: .string)
    var pasteCalls = 0
    var sleepCalls = 0
    let replacer = TextReplacer(
        clipboardManager: ClipboardManager(pasteboard: pasteboard),
        sourceAppActivator: { _ in true },
        frontmostPIDProvider: { 321 },
        sleepClosure: { _ in sleepCalls += 1 },
        pasteAction: { pasteCalls += 1 },
        selectionSnapshotReader: { _ in
            replacementSnapshot(selectedTextRange: otherRange, selectedTextRanges: [capturedRange])
        }
    )

    let outcome = await replacer.replace(
        with: "Updated",
        selection: replacementSelection(selectedTextRange: capturedRange, selectedTextRanges: [capturedRange])
    )

    #expect(outcome == .failed)
    #expect(pasteCalls == 0)
    #expect(sleepCalls == 0)
    #expect(pasteboard.string(forType: .string) == "original clipboard")
}

@Test
@MainActor
func testTextReplacerRechecksContradictoryRangesAfterClipboardSettle() async {
    let capturedRange = AXTextSelectionRange(location: 2, length: 5)
    let otherRange = AXTextSelectionRange(location: 8, length: 5)
    for introduceConflict in [true, false] {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original clipboard", forType: .string)
        var singleRange = capturedRange
        var pasteCalls = 0
        var settleCalls = 0
        let replacer = TextReplacer(
            clipboardManager: ClipboardManager(pasteboard: pasteboard),
            sourceAppActivator: { _ in true },
            frontmostPIDProvider: { 321 },
            sleepClosure: { milliseconds in
                if milliseconds == 80 {
                    settleCalls += 1
                    if introduceConflict { singleRange = otherRange }
                }
            },
            pasteAction: { pasteCalls += 1 },
            selectionSnapshotReader: { _ in
                replacementSnapshot(selectedTextRange: singleRange, selectedTextRanges: [capturedRange])
            }
        )

        let outcome = await replacer.replace(
            with: "Updated",
            selection: replacementSelection(selectedTextRange: capturedRange, selectedTextRanges: [capturedRange])
        )

        #expect(outcome == (introduceConflict ? .failed : .replaced(.clipboard)))
        #expect(pasteCalls == (introduceConflict ? 0 : 1))
        #expect(settleCalls == 1)
        #expect(pasteboard.string(forType: .string) == "original clipboard")
    }
}

@MainActor
private func replacementSelection(
    selectedTextRange: AXTextSelectionRange? = nil,
    selectedTextRanges: [AXTextSelectionRange] = [],
    appBundleIdentifier: String? = nil
) -> TextSelection {
    TextSelection(
        text: "Hello",
        cursorPosition: .zero,
        selectedTextRange: selectedTextRange,
        selectedTextRanges: selectedTextRanges,
        focusedElementID: 11,
        sourceAppPID: 321,
        appBundleIdentifier: appBundleIdentifier
    )
}

@Test
@MainActor
func testAyuGramClipboardPreflightUsesFullResultUTF16Limit() async {
    let range = AXTextSelectionRange(location: 0, length: 5)
    let cases: [(text: String, suffix: String, allowed: Bool)] = [
        ("Updated", " tail", true),
        (String(repeating: "a", count: 32767), "", true),
        (String(repeating: "a", count: 32768), "", false),
        (String(repeating: "a", count: 32761), "suffix", true),
        (String(repeating: "a", count: 32762), "suffix", false),
        (String(repeating: "a", count: 1000), String(repeating: "s", count: 32000), false),
        (String(repeating: "😀", count: 16383) + "a", "", true),
        (String(repeating: "😀", count: 16384), "", false),
    ]
    for testCase in cases {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original clipboard", forType: .string)
        let originalChangeCount = pasteboard.changeCount
        var editorValue = "Hello" + testCase.suffix
        let expectedValue = testCase.text + testCase.suffix
        var pasteCalls = 0
        let replacer = TextReplacer(
            clipboardManager: ClipboardManager(pasteboard: pasteboard),
            sourceAppActivator: { _ in true },
            frontmostPIDProvider: { 321 },
            sleepClosure: { _ in },
            pasteAction: { pasteCalls += 1; editorValue = expectedValue },
            selectionSnapshotReader: { _ in replacementSnapshot(selectedTextRange: range) },
            editableValueReader: { pid, elementID in
                #expect(pid == 321 && elementID == 11)
                return editorValue
            }
        )

        let outcome = await replacer.replace(
            with: testCase.text,
            selection: replacementSelection(selectedTextRange: range, appBundleIdentifier: "one.ayugram.AyuGramDesktop")
        )

        #expect(outcome == (testCase.allowed ? .replaced(.clipboard) : .failed))
        #expect(pasteCalls == (testCase.allowed ? 1 : 0))
        #expect(pasteboard.string(forType: .string) == "original clipboard")
        if !testCase.allowed {
            #expect(pasteboard.changeCount == originalChangeCount)
            #expect(editorValue == "Hello" + testCase.suffix)
        }
    }
}

@Test
@MainActor
func testAyuGramClipboardPreflightRequiresReadableMatchingEditorValue() async {
    let range = AXTextSelectionRange(location: 0, length: 5)
    let values: [String?] = [nil, "Other tail"]
    for value in values {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original clipboard", forType: .string)
        let originalChangeCount = pasteboard.changeCount
        var pasteCalls = 0
        let replacer = TextReplacer(
            clipboardManager: ClipboardManager(pasteboard: pasteboard),
            sourceAppActivator: { _ in true },
            frontmostPIDProvider: { 321 },
            sleepClosure: { _ in },
            pasteAction: { pasteCalls += 1 },
            selectionSnapshotReader: { _ in replacementSnapshot(selectedTextRange: range) },
            editableValueReader: { _, _ in value }
        )

        let outcome = await replacer.replace(
            with: "Updated",
            selection: replacementSelection(selectedTextRange: range, appBundleIdentifier: "one.ayugram.AyuGramDesktop")
        )

        #expect(outcome == .failed)
        #expect(pasteCalls == 0)
        #expect(pasteboard.changeCount == originalChangeCount)
    }
}

@Test
@MainActor
func testAyuGramClipboardRejectsChangedUnselectedSuffixBeforePaste() async {
    let range = AXTextSelectionRange(location: 0, length: 5)
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.setString("original clipboard", forType: .string)
    var editorValue = "Hello tail"
    var pasteCalls = 0
    let replacer = TextReplacer(
        clipboardManager: ClipboardManager(pasteboard: pasteboard),
        sourceAppActivator: { _ in true },
        frontmostPIDProvider: { 321 },
        sleepClosure: { milliseconds in
            if milliseconds == 80 { editorValue = "Hello changed tail" }
        },
        pasteAction: { pasteCalls += 1 },
        selectionSnapshotReader: { _ in replacementSnapshot(selectedTextRange: range) },
        editableValueReader: { _, _ in editorValue }
    )

    let outcome = await replacer.replace(
        with: "Updated",
        selection: replacementSelection(selectedTextRange: range, appBundleIdentifier: "one.ayugram.AyuGramDesktop")
    )

    #expect(outcome == .failed)
    #expect(pasteCalls == 0)
    #expect(editorValue == "Hello changed tail")
    #expect(pasteboard.string(forType: .string) == "original clipboard")
}

@Test
@MainActor
func testAyuGramClipboardReportsSuccessOnlyForVerifiedResult() async {
    let range = AXTextSelectionRange(location: 0, length: 5)
    let cases: [(value: String?, verified: Bool)] = [
        (nil, false),
        ("", false),
        ("Hello tail\n", false),
        ("Updated  tail\n", false),
        ("Updated tail", false),
        ("Updated tail\n", true),
        ("Updated tail\r\n", true),
        ("Updated tail\r", true),
        ("Updated tail\u{2028}", true),
        ("Updated tail\u{2029}", true),
    ]
    for testCase in cases {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("original clipboard", forType: .string)
        var editorValue: String? = "Hello tail\n"
        var pasteCalls = 0
        let replacer = TextReplacer(
            clipboardManager: ClipboardManager(pasteboard: pasteboard),
            sourceAppActivator: { _ in true },
            frontmostPIDProvider: { 321 },
            sleepClosure: { _ in },
            pasteAction: { pasteCalls += 1; editorValue = testCase.value },
            selectionSnapshotReader: { _ in replacementSnapshot(selectedTextRange: range) },
            editableValueReader: { _, _ in editorValue }
        )

        let outcome = await replacer.replace(
            with: "Updated",
            selection: replacementSelection(selectedTextRange: range, appBundleIdentifier: "one.ayugram.AyuGramDesktop")
        )

        #expect(outcome == (testCase.verified ? .replaced(.clipboard) : .failed))
        #expect(pasteCalls == 1)
        #expect(editorValue == testCase.value)
        #expect(pasteboard.string(forType: .string) == "original clipboard")
    }
}

@Test
@MainActor
func testOtherAppsClipboardDoesNotApplyAyuGramSpecificValueOrLengthPolicy() async {
    let range = AXTextSelectionRange(location: 0, length: 5)
    var pasteCalls = 0
    var valueReadCalls = 0
    let replacer = TextReplacer(
        clipboardManager: ClipboardManager(pasteboard: .withUniqueName()),
        sourceAppActivator: { _ in true },
        frontmostPIDProvider: { 321 },
        sleepClosure: { _ in },
        pasteAction: { pasteCalls += 1 },
        selectionSnapshotReader: { _ in replacementSnapshot(selectedTextRange: range) },
        editableValueReader: { _, _ in valueReadCalls += 1; return nil }
    )

    let outcome = await replacer.replace(
        with: String(repeating: "a", count: 32768),
        selection: replacementSelection(selectedTextRange: range, appBundleIdentifier: "ru.keepcoder.Telegram")
    )

    #expect(outcome == .replaced(.clipboard))
    #expect(pasteCalls == 1)
    #expect(valueReadCalls == 0)
}

@MainActor
private func replacementSnapshot(
    text: String = "Hello",
    selectedTextRange: AXTextSelectionRange? = nil,
    selectedTextRanges: [AXTextSelectionRange] = [],
    focusedElementID: Int = 11,
    sourceAppPID: pid_t = 321,
    rawText: String? = nil
) -> AXTextSelectionSnapshot {
    AXTextSelectionSnapshot(
        rawSelectedTextEvidence: .nonEmpty(text: rawText ?? text, range: nil),
        selectedTextRangesEvidence: selectedTextRanges.isEmpty ? .unsupported : .nonEmpty(text: text, range: nil),
        selectedTextRangeEvidence: selectedTextRange.map { .nonEmpty(text: text, range: $0) } ?? .unsupported,
        selectedTextMarkerRangeEvidence: .unsupported,
        selectedTextRanges: selectedTextRanges,
        cursorPosition: .zero,
        selectionBounds: nil,
        sourceAppPID: sourceAppPID,
        appBundleIdentifier: "test.editor",
        focusedElementRole: "AXTextArea",
        focusedElementSubrole: nil,
        isValueAttributeWritable: false,
        boundsMode: .alreadyAppKit,
        focusedElementID: focusedElementID
    )
}
