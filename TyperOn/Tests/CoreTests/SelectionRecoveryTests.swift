// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import ApplicationServices
import Carbon
import Testing
@testable import Typer_On

@MainActor
final class ManualSelectionScheduler: SelectionScheduler {
    private final class Work: SelectionScheduledWork {
        let deadline: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }
        func cancel() { cancelled = true }
    }
    private var time: TimeInterval = 0
    private var work: [Work] = []
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any SelectionScheduledWork {
        let item = Work(deadline: time + delay, action: action)
        work.append(item)
        return item
    }
    func advance(by duration: TimeInterval) {
        let end = time + duration
        while let next = work.filter({ !$0.cancelled && $0.deadline <= end + 0.000001 })
            .min(by: { $0.deadline < $1.deadline }) {
            time = next.deadline
            next.cancelled = true
            next.action()
        }
        time = end
        work.removeAll { $0.cancelled }
    }
}

@MainActor
private func recoverySnapshot(text: String = "Hello", pid: pid_t = 123, focus: Int = 11,
                              ranges: AXSelectionEvidence = .unsupported,
                              single: AXSelectionEvidence? = nil,
                              marker: AXSelectionEvidence = .unsupported) -> AXTextSelectionSnapshot {
    AXTextSelectionSnapshot(
        rawSelectedTextEvidence: .unsupported,
        selectedTextRangesEvidence: ranges,
        selectedTextRangeEvidence: single ?? .nonEmpty(text: text, range: AXTextSelectionRange(location: 0, length: text.utf16.count)),
        selectedTextMarkerRangeEvidence: marker,
        cursorPosition: .zero, selectionBounds: nil, sourceAppPID: pid,
        appBundleIdentifier: "com.apple.TextEdit", focusedElementRole: "AXTextArea",
        focusedElementSubrole: nil, isValueAttributeWritable: true,
        boundsMode: .topLeftNeedsConversion, focusedElementID: focus
    )
}

@Test @MainActor
func testUnavailableSelectionRetriesAt100And250MillisecondsAndExpiresAt500() async {
    let scheduler = ManualSelectionScheduler()
    var reads = 0
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        scheduler: scheduler, automaticSnapshotReader: { _ in
            reads += 1
            return .unavailable(focusedElementID: 11)
        }, frontmostPIDReader: { 123 }
    )
    observer.processReadOutcomeForTesting(.snapshot(recoverySnapshot()), pid: 123)
    observer.processReadOutcomeForTesting(.unavailable(focusedElementID: 11), pid: 123)
    scheduler.advance(by: 0.099)
    #expect(reads == 0)
    scheduler.advance(by: 0.001)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(reads == 1)
    scheduler.advance(by: 0.15)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(reads == 2)
    observer.processReadOutcomeForTesting(.unavailable(focusedElementID: 11), pid: 123)
    scheduler.advance(by: 0.249)
    #expect(observer.currentSelection != nil)
    scheduler.advance(by: 0.001)
    #expect(observer.currentSelection == nil)
}

@MainActor
private func telegramHoldSnapshot() -> AXTextSelectionSnapshot {
    AXTextSelectionSnapshot(
        rawSelectedTextEvidence: .nonEmpty(text: "Held message", range: nil),
        selectedTextRangesEvidence: .unsupported, selectedTextRangeEvidence: .unsupported,
        selectedTextMarkerRangeEvidence: .unsupported, cursorPosition: .zero, selectionBounds: nil,
        sourceAppPID: 123, appBundleIdentifier: "ru.keepcoder.Telegram",
        focusedElementRole: "AXStaticText", focusedElementSubrole: nil, isValueAttributeWritable: false,
        boundsMode: .topLeftNeedsConversion, focusedElementID: 11
    )
}

@MainActor
private func ayuMessageSnapshot(
    pid: pid_t = 123, focus: Int = 11, bundle: String = "one.ayugram.AyuGramDesktop",
    role: String = "AXStaticText", writable: Bool = false, rawText: String? = nil
) -> AXTextSelectionSnapshot {
    AXTextSelectionSnapshot(
        rawSelectedTextEvidence: rawText.map { .nonEmpty(text: $0, range: nil) } ?? .unsupported,
        selectedTextRangesEvidence: .unsupported, selectedTextRangeEvidence: rawText == nil ? .empty : .unsupported,
        selectedTextMarkerRangeEvidence: .unsupported, cursorPosition: .zero, selectionBounds: nil,
        sourceAppPID: pid, appBundleIdentifier: bundle, focusedElementRole: role,
        focusedElementSubrole: nil, isValueAttributeWritable: writable,
        boundsMode: .topLeftNeedsConversion, focusedElementID: focus
    )
}

@Test @MainActor
func testAyuReadOnlyClipboardCaptureRetainsIdentityThroughRealPollingAndBoundedRecovery() async {
    let scheduler = ManualSelectionScheduler()
    let snapshot = ayuMessageSnapshot()
    var outcome: AXSelectionReadOutcome = .snapshot(snapshot)
    var reads = 0
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot },
        clipboardSelectionCapture: { _ in TextSelection(text: "Synthetic message", cursorPosition: .zero, sourceAppPID: 123) },
        scheduler: scheduler, automaticSnapshotReader: { _ in reads += 1; return outcome },
        frontmostPIDReader: { 123 }
    )
    var clears = 0
    observer.onSelectionCleared = { clears += 1 }
    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    #expect(observer.currentSelection?.focusedElementID == 11)
    #expect(observer.currentCaptureResult?.focusedElementID == 11)
    #expect(observer.currentSelection?.selectedTextRange == nil)
    #expect(observer.currentSelection?.selectedTextRanges.isEmpty == true)
    #expect(observer.currentCaptureResult?.allEvidenceStates.range == .unsupported)
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    #expect(observer.currentSelection?.text == "Synthetic message")
    outcome = .unavailable(focusedElementID: 11)
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    scheduler.advance(by: 0.1)
    await observer.waitForPendingSelectionReadForTesting()
    scheduler.advance(by: 0.15)
    await observer.waitForPendingSelectionReadForTesting()
    scheduler.advance(by: 0.75)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(observer.currentSelection?.text == "Synthetic message")
    #expect(reads == 4)
    #expect(clears == 0)
    observer.stopPolling()
}

