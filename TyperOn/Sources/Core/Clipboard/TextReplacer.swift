// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit

enum ReplacementMethod: String, Sendable {
    case accessibility
    case clipboard
}

struct LastReplacement: Sendable, Equatable {
    let originalText: String
    let replacementText: String
    let sourceAppPID: pid_t?
    let timestamp: Date
    let method: ReplacementMethod
}

enum ReplaceOutcome: Sendable, Equatable {
    case replaced(ReplacementMethod)
    case failed
}

@MainActor
final class TextReplacer {
    typealias AppActivator = (pid_t?) -> Bool
    typealias FrontmostPIDProvider = () -> pid_t?
    typealias SleepClosure = (Int) async -> Void
    typealias KeyAction = () -> Void
    typealias SelectionRangeRestorer = (AXTextSelectionRange, pid_t?, AccessibilityManager) -> Bool
    typealias AccessibilityReplaceHandler = (String, pid_t?, Int, AXTextSelectionRange?, AccessibilityManager) -> Bool
    typealias SelectionSnapshotReader = (pid_t?) -> AXTextSelectionSnapshot?
    typealias EditableValueReader = (pid_t, Int) -> String?

    private static let focusWaitTimeoutMilliseconds = 400
    private static let focusWaitStepMilliseconds = 20
    private static let clipboardSettleMilliseconds = 80
    private static let clipboardRestoreDelayMilliseconds = 200
    // AyuGram v7.0.9 uses 8 * account message limit; 32768 is its non-Premium default.
    // This conservative operational cap does not assume access to its server configuration.
    private static let ayuGramTextPasteLimit = 32768

    private let clipboardManager: ClipboardManager
    private let sourceAppActivator: AppActivator?
    private let frontmostPIDProvider: FrontmostPIDProvider?
    private let sleepClosure: SleepClosure?
    private let pasteAction: KeyAction?
    private let undoAction: KeyAction?
    private let selectionRangeRestorer: SelectionRangeRestorer?
    private let accessibilityReplaceHandler: AccessibilityReplaceHandler?
    private let selectionSnapshotReader: SelectionSnapshotReader?
    private let editableValueReader: EditableValueReader?
    private var isReplacing = false

    init(
        clipboardManager: ClipboardManager,
        sourceAppActivator: AppActivator? = nil,
        frontmostPIDProvider: FrontmostPIDProvider? = nil,
        sleepClosure: SleepClosure? = nil,
        pasteAction: KeyAction? = nil,
        undoAction: KeyAction? = nil,
        selectionRangeRestorer: SelectionRangeRestorer? = nil,
        accessibilityReplaceHandler: AccessibilityReplaceHandler? = nil,
        selectionSnapshotReader: SelectionSnapshotReader? = nil,
        editableValueReader: EditableValueReader? = nil
    ) {
        self.clipboardManager = clipboardManager
        self.sourceAppActivator = sourceAppActivator
        self.frontmostPIDProvider = frontmostPIDProvider
        self.sleepClosure = sleepClosure
        self.pasteAction = pasteAction
        self.undoAction = undoAction
        self.selectionRangeRestorer = selectionRangeRestorer
        self.accessibilityReplaceHandler = accessibilityReplaceHandler
        self.selectionSnapshotReader = selectionSnapshotReader
        self.editableValueReader = editableValueReader
    }