@Test @MainActor
func testAyuReadOnlyHoldTreatsMixedRecoveryEmptyAsPollingUntilRealEventClear() async {
    let scheduler = ManualSelectionScheduler()
    let snapshot = ayuMessageSnapshot()
    var outcome: AXSelectionReadOutcome = .unavailable(focusedElementID: 11)
    var reads = 0
    var clears = 0
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot },
        clipboardSelectionCapture: { _ in TextSelection(text: "Synthetic message", cursorPosition: .zero, sourceAppPID: 123) },
        scheduler: scheduler, automaticSnapshotReader: { _ in reads += 1; return outcome }, frontmostPIDReader: { 123 }
    )
    observer.onSelectionCleared = { clears += 1 }
    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    #expect(reads == 1)

    outcome = .snapshot(snapshot)
    scheduler.advance(by: 0.1)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(observer.currentSelection?.text == "Synthetic message")
    #expect(clears == 0)
    outcome = .unavailable(focusedElementID: 11)
    scheduler.advance(by: 0.15)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(reads == 3)
    outcome = .snapshot(snapshot)
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    scheduler.advance(by: 0.25)
    #expect(observer.currentSelection?.text == "Synthetic message")
    #expect(clears == 0)

    outcome = .unavailable(focusedElementID: 11)
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    let readsAfterExpiry = reads
    scheduler.advance(by: 1)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(reads == readsAfterExpiry)
    #expect(observer.currentSelection?.text == "Synthetic message")

    outcome = .snapshot(snapshot)
    observer.checkSelectionFromEvent(frontmostPID: 123)
    scheduler.advance(by: 0.05)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(observer.currentSelection == nil)
    #expect(clears == 1)
    observer.stopPolling()
}

@Test @MainActor
func testAyuReadOnlyEventOriginRecoveryClearsOnEmptySnapshot() async {
    let scheduler = ManualSelectionScheduler()
    let snapshot = ayuMessageSnapshot()
    var outcome: AXSelectionReadOutcome = .unavailable(focusedElementID: 11)
    var clears = 0
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot },
        clipboardSelectionCapture: { _ in TextSelection(text: "Synthetic message", cursorPosition: .zero, sourceAppPID: 123) },
        scheduler: scheduler, automaticSnapshotReader: { _ in outcome }, frontmostPIDReader: { 123 }
    )
    observer.onSelectionCleared = { clears += 1 }
    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    observer.checkSelectionFromEvent(frontmostPID: 123)
    scheduler.advance(by: 0.05)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(observer.currentSelection != nil)
    outcome = .snapshot(snapshot)
    scheduler.advance(by: 0.1)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(observer.currentSelection == nil)
    #expect(clears == 1)
    scheduler.advance(by: 0.5)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(observer.currentSelection == nil)
    observer.stopPolling()
}

@Test @MainActor
func testAyuRealEventPromotesPendingPollingRecoveryWithoutStartingAnotherWindow() async {
    let scheduler = ManualSelectionScheduler()
    let snapshot = ayuMessageSnapshot()
    var outcome: AXSelectionReadOutcome = .unavailable(focusedElementID: 11)
    var reads = 0
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot },
        clipboardSelectionCapture: { _ in TextSelection(text: "Synthetic message", cursorPosition: .zero, sourceAppPID: 123) },
        scheduler: scheduler, automaticSnapshotReader: { _ in reads += 1; return outcome }, frontmostPIDReader: { 123 }
    )
    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    outcome = .snapshot(snapshot)
    scheduler.advance(by: 0.1)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(observer.currentSelection?.text == "Synthetic message")
    outcome = .unavailable(focusedElementID: 11)
    observer.checkSelectionFromEvent(frontmostPID: 123)
    scheduler.advance(by: 0.05)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(reads == 3)
    outcome = .snapshot(snapshot)
    scheduler.advance(by: 0.1)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(reads == 4)
    #expect(observer.currentSelection == nil)
    observer.stopPolling()
}

@Test @MainActor
func testAyuEventAfterLastRecoveryRetryDoesNotExtendOriginalDeadline() async {
    let scheduler = ManualSelectionScheduler()
    let snapshot = ayuMessageSnapshot()
    var reads = 0
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot },
        clipboardSelectionCapture: { _ in TextSelection(text: "Synthetic message", cursorPosition: .zero, sourceAppPID: 123) },
        scheduler: scheduler, automaticSnapshotReader: { _ in reads += 1; return .unavailable(focusedElementID: 11) },
        frontmostPIDReader: { 123 }
    )
    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    scheduler.advance(by: 0.1)
    await observer.waitForPendingSelectionReadForTesting()
    scheduler.advance(by: 0.15)
    await observer.waitForPendingSelectionReadForTesting()
    observer.checkSelectionFromEvent(frontmostPID: 123)
    scheduler.advance(by: 0.05)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(reads == 4)
    scheduler.advance(by: 0.2)
    #expect(observer.currentSelection?.text == "Synthetic message")
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    scheduler.advance(by: 1)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(reads == 5)
    #expect(observer.currentSelection?.text == "Synthetic message")
    observer.stopPolling()
}

@Test @MainActor
func testWritableTelegramHoldKeepsOriginalEventRecoveryAfterPollingFailure() async {
    let scheduler = ManualSelectionScheduler()
    let selected = AXTextSelectionSnapshot(
        rawSelectedTextEvidence: .nonEmpty(text: "Hello", range: nil), selectedTextRangesEvidence: .unsupported,
        selectedTextRangeEvidence: .nonEmpty(text: "Hello", range: AXTextSelectionRange(location: 0, length: 5)),
        selectedTextMarkerRangeEvidence: .unsupported, cursorPosition: .zero, selectionBounds: nil,
        sourceAppPID: 123, appBundleIdentifier: "ru.keepcoder.Telegram", focusedElementRole: "AXTextArea",
        focusedElementSubrole: nil, isValueAttributeWritable: true, boundsMode: .topLeftNeedsConversion, focusedElementID: 11
    )
    var outcome: AXSelectionReadOutcome = .unavailable(focusedElementID: 11)
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in selected }, clipboardSelectionCapture: { _ in nil },
        scheduler: scheduler, automaticSnapshotReader: { _ in outcome }, frontmostPIDReader: { 123 }
    )
    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    #expect(observer.currentSelection?.text == "Hello")
    outcome = .snapshot(ayuMessageSnapshot(bundle: "ru.keepcoder.Telegram", role: "AXTextArea", writable: true))
    scheduler.advance(by: 0.1)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(observer.currentSelection == nil)
    observer.stopPolling()
}

@Test @MainActor
func testAyuReadOnlyClipboardHoldRequiresExactEligibleSnapshot() async {
    let ineligible = [
        ayuMessageSnapshot(pid: 0), ayuMessageSnapshot(focus: 0),
        ayuMessageSnapshot(role: "AXTextArea"), ayuMessageSnapshot(role: "AXGroup"),
        ayuMessageSnapshot(writable: true), ayuMessageSnapshot(bundle: "one.ayugram.AyuGramDesktop.beta"),
        ayuMessageSnapshot(bundle: "org.example.Client")
    ]
    for snapshot in ineligible {
        let observer = TextSelectionObserver(
            accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
            selectionSnapshotReader: { _ in snapshot },
            clipboardSelectionCapture: { _ in TextSelection(text: "Synthetic message", cursorPosition: .zero,
                sourceAppPID: 123, appBundleIdentifier: "one.ayugram.AyuGramDesktop") },
            scheduler: ManualSelectionScheduler(), automaticSnapshotReader: { _ in .unavailable(focusedElementID: 11) },
            frontmostPIDReader: { 123 }
        )
        _ = await observer.captureSelection(preferredSourceAppPID: 123)
        observer.pollForTesting()
        await observer.waitForPendingSelectionReadForTesting()
        #expect(observer.currentSelection == nil)
        observer.stopPolling()
    }
}

@Test @MainActor
func testAyuReadOnlyClipboardHoldAcceptsCaseInsensitiveExactBundle() async {
    let snapshot = ayuMessageSnapshot(bundle: "ONE.AYUGRAM.AYUGRAMDESKTOP")
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot },
        clipboardSelectionCapture: { _ in TextSelection(text: "Synthetic message", cursorPosition: .zero, sourceAppPID: 123) },
        scheduler: ManualSelectionScheduler(), automaticSnapshotReader: { _ in .snapshot(snapshot) },
        frontmostPIDReader: { 123 }
    )
    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    #expect(observer.currentSelection?.focusedElementID == 11)
    observer.stopPolling()
}

@Test(arguments: ["poll", "sync-confirmation", "async-confirmation"]) @MainActor
func testAyuReadOnlyHoldSurvivesBriefReadableRecoveryWithoutAutoShow(_ refresh: String) async throws {
    let scheduler = ManualSelectionScheduler()
    var snapshot = ayuMessageSnapshot()
    var outcome: AXSelectionReadOutcome = .snapshot(snapshot)
    var reads = 0
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot },
        clipboardSelectionCapture: { _ in TextSelection(text: "Synthetic message", cursorPosition: .zero, sourceAppPID: 123) },
        scheduler: scheduler, automaticSnapshotReader: { _ in reads += 1; return outcome }, frontmostPIDReader: { 123 }
    )
    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    let pending = try #require(observer.currentCaptureResult)
    var autoShows = 0
    observer.onSelectionChanged = { _ in autoShows += 1 }
    snapshot = ayuMessageSnapshot(rawText: "Synthetic message")
    outcome = .snapshot(snapshot)
    if refresh == "poll" {
        observer.pollForTesting()
        await observer.waitForPendingSelectionReadForTesting()
    } else if refresh == "sync-confirmation" {
        #expect(observer.confirmSelectionCapture(pending) != nil)
    } else {
        var confirmed = false
        observer.confirmSelectionCapture(pending) { confirmed = $0 != nil }
        await observer.waitForPendingSelectionReadForTesting()
        #expect(confirmed)
    }
    outcome = .snapshot(ayuMessageSnapshot())
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    #expect(observer.currentSelection?.text == "Synthetic message")
    outcome = .unavailable(focusedElementID: 11)
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    let readsBeforeRecovery = reads
    scheduler.advance(by: 0.1)
    await observer.waitForPendingSelectionReadForTesting()
    scheduler.advance(by: 0.15)
    await observer.waitForPendingSelectionReadForTesting()
    scheduler.advance(by: 0.75)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(reads == readsBeforeRecovery + 2)
    #expect(observer.currentSelection?.text == "Synthetic message")
    #expect(autoShows == 0)
    observer.stopPolling()
}