    func replace(
        with text: String,
        selection: TextSelection,
        using accessibilityManager: AccessibilityManager? = nil
    ) async -> ReplaceOutcome {
        guard !text.isEmpty, !Task.isCancelled, !isReplacing,
              let sourcePID = selection.sourceAppPID,
              let frontmostPID = currentFrontmostPID(),
              frontmostPID == sourcePID || frontmostPID == ProcessInfo.processInfo.processIdentifier else {
            return .failed
        }
        isReplacing = true
        defer { isReplacing = false }
        guard await waitForSourceAppFocus(expectedPID: selection.sourceAppPID) else { return .failed }
        guard isReplacementTargetValid(selection, using: accessibilityManager) else { return .failed }

        let isAyuGram = selection.appBundleIdentifier?.lowercased() == "one.ayugram.ayugramdesktop"
        // AyuGram 7.0.9 AXValue writes bypass Undo; use its normal paste editing path.
        if let manager = accessibilityManager,
           selection.supportsDirectAccessibilityReplace,
           !isAyuGram,
           restoreSelectionRangeIfAvailable(selection, using: manager),
           isReplacementTargetValid(selection, using: manager) {
            if replaceViaAccessibility(
                text,
                expectedPID: selection.sourceAppPID,
                expectedFocusedElementID: selection.focusedElementID,
                preferredSelectionRange: selection.selectedTextRange,
                expectedSelectedText: selection.text,
                using: manager
            ) {
                Log.clipboard.info("Text replaced via Accessibility API (pid: \(selection.sourceAppPID ?? -1))")
                return .replaced(.accessibility)
            }
        }

        // Fallback: clipboard-based replacement
        return await replaceViaClipboard(text, selection: selection, using: accessibilityManager, verifyAyuGramEdit: isAyuGram)
    }

    func undoLastReplacement(_ replacement: LastReplacement) async -> Bool {
        guard await waitForSourceAppFocus(expectedPID: replacement.sourceAppPID) else { return false }
        simulateUndo()
        return true
    }

    private func waitForSourceAppFocus(expectedPID: pid_t?) async -> Bool {
        guard activateSourceApp(forPID: expectedPID) else { return false }

        guard let expectedPID else {
            return true
        }

        if currentFrontmostPID() == expectedPID {
            return true
        }

        let attempts = Self.focusWaitTimeoutMilliseconds / Self.focusWaitStepMilliseconds
        for _ in 0..<attempts {
            await sleep(milliseconds: Self.focusWaitStepMilliseconds)
            guard !Task.isCancelled else { return false }
            if currentFrontmostPID() == expectedPID {
                return true
            }
        }

        Log.clipboard.error("Replace failed: source app pid \(expectedPID) did not become frontmost after activation")
        return false
    }

    private func restoreSelectionRangeIfAvailable(
        _ selection: TextSelection,
        using manager: AccessibilityManager
    ) -> Bool {
        guard isReplacementTargetValid(selection, using: manager) else { return false }
        let selectionRange = selection.selectedTextRange
        guard let selectionRange, selectionRange.length > 0 else { return false }
        if let selectionRangeRestorer {
            return selectionRangeRestorer(selectionRange, selection.sourceAppPID, manager)
        }
        return manager.setSelectedTextRange(selectionRange, for: selection)
    }

    private func replaceViaAccessibility(
        _ text: String,
        expectedPID: pid_t?,
        expectedFocusedElementID: Int,
        preferredSelectionRange: AXTextSelectionRange?,
        expectedSelectedText: String,
        using manager: AccessibilityManager
    ) -> Bool {
        if let accessibilityReplaceHandler {
            return accessibilityReplaceHandler(
                text,
                expectedPID,
                expectedFocusedElementID,
                preferredSelectionRange,
                manager
            )
        }

        if manager.replaceSelectedText(
            with: text,
            in: expectedPID,
            expectedFocusedElementID: expectedFocusedElementID,
            preferredSelectionRange: preferredSelectionRange,
            expectedSelectedText: expectedSelectedText
        ) {
            Log.clipboard.info("Text replaced via Accessibility API (pid: \(expectedPID ?? -1))")
            return true
        }
        return false
    }

    private func activateSourceApp(forPID sourcePID: pid_t?) -> Bool {
        if let sourceAppActivator {
            return sourceAppActivator(sourcePID)
        }

        guard let sourcePID else { return true }
        guard let sourceApp = NSRunningApplication(processIdentifier: sourcePID) else {
            Log.clipboard.error("Replace failed: source app with pid \(sourcePID) not found")
            return false
        }

        if sourceApp.isActive {
            return true
        }

        let activated = sourceApp.activate(options: [])
        if !activated {
            Log.clipboard.error("Replace failed: unable to activate source app pid \(sourcePID)")
        }
        return activated
    }