@Test @MainActor
func testAyuReadOnlyClipboardCaptureRejectsChangedIdentityDuringCopy() async {
    let changed: [AXTextSelectionSnapshot?] = [
        ayuMessageSnapshot(pid: 456), ayuMessageSnapshot(focus: 22), ayuMessageSnapshot(focus: 0),
        ayuMessageSnapshot(role: "AXTextArea"), ayuMessageSnapshot(writable: true),
        ayuMessageSnapshot(bundle: "one.ayugram.AyuGramDesktop.beta"), nil
    ]
    for replacement in changed {
        var snapshot: AXTextSelectionSnapshot? = ayuMessageSnapshot()
        var frontmost: pid_t = 123
        let observer = TextSelectionObserver(
            accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
            selectionSnapshotReader: { _ in snapshot },
            clipboardSelectionCapture: { _ in
                await Task.yield()
                snapshot = replacement
                frontmost = replacement?.sourceAppPID ?? 123
                return TextSelection(text: "Synthetic message", cursorPosition: .zero, sourceAppPID: 123)
            }, scheduler: ManualSelectionScheduler(), frontmostPIDReader: { frontmost }
        )
        #expect(await observer.captureSelection(preferredSourceAppPID: 123) == nil)
        #expect(observer.currentCaptureResult == nil)
        observer.stopPolling()
    }
}

@Test @MainActor
func testAyuReadOnlyClipboardCaptureRejectsChangedIdentityBeforeCopy() async {
    var reads = 0
    var copies = 0
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in
            reads += 1
            return ayuMessageSnapshot(focus: reads < 3 ? 11 : 22)
        }, clipboardSelectionCapture: { _ in
            copies += 1
            return TextSelection(text: "Synthetic message", cursorPosition: .zero, sourceAppPID: 123)
        }, scheduler: ManualSelectionScheduler(), frontmostPIDReader: { 123 }
    )
    #expect(await observer.captureSelection(preferredSourceAppPID: 123) == nil)
    #expect(copies == 0)
    #expect(observer.currentCaptureResult == nil)
}

@Test @MainActor
func testAyuReadOnlyHoldClearsOnActualEventFocusApplicationOrAuthoritativeClear() async {
    for scenario in 0..<4 {
        let scheduler = ManualSelectionScheduler()
        var frontmost: pid_t = 123
        var outcome: AXSelectionReadOutcome = .snapshot(ayuMessageSnapshot())
        let observer = TextSelectionObserver(
            accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
            selectionSnapshotReader: { _ in ayuMessageSnapshot() },
            clipboardSelectionCapture: { _ in TextSelection(text: "Synthetic message", cursorPosition: .zero, sourceAppPID: 123) },
            scheduler: scheduler, automaticSnapshotReader: { _ in outcome }, frontmostPIDReader: { frontmost }
        )
        _ = await observer.captureSelection(preferredSourceAppPID: 123)
        switch scenario {
        case 0:
            observer.checkSelectionFromEvent(frontmostPID: 123)
            scheduler.advance(by: 0.05)
        case 1:
            outcome = .snapshot(ayuMessageSnapshot(focus: 22))
            observer.pollForTesting()
        case 2:
            frontmost = 456
            outcome = .unavailable(focusedElementID: nil)
            observer.sourceApplicationChanged()
        default:
            outcome = .cleared
            observer.pollForTesting()
        }
        await observer.waitForPendingSelectionReadForTesting()
        #expect(observer.currentSelection == nil)
        scheduler.advance(by: 1)
        await observer.waitForPendingSelectionReadForTesting()
        #expect(observer.currentSelection == nil)
        observer.stopPolling()
    }
}

@MainActor
private func ayuEditorSnapshot() -> AXTextSelectionSnapshot {
    AXTextSelectionSnapshot(
        rawSelectedTextEvidence: .nonEmpty(text: "Hello", range: nil), selectedTextRangesEvidence: .unsupported,
        selectedTextRangeEvidence: .nonEmpty(text: "Hello", range: AXTextSelectionRange(location: 0, length: 5)),
        selectedTextMarkerRangeEvidence: .unsupported, cursorPosition: .zero, selectionBounds: nil,
        sourceAppPID: 123, appBundleIdentifier: "one.ayugram.AyuGramDesktop", focusedElementRole: "AXTextArea",
        focusedElementSubrole: nil, isValueAttributeWritable: true, boundsMode: .topLeftNeedsConversion, focusedElementID: 11
    )
}

@Test(arguments: [false, true], [false, true]) @MainActor
func testAyuUserDismissDoesNotResurrectFromUnchangedPolling(readOnly: Bool, repeatedHotkey: Bool) async throws {
    let scheduler = ManualSelectionScheduler()
    let snapshot = readOnly ? ayuMessageSnapshot() : ayuEditorSnapshot()
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot },
        clipboardSelectionCapture: { _ in TextSelection(text: "Synthetic message", cursorPosition: .zero, sourceAppPID: 123) },
        scheduler: scheduler, automaticSnapshotReader: { _ in .snapshot(snapshot) }, frontmostPIDReader: { 123 }
    )
    let selection = try #require(await observer.captureSelection(preferredSourceAppPID: 123))
    let toolbar = FloatingToolbarViewModel(environment: AppEnvironment(), keyboardMonitoringEnabled: false)
    defer { toolbar.dismiss(); observer.stopPolling() }
    toolbar.onUserDismiss = { observer.dismissExplicitSelectionHold() }
    var rediscoveries = 0
    observer.onSelectionChanged = { result in
        rediscoveries += 1
        toolbar.show(for: result.selection, source: .autoDetect)
    }
    toolbar.show(for: selection, source: .explicit)
    if repeatedHotkey { #expect(toolbar.handleExplicitTriggerIfVisible()) }
    else { #expect(toolbar.handleKeyValues(keyCode: UInt16(kVK_Escape), modifiers: [])) }
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    scheduler.advance(by: 1)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(!toolbar.isVisible)
    #expect(rediscoveries == 0)
    if readOnly { #expect(observer.currentSelection == nil) }
    else {
        #expect(observer.currentCaptureResult?.appProfileID == "cocoa-editor")
        #expect(observer.currentCaptureResult?.confidence == .high)
    }
}

@Test @MainActor
func testAyuReadOnlyModuleHandoffDoesNotDismissObserverHold() async throws {
    let snapshot = ayuMessageSnapshot()
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot },
        clipboardSelectionCapture: { _ in TextSelection(text: "Synthetic message", cursorPosition: .zero, sourceAppPID: 123) },
        scheduler: ManualSelectionScheduler(), automaticSnapshotReader: { _ in .snapshot(snapshot) }, frontmostPIDReader: { 123 }
    )
    let selection = try #require(await observer.captureSelection(preferredSourceAppPID: 123))
    let toolbar = FloatingToolbarViewModel(environment: AppEnvironment(), keyboardMonitoringEnabled: false)
    defer { toolbar.dismiss(); observer.stopPolling() }
    var userDismisses = 0
    var handedOff: TextSelection?
    toolbar.onUserDismiss = { userDismisses += 1; observer.dismissExplicitSelectionHold() }
    toolbar.onModuleInvoked = { _, selection in handedOff = selection; return false }
    toolbar.show(for: selection, source: .explicit)
    toolbar.invokeModule(GrammarFixModule())
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    #expect(userDismisses == 0)
    #expect(handedOff?.text == "Synthetic message")
    #expect(observer.currentSelection?.text == "Synthetic message")
}

@Test @MainActor
func testAyuRetainedReadOnlyClipboardTextCannotReplace() async throws {
    let snapshot = ayuMessageSnapshot()
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in snapshot },
        clipboardSelectionCapture: { _ in TextSelection(text: "Synthetic message", cursorPosition: .zero, sourceAppPID: 123) },
        scheduler: ManualSelectionScheduler(), automaticSnapshotReader: { _ in .snapshot(snapshot) }, frontmostPIDReader: { 123 }
    )
    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    let selection = try #require(observer.currentSelection)
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.setString("Previous clipboard", forType: .string)
    var writes = 0
    let replacer = TextReplacer(
        clipboardManager: ClipboardManager(pasteboard: pasteboard), sourceAppActivator: { _ in true },
        frontmostPIDProvider: { 123 }, sleepClosure: { _ in }, pasteAction: { writes += 1 },
        accessibilityReplaceHandler: { _, _, _, _, _ in writes += 1; return true },
        selectionSnapshotReader: { _ in snapshot }
    )
    #expect(await replacer.replace(with: "Updated", selection: selection, using: AccessibilityManager()) == .failed)
    #expect(writes == 0)
    #expect(pasteboard.string(forType: .string) == "Previous clipboard")
    observer.stopPolling()
}

@MainActor
private func exhaustTelegramHoldRecovery(_ observer: TextSelectionObserver, scheduler: ManualSelectionScheduler) async {
    observer.processReadOutcomeForTesting(.unavailable(focusedElementID: 11), pid: 123)
    scheduler.advance(by: 0.1)
    await observer.waitForPendingSelectionReadForTesting()
    scheduler.advance(by: 0.15)
    await observer.waitForPendingSelectionReadForTesting()
    scheduler.advance(by: 0.25)
}

@Test @MainActor
func testExplicitTelegramHoldKeepsContextAfter500MillisecondsWithoutRepeatedRecovery() async {
    let scheduler = ManualSelectionScheduler()
    var reads = 0
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in telegramHoldSnapshot() }, scheduler: scheduler,
        automaticSnapshotReader: { _ in reads += 1; return .unavailable(focusedElementID: 11) },
        frontmostPIDReader: { 123 }
    )
    var clears = 0
    observer.onSelectionCleared = { clears += 1 }
    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    let captured = observer.currentCaptureResult
    await exhaustTelegramHoldRecovery(observer, scheduler: scheduler)
    #expect(reads == 2)
    #expect(observer.currentSelection?.text == "Held message")

    for iteration in 1...3 {
        observer.processReadOutcomeForTesting(.unavailable(focusedElementID: 11), pid: 123)
        observer.pollForTesting()
        await observer.waitForPendingSelectionReadForTesting()
        scheduler.advance(by: 1)
        await observer.waitForPendingSelectionReadForTesting()
        // Normal polling remains available, but cannot start another pair of recovery reads.
        #expect(reads == 2 + iteration)
        #expect(observer.currentSelection?.capturedAt == captured?.selection.capturedAt)
        #expect(observer.currentCaptureResult?.captureMode == .explicit)
        #expect(clears == 0)
    }
    observer.stopPolling()
}