    private func isReplacementTargetValid(
        _ selection: TextSelection,
        using manager: AccessibilityManager?
    ) -> Bool {
        guard !Task.isCancelled,
              let expectedPID = selection.sourceAppPID,
              currentFrontmostPID() == expectedPID else { return false }
        let snapshot: AXTextSelectionSnapshot?
        if let selectionSnapshotReader {
            snapshot = selectionSnapshotReader(expectedPID)
        } else {
            snapshot = manager?.selectionSnapshot(in: expectedPID)
        }
        guard let snapshot, currentFrontmostPID() == expectedPID else { return false }
        return AccessibilityManager.isReplacementContextValid(selection: selection, snapshot: snapshot)
    }

    private func replaceViaClipboard(
        _ text: String,
        selection: TextSelection,
        using manager: AccessibilityManager?,
        verifyAyuGramEdit: Bool
    ) async -> ReplaceOutcome {
        guard isReplacementTargetValid(selection, using: manager) else { return .failed }

        var originalValue: String?
        var expectedValue: String?
        if verifyAyuGramEdit {
            guard !selection.hasDiscontiguousSelection,
                  let range = selection.selectedTextRange,
                  let value = editableValue(for: selection, using: manager),
                  let replacement = AccessibilityManager.replacingValue(
                      value, replacing: range, with: text, expectedSelectedText: selection.text
                  ),
                  replacement.updatedValue.utf16.count < Self.ayuGramTextPasteLimit else {
                return .failed
            }
            originalValue = value
            expectedValue = replacement.updatedValue
        }

        clipboardManager.backup()
        clipboardManager.write(text)

        // Delay to ensure clipboard is updated before paste
        await sleep(milliseconds: Self.clipboardSettleMilliseconds)

        guard isReplacementTargetValid(selection, using: manager),
              originalValue == nil || editableValue(for: selection, using: manager) == originalValue,
              currentFrontmostPID() == selection.sourceAppPID,
              !clipboardManager.hasExternalChange() else {
            if !clipboardManager.hasExternalChange() {
                clipboardManager.restore()
            }
            return .failed
        }
        simulatePaste()

        // Wait for paste to complete in the target app, then restore
        await sleep(milliseconds: Self.clipboardRestoreDelayMilliseconds)

        var replacementVerified = true
        if let expectedValue {
            replacementVerified = currentFrontmostPID() == selection.sourceAppPID
                && editableValue(for: selection, using: manager).map(Self.normalizedLineEndings)
                    == Self.normalizedLineEndings(expectedValue)
                && currentFrontmostPID() == selection.sourceAppPID
        }

        // Only restore if no external app modified the clipboard during paste
        if !clipboardManager.hasExternalChange() {
            clipboardManager.restore()
            if replacementVerified {
                Log.clipboard.info("Text replaced via clipboard, original restored")
            } else {
                Log.clipboard.warning("Clipboard restored; paste result could not be verified")
            }
        } else {
            Log.clipboard.warning("Clipboard changed externally during paste, skipping restore")
        }

        return replacementVerified ? .replaced(.clipboard) : .failed
    }

    private func editableValue(for selection: TextSelection, using manager: AccessibilityManager?) -> String? {
        guard let pid = selection.sourceAppPID else { return nil }
        if let editableValueReader {
            return editableValueReader(pid, selection.focusedElementID)
        }
        return manager?.replacementTextAreaValue(in: pid, expectedFocusedElementID: selection.focusedElementID)
    }

    private static func normalizedLineEndings(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    private func currentFrontmostPID() -> pid_t? {
        if let frontmostPIDProvider {
            return frontmostPIDProvider()
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func sleep(milliseconds: Int) async {
        if let sleepClosure {
            await sleepClosure(milliseconds)
            return
        }

        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func simulatePaste() {
        if let pasteAction {
            pasteAction()
            return
        }
        KeySimulator.simulatePaste()
    }

    private func simulateUndo() {
        if let undoAction {
            undoAction()
            return
        }
        KeySimulator.simulateUndo()
    }
}