@Test @MainActor
func testSuccessfulTelegramSelectionAndFreshExplicitCaptureRearmRecovery() async {
    let scheduler = ManualSelectionScheduler()
    var reads = 0
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in telegramHoldSnapshot() }, scheduler: scheduler,
        automaticSnapshotReader: { _ in reads += 1; return .unavailable(focusedElementID: 11) },
        frontmostPIDReader: { 123 }
    )
    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    await exhaustTelegramHoldRecovery(observer, scheduler: scheduler)
    #expect(reads == 2)

    observer.processReadOutcomeForTesting(.snapshot(telegramHoldSnapshot()), pid: 123)
    await exhaustTelegramHoldRecovery(observer, scheduler: scheduler)
    #expect(reads == 4)
    #expect(observer.currentSelection?.text == "Held message")

    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    await exhaustTelegramHoldRecovery(observer, scheduler: scheduler)
    #expect(reads == 6)
    #expect(observer.currentSelection?.text == "Held message")
    observer.stopPolling()
}

@Test(arguments: [false, true]) @MainActor
func testConfirmedTelegramSelectionRearmsExhaustedRecovery(asynchronously: Bool) async throws {
    let scheduler = ManualSelectionScheduler()
    var reads = 0
    var outcome: AXSelectionReadOutcome = .unavailable(focusedElementID: 11)
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in telegramHoldSnapshot() }, scheduler: scheduler,
        automaticSnapshotReader: { _ in reads += 1; return outcome }, frontmostPIDReader: { 123 }
    )
    _ = await observer.captureSelection(preferredSourceAppPID: 123)
    await exhaustTelegramHoldRecovery(observer, scheduler: scheduler)
    let pending = try #require(observer.currentCaptureResult)
    if asynchronously {
        outcome = .snapshot(telegramHoldSnapshot())
        var confirmed = false
        observer.confirmSelectionCapture(pending) { confirmed = $0 != nil }
        await observer.waitForPendingSelectionReadForTesting()
        #expect(confirmed)
        outcome = .unavailable(focusedElementID: 11)
    } else {
        #expect(observer.confirmSelectionCapture(pending) != nil)
    }
    await exhaustTelegramHoldRecovery(observer, scheduler: scheduler)
    #expect(reads == (asynchronously ? 5 : 4))
    #expect(observer.currentSelection?.text == "Held message")
    observer.stopPolling()
}

@Test @MainActor
func testExhaustedTelegramHoldClearsOnConfirmedDeselectionFocusAndApplicationChange() async {
    let scheduler = ManualSelectionScheduler()
    var pid: pid_t = 123
    var reads = 0
    let observer = TextSelectionObserver(
        accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        selectionSnapshotReader: { _ in telegramHoldSnapshot() }, scheduler: scheduler,
        automaticSnapshotReader: { _ in reads += 1; return .unavailable(focusedElementID: 11) },
        frontmostPIDReader: { pid }
    )
    var clears = 0
    observer.onSelectionCleared = { clears += 1 }
    for scenario in 0..<3 {
        _ = await observer.captureSelection(preferredSourceAppPID: 123)
        await exhaustTelegramHoldRecovery(observer, scheduler: scheduler)
        #expect(observer.currentSelection?.text == "Held message")
        switch scenario {
        case 0: observer.processReadOutcomeForTesting(.cleared, pid: 123)
        case 1: observer.processReadOutcomeForTesting(.unavailable(focusedElementID: 22), pid: 123)
        default:
            pid = 456
            observer.sourceApplicationChanged()
            await observer.waitForPendingSelectionReadForTesting()
        }
        #expect(observer.currentSelection == nil)
        #expect(clears == scenario + 1)
        let readsAfterClear = reads
        scheduler.advance(by: 1)
        await observer.waitForPendingSelectionReadForTesting()
        #expect(reads == readsAfterClear)
    }
    observer.stopPolling()
}

@Test @MainActor
func testSuccessfulReadCancelsRecoveryAndFocusOrConfirmedEmptyClearsImmediately() {
    let scheduler = ManualSelectionScheduler()
    let observer = TextSelectionObserver(accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
                                        scheduler: scheduler, frontmostPIDReader: { 123 })
    observer.processReadOutcomeForTesting(.snapshot(recoverySnapshot()), pid: 123)
    observer.processReadOutcomeForTesting(.unavailable(focusedElementID: 11), pid: 123)
    observer.processReadOutcomeForTesting(.snapshot(recoverySnapshot()), pid: 123)
    scheduler.advance(by: 0.5)
    #expect(observer.currentSelection?.text == "Hello")
    observer.processReadOutcomeForTesting(.unavailable(focusedElementID: 22), pid: 123)
    #expect(observer.currentSelection == nil)
    observer.processReadOutcomeForTesting(.snapshot(recoverySnapshot()), pid: 123)
    observer.processReadOutcomeForTesting(.cleared, pid: 123)
    #expect(observer.currentSelection == nil)
}

@Test @MainActor
func testFailedConfirmationAllowsSameSelectionToBeRediscovered() async {
    var outcome: AXSelectionReadOutcome = .unavailable(focusedElementID: 11)
    let observer = TextSelectionObserver(accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
                                        scheduler: ManualSelectionScheduler(),
                                        automaticSnapshotReader: { _ in outcome }, frontmostPIDReader: { 123 })
    var shows = 0
    observer.onSelectionChanged = { _ in shows += 1 }
    observer.processReadOutcomeForTesting(.snapshot(recoverySnapshot()), pid: 123)
    var confirmed = true
    observer.confirmSelectionCapture(observer.currentCaptureResult!) { confirmed = $0 != nil }
    await observer.waitForPendingSelectionReadForTesting()
    #expect(!confirmed)
    outcome = .snapshot(recoverySnapshot())
    observer.pollForTesting()
    await observer.waitForPendingSelectionReadForTesting()
    #expect(shows == 2)
    observer.stopPolling()
}

@Test @MainActor
func testUnreadableRangeFallsThroughToReadableMarker() {
    let snapshot = recoverySnapshot(
        ranges: .nonEmpty(text: nil, range: AXTextSelectionRange(location: 0, length: 5)),
        single: .unsupported, marker: .nonEmpty(text: "Hello", range: nil)
    )
    let result = SelectionCaptureEngine().resolveCaptureResult(from: snapshot, mode: .event)
    #expect(result?.selection.text == "Hello")
    #expect(result?.winningEvidenceSource == .marker)
}

@Test
func testPartialAXFailureKeepsReadableEvidenceButCannotEstablishDeselection() {
    let readable = AXSelectionEvidence.nonEmpty(text: "Hello", range: AXTextSelectionRange(location: 0, length: 5))
    #expect(AXSelectionReader.canUseSelectionEvidence(raw: .unsupported, ranges: [readable, .unsupported], hadUnavailableRead: true))
    #expect(AXSelectionReader.canUseSelectionEvidence(raw: readable, ranges: [.unsupported], hadUnavailableRead: true))
    #expect(!AXSelectionReader.canUseSelectionEvidence(raw: .empty, ranges: [.empty, .unsupported], hadUnavailableRead: true))
    #expect(!AXSelectionReader.canUseSelectionEvidence(raw: readable, ranges: [.empty, .unsupported], hadUnavailableRead: true))
    #expect(AXSelectionReader.canUseSelectionEvidence(raw: .empty, ranges: [.empty], hadUnavailableRead: false))
}

@Test @MainActor
func testUnsupportedMarkerStringDoesNotDelayConfirmedDeselection() {
    let scheduler = ManualSelectionScheduler()
    let observer = TextSelectionObserver(accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
                                        scheduler: scheduler, frontmostPIDReader: { 123 })
    for error: AXError in [.attributeUnsupported, .parameterizedAttributeUnsupported, .noValue] {
        observer.processReadOutcomeForTesting(.snapshot(recoverySnapshot()), pid: 123)
        let marker = AXSelectionReader.markerEvidence(value: nil, error: error)
        #expect(marker.evidence == .unsupported)
        #expect(!marker.unavailable)
        #expect(AXSelectionReader.canUseSelectionEvidence(raw: .empty, ranges: [.empty, marker.evidence],
                                                        hadUnavailableRead: marker.unavailable))
        observer.processReadOutcomeForTesting(.snapshot(recoverySnapshot(single: .empty, marker: marker.evidence)), pid: 123)
        #expect(observer.currentSelection == nil)
    }
}

@Test
func testMarkerStringPolicyKeepsTransientAndMalformedReadsUnavailable() {
    // Budget exhaustion is represented as cannotComplete before the read returns.
    for error: AXError in [.cannotComplete, .failure] {
        let marker = AXSelectionReader.markerEvidence(value: nil, error: error)
        #expect(marker.unavailable)
        #expect(!AXSelectionReader.canUseSelectionEvidence(raw: .empty, ranges: [.empty, marker.evidence],
                                                         hadUnavailableRead: marker.unavailable))
    }
    for value: AnyObject? in [nil, NSNumber(value: 1)] {
        let marker = AXSelectionReader.markerEvidence(value: value, error: .success)
        #expect(marker.evidence == .unsupported)
        #expect(marker.unavailable)
    }
    let empty = AXSelectionReader.markerEvidence(value: "" as NSString, error: .success)
    #expect(empty.evidence == .empty)
    #expect(!empty.unavailable)
    let text = AXSelectionReader.markerEvidence(value: NSAttributedString(string: "Hello"), error: .success)
    #expect(text.evidence == .nonEmpty(text: "Hello", range: nil))
    #expect(!text.unavailable)
}

@Test
func testSystemWideFocusFallbackRequiresRequestedApplicationAndKeepsPreferredFirst() {
    var fallbackReads = 0
    let matched = AXSelectionReader.resolveFocusedElement(
        requestedPID: 123, preferredRead: { nil as Int? },
        systemWideRead: { fallbackReads += 1; return 11 }, ownerPID: { _ in 123 }
    )
    #expect(matched == 11)
    #expect(fallbackReads == 1)
    let mismatched = AXSelectionReader.resolveFocusedElement(
        requestedPID: 123, preferredRead: { nil as Int? },
        systemWideRead: { 22 }, ownerPID: { _ in 456 }
    )
    #expect(mismatched == nil)
    let unknownOwner = AXSelectionReader.resolveFocusedElement(
        requestedPID: 123, preferredRead: { nil as Int? },
        systemWideRead: { 22 }, ownerPID: { _ in nil }
    )
    #expect(unknownOwner == nil)
    let preferred = AXSelectionReader.resolveFocusedElement(
        requestedPID: 123, preferredRead: { 33 },
        systemWideRead: { fallbackReads += 1; return 11 }, ownerPID: { _ in 123 }
    )
    #expect(preferred == 33)
    #expect(fallbackReads == 1)
}

@Test @MainActor
func testEventUsesSingle50MillisecondDelayAndIncludesSelectionShortcuts() async {
    let scheduler = ManualSelectionScheduler()
    var reads = 0
    let observer = TextSelectionObserver(accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
        scheduler: scheduler, automaticSnapshotReader: { _ in reads += 1; return .snapshot(recoverySnapshot()) },
        frontmostPIDReader: { 123 })
    observer.checkSelectionFromEvent(frontmostPID: 123)
    observer.checkSelectionFromEvent(frontmostPID: 123)
    scheduler.advance(by: 0.049)
    #expect(reads == 0)
    scheduler.advance(by: 0.001)
    await observer.waitForPendingSelectionReadForTesting()
    #expect(reads == 1)
    #expect(observer.currentCaptureResult?.captureMode == .event)
    for flags: CGEventFlags in [[.maskCommand, .maskShift], [.maskAlternate, .maskShift]] {
        #expect(SelectionEventMonitor.shouldHandleEvent(type: .keyUp, keyCode: CGKeyCode(kVK_LeftArrow), flags: flags))
    }
    #expect(SelectionEventMonitor.shouldHandleEvent(type: .keyUp, keyCode: CGKeyCode(kVK_ANSI_A), flags: .maskCommand))
    #expect(!SelectionEventMonitor.shouldHandleEvent(type: .keyUp, keyCode: CGKeyCode(kVK_ANSI_F), flags: .maskAlternate))
}

@MainActor
private final class ControlledSelectionReader {
    var requests: [AXSelectionReadContext] = []
    private var pending: CheckedContinuation<AXSelectionReadOutcome, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func read(_ context: AXSelectionReadContext) async -> AXSelectionReadOutcome {
        requests.append(context)
        return await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ outcome: AXSelectionReadOutcome) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: outcome)
    }
}

@Test @MainActor
func testSelectionReaderCoalescesQueueAndRejectsOldApplicationResult() async {
    let reader = ControlledSelectionReader()
    var pid: pid_t = 123
    let observer = TextSelectionObserver(accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
                                        automaticSnapshotReader: { await reader.read($0) }, frontmostPIDReader: { pid })
    observer.pollForTesting()
    await reader.waitUntilStarted()
    for _ in 0..<20 { observer.pollForTesting() }
    #expect(reader.requests.count == 1)
    pid = 456
    observer.sourceApplicationChanged()
    reader.finish(.snapshot(recoverySnapshot()))
    await reader.waitUntilStarted()
    #expect(reader.requests.map(\.processIdentifier) == [123, 456])
    #expect(observer.currentSelection == nil)
    reader.finish(.snapshot(recoverySnapshot(text: "New", pid: 456)))
    await observer.waitForPendingSelectionReadForTesting()
    #expect(observer.currentSelection?.text == "New")
    #expect(reader.requests.count == 2)
}

@MainActor
private final class RecoveryPanelVisibility: PanelVisibilityProvider {
    var isProcessingActive = false
    var isProcessingVisible = false
    var isChatVisible = false
}

@Test @MainActor
func testHighConfidenceEventShowsImmediatelyAndShortReselectionDismisses() {
    let previous = UserDefaults.standard.autoDetectSelectionEnabled
    UserDefaults.standard.setAutoDetectSelectionEnabled(true)
    defer { UserDefaults.standard.setAutoDetectSelectionEnabled(previous) }
    let scheduler = ManualSelectionScheduler()
    let observer = TextSelectionObserver(accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
                                        scheduler: scheduler, frontmostPIDReader: { 123 })
    let environment = AppEnvironment()
    environment.installTextSelectionObserverForTesting(observer)
    let visibility = RecoveryPanelVisibility()
    let coordinator = AutoDetectCoordinator(environment: environment, panelVisibility: visibility, scheduler: scheduler)
    var shows = 0
    var clears = 0
    coordinator.onSelectionDetected = { _ in shows += 1 }
    coordinator.onSelectionCleared = { clears += 1 }
    coordinator.bindAutoDetectionCallbacks(to: observer)
    observer.processReadOutcomeForTesting(.snapshot(recoverySnapshot()), pid: 123)
    #expect(shows == 1)
    observer.processReadOutcomeForTesting(.snapshot(recoverySnapshot(text: "Hi")), pid: 123)
    #expect(clears == 1)
    scheduler.advance(by: 0.5)
    #expect(shows == 1)
    coordinator.cancelPendingSelectionWork()
}

@Test @MainActor
func testPollingCapturePromotesToImmediateEventShowOnlyOnce() async {
    let previous = UserDefaults.standard.autoDetectSelectionEnabled
    UserDefaults.standard.setAutoDetectSelectionEnabled(true)
    defer { UserDefaults.standard.setAutoDetectSelectionEnabled(previous) }
    let scheduler = ManualSelectionScheduler()
    let snapshot = recoverySnapshot()
    let observer = TextSelectionObserver(accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
                                        scheduler: scheduler, automaticSnapshotReader: { _ in .snapshot(snapshot) },
                                        frontmostPIDReader: { 123 })
    let environment = AppEnvironment()
    environment.installTextSelectionObserverForTesting(observer)
    let visibility = RecoveryPanelVisibility()
    let coordinator = AutoDetectCoordinator(environment: environment, panelVisibility: visibility, scheduler: scheduler)
    var shows = 0
    coordinator.onSelectionDetected = { _ in shows += 1 }
    coordinator.bindAutoDetectionCallbacks(to: observer)
    func poll() async {
        observer.pollForTesting()
        await observer.waitForPendingSelectionReadForTesting()
    }

    await poll()
    #expect(shows == 0)
    scheduler.advance(by: 0.05)
    observer.processReadOutcomeForTesting(.snapshot(snapshot), pid: 123)
    #expect(shows == 1)

    for _ in 0..<3 {
        await poll()
        observer.processReadOutcomeForTesting(.snapshot(snapshot), pid: 123)
    }
    scheduler.advance(by: 0.5)
    #expect(shows == 1)

    observer.processReadOutcomeForTesting(.cleared, pid: 123)
    await poll()
    observer.processReadOutcomeForTesting(.snapshot(snapshot), pid: 123)
    #expect(shows == 2)
    scheduler.advance(by: 0.5)
    #expect(shows == 2)
    coordinator.cancelPendingSelectionWork()
}
