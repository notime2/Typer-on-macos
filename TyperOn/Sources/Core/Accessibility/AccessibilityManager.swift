// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import ApplicationServices

// These runtime AX names also work with SDKs that do not export marker constants.
enum AXTextMarkerAttributes {
    static let selectedRange = "AXSelectedTextMarkerRange"
    static let attributedStringForRange = "AXAttributedStringForTextMarkerRange"
    static let boundsForRange = "AXBoundsForTextMarkerRange"
}

struct AXTextSelectionRange: Equatable, Sendable {
    let location: Int
    let length: Int
}

enum AXSelectionEvidence: Equatable, Sendable {
    case unsupported
    case empty
    case nonEmpty(text: String?, range: AXTextSelectionRange?)

    var text: String? {
        guard case .nonEmpty(let text, _) = self,
              let text,
              !text.isEmpty else {
            return nil
        }
        return text
    }

    var range: AXTextSelectionRange? {
        guard case .nonEmpty(_, let range) = self else {
            return nil
        }
        return range
    }

    var isSupported: Bool {
        self != .unsupported
    }

    var isExplicitlyEmpty: Bool {
        self == .empty
    }

    var isNonEmpty: Bool {
        if case .nonEmpty = self {
            return true
        }
        return false
    }
}

struct AXTextSelectionSnapshot: Equatable, Sendable {
    let rawSelectedTextEvidence: AXSelectionEvidence
    let selectedTextRangesEvidence: AXSelectionEvidence
    let selectedTextRangeEvidence: AXSelectionEvidence
    let selectedTextMarkerRangeEvidence: AXSelectionEvidence
    let selectedTextRanges: [AXTextSelectionRange]
    let selectedText: String?
    let selectedTextRange: AXTextSelectionRange?
    let cursorPosition: NSPoint
    let selectionBounds: NSRect?
    let sourceAppPID: pid_t?
    let appBundleIdentifier: String?
    let focusedElementRole: String?
    let focusedElementSubrole: String?
    let isValueAttributeWritable: Bool
    let boundsMode: AccessibilityManager.SelectionBoundsCoordinateMode
    let focusedElementID: Int

    init(
        rawSelectedTextEvidence: AXSelectionEvidence,
        selectedTextRangesEvidence: AXSelectionEvidence,
        selectedTextRangeEvidence: AXSelectionEvidence,
        selectedTextMarkerRangeEvidence: AXSelectionEvidence,
        selectedTextRanges: [AXTextSelectionRange] = [],
        cursorPosition: NSPoint,
        selectionBounds: NSRect?,
        sourceAppPID: pid_t?,
        appBundleIdentifier: String?,
        focusedElementRole: String?,
        focusedElementSubrole: String?,
        isValueAttributeWritable: Bool,
        boundsMode: AccessibilityManager.SelectionBoundsCoordinateMode,
        focusedElementID: Int
    ) {
        self.rawSelectedTextEvidence = rawSelectedTextEvidence
        self.selectedTextRangesEvidence = selectedTextRangesEvidence
        self.selectedTextRangeEvidence = selectedTextRangeEvidence
        self.selectedTextMarkerRangeEvidence = selectedTextMarkerRangeEvidence
        self.selectedTextRanges = selectedTextRanges
        self.selectedText = Self.resolveSelectedText(
            rawSelectedTextEvidence: rawSelectedTextEvidence,
            selectedTextRangesEvidence: selectedTextRangesEvidence,
            selectedTextRangeEvidence: selectedTextRangeEvidence,
            selectedTextMarkerRangeEvidence: selectedTextMarkerRangeEvidence
        )
        self.selectedTextRange = Self.resolveSelectedTextRange(
            selectedTextRanges: selectedTextRanges,
            selectedTextRangesEvidence: selectedTextRangesEvidence,
            selectedTextRangeEvidence: selectedTextRangeEvidence,
            selectedTextMarkerRangeEvidence: selectedTextMarkerRangeEvidence
        )
        self.cursorPosition = cursorPosition
        self.selectionBounds = selectionBounds
        self.sourceAppPID = sourceAppPID
        self.appBundleIdentifier = appBundleIdentifier
        self.focusedElementRole = focusedElementRole
        self.focusedElementSubrole = focusedElementSubrole
        self.isValueAttributeWritable = isValueAttributeWritable
        self.boundsMode = boundsMode
        self.focusedElementID = focusedElementID
    }

    var hasNonEmptyText: Bool {
        guard let selectedText else { return false }
        return !selectedText.isEmpty
    }

    var rawSelectedText: String? {
        rawSelectedTextEvidence.text
    }

    var rangeBackedEvidences: [AXSelectionEvidence] {
        [
            selectedTextRangesEvidence,
            selectedTextRangeEvidence,
            selectedTextMarkerRangeEvidence,
        ]
    }

    var hasSupportedRangeBackedEvidence: Bool {
        rangeBackedEvidences.contains { $0.isSupported }
    }

    var hasExplicitlyEmptyRangeBackedEvidence: Bool {
        rangeBackedEvidences.contains { $0.isExplicitlyEmpty }
    }

    var hasNonEmptyRangeBackedEvidence: Bool {
        rangeBackedEvidences.contains { $0.isNonEmpty }
    }

    var hasDiscontiguousSelection: Bool {
        selectedTextRanges.count > 1
    }

    private static func resolveSelectedText(
        rawSelectedTextEvidence: AXSelectionEvidence,
        selectedTextRangesEvidence: AXSelectionEvidence,
        selectedTextRangeEvidence: AXSelectionEvidence,
        selectedTextMarkerRangeEvidence: AXSelectionEvidence
    ) -> String? {
        let rangeBackedEvidences = [
            selectedTextRangesEvidence,
            selectedTextRangeEvidence,
            selectedTextMarkerRangeEvidence,
        ]
        if let text = rangeBackedEvidences.lazy.compactMap({ $0.text }).first {
            return text
        }
        return rawSelectedTextEvidence.text
    }

    private static func resolveSelectedTextRange(
        selectedTextRanges: [AXTextSelectionRange],
        selectedTextRangesEvidence: AXSelectionEvidence,
        selectedTextRangeEvidence: AXSelectionEvidence,
        selectedTextMarkerRangeEvidence: AXSelectionEvidence
    ) -> AXTextSelectionRange? {
        if selectedTextRanges.count == 1 {
            return selectedTextRanges[0]
        }

        let rangeBackedEvidences = [
            selectedTextRangesEvidence,
            selectedTextRangeEvidence,
            selectedTextMarkerRangeEvidence,
        ]
        return rangeBackedEvidences.lazy.compactMap({ $0.range }).first
    }
}

private extension AXTextSelectionRange {
    var isValid: Bool {
        location >= 0 && length >= 0
    }

    var isNonEmpty: Bool {
        isValid && length > 0
    }

    var cfRange: CFRange {
        CFRange(location: location, length: length)
    }
}

@MainActor
@Observable
final class AccessibilityManager {
    private struct FocusedElementContext {
        let element: AXUIElement
        let sourceAppPID: pid_t?
    }

    enum SelectionBoundsCoordinateMode: Equatable, Sendable {
        case topLeftNeedsConversion
        case alreadyAppKit
    }

    nonisolated static let chromiumBundleIdentifiers: Set<String> = [
        "com.brave.Browser",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.google.Chrome.dev",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaNext",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
        "org.chromium.Chromium",
    ]

    nonisolated private static let electronBundleIdentifiers: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.github.Electron",
        "com.microsoft.VSCode",
        "com.tinyspeck.slackmacgap",
        "com.getpostman.Postman",
        "notion.id",
    ]

    nonisolated private static let electronBundleIdentifierPatterns: [String] = [
        ".electron.",
        ".electron",
        "electron.",
    ]

    private(set) var isTrusted: Bool = false
    @ObservationIgnored private let manualAccessibilityActivator: AXManualAccessibilityActivator

    init(manualAccessibilityActivator: AXManualAccessibilityActivator = .shared) {
        self.manualAccessibilityActivator = manualAccessibilityActivator
        isTrusted = AXIsProcessTrusted()
    }

    func requestPermission() {
        isTrusted = Self.requestTrustedWithPrompt()
    }

    private nonisolated static func requestTrustedWithPrompt() -> Bool {
        // kAXTrustedCheckOptionPrompt is "AXTrustedCheckOptionPrompt"
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func checkPermission() {
        isTrusted = AXIsProcessTrusted()
    }

    func getSelectedText(in processIdentifier: pid_t? = nil) -> (
        text: String,
        position: NSPoint,
        selectionBounds: NSRect?,
        sourceAppPID: pid_t?
    )? {
        guard let snapshot = selectionSnapshot(in: processIdentifier),
              snapshot.hasNonEmptyText,
              let text = snapshot.selectedText else {
            return nil
        }

        return (
            text: text,
            position: snapshot.cursorPosition,
            selectionBounds: snapshot.selectionBounds,
            sourceAppPID: snapshot.sourceAppPID
        )
    }

    func selectionSnapshot(in processIdentifier: pid_t? = nil) -> AXTextSelectionSnapshot? {
        guard isTrusted else { return nil }

        // Before the focus lookup: an app with a hidden AX tree has no focused element to read.
        if let targetPID = processIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier {
            manualAccessibilityActivator.prepare(
                pid: targetPID,
                bundleIdentifier: NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier
            )
        }

        guard let context = focusedElementContext(for: processIdentifier) else {
            return nil
        }

        let sourceBundleIdentifier = context.sourceAppPID
            .flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        let cursorPosition = NSEvent.mouseLocation
        let rawSelectedTextEvidence = selectedTextAttributeEvidence(from: context.element)
        let selectedTextRanges = extractSelectedTextRanges(from: context.element)
        let selectedTextRangesEvidence = selectedTextRangesEvidence(
            from: context.element,
            selectedRanges: selectedTextRanges
        )
        let selectedTextRangeEvidence = selectedTextRangeEvidence(from: context.element)
        let selectedTextMarkerRangeEvidence = selectedTextMarkerRangeEvidence(from: context.element)
        let boundsMode = Self.coordinateMode(forBundleIdentifier: sourceBundleIdentifier)

        return AXTextSelectionSnapshot(
            rawSelectedTextEvidence: rawSelectedTextEvidence,
            selectedTextRangesEvidence: selectedTextRangesEvidence,
            selectedTextRangeEvidence: selectedTextRangeEvidence,
            selectedTextMarkerRangeEvidence: selectedTextMarkerRangeEvidence,
            selectedTextRanges: selectedTextRanges,
            cursorPosition: cursorPosition,
            selectionBounds: getSelectionBounds(
                for: context.element,
                sourceBundleIdentifier: sourceBundleIdentifier
            ),
            sourceAppPID: context.sourceAppPID,
            appBundleIdentifier: sourceBundleIdentifier,
            focusedElementRole: attributeStringValue(kAXRoleAttribute as CFString, from: context.element),
            focusedElementSubrole: attributeStringValue(kAXSubroleAttribute as CFString, from: context.element),
            isValueAttributeWritable: isAttributeSettable(kAXValueAttribute as CFString, on: context.element),
            boundsMode: boundsMode,
            focusedElementID: Int(CFHash(context.element))
        )
    }

    private func getSelectionBounds(for element: AXUIElement, sourceBundleIdentifier: String?) -> NSRect? {
        let screens = NSScreen.screens
        let screenFrames = screens.map(\.frame)
        let primaryScreenFrame = screens.first?.frame
        let mode = Self.coordinateMode(forBundleIdentifier: sourceBundleIdentifier)

        if let axRect = boundsForSelectedTextRange(in: element),
           let resolved = Self.resolveSelectionBounds(
               axRect: axRect, screenFrames: screenFrames, primaryScreenFrame: primaryScreenFrame, mode: mode
           ) {
            return resolved
        }

        if let axRect = boundsForSelectedTextMarkerRange(in: element),
           let resolved = Self.resolveSelectionBounds(
               axRect: axRect, screenFrames: screenFrames, primaryScreenFrame: primaryScreenFrame, mode: mode
           ) {
            return resolved
        }

        return nil
    }

    nonisolated static func coordinateMode(forBundleIdentifier bundleIdentifier: String?) -> SelectionBoundsCoordinateMode {
        guard let bundleIdentifier else {
            return .topLeftNeedsConversion
        }

        if chromiumBundleIdentifiers.contains(bundleIdentifier) {
            return .alreadyAppKit
        }

        if electronBundleIdentifiers.contains(bundleIdentifier) {
            return .alreadyAppKit
        }

        let lowered = bundleIdentifier.lowercased()
        if electronBundleIdentifierPatterns.contains(where: lowered.contains) {
            return .alreadyAppKit
        }

        return .topLeftNeedsConversion
    }

    nonisolated static func resolveSelectionBounds(
        axRect: CGRect,
        screenFrames: [CGRect],
        primaryScreenFrame: CGRect?,
        mode: SelectionBoundsCoordinateMode
    ) -> NSRect? {
        guard let primaryScreenFrame,
              isUsableRect(primaryScreenFrame),
              screenFrames.contains(primaryScreenFrame),
              screenFrames.allSatisfy(isUsableRect),
              isUsableRect(axRect) else { return nil }

        let candidates = selectionBoundsCandidates(
            axRect: axRect,
            primaryScreenFrame: primaryScreenFrame,
            mode: mode
        )

        if isValidSelectionBounds(candidates.preferred, screenFrames: screenFrames) {
            return candidates.preferred
        }

        if isValidSelectionBounds(candidates.alternate, screenFrames: screenFrames) {
            return candidates.alternate
        }

        return nil
    }

    static func replacingValue(
        _ currentValue: String,
        replacing selectionRange: AXTextSelectionRange,
        with replacementText: String,
        expectedSelectedText: String? = nil
    ) -> (updatedValue: String, insertionRange: AXTextSelectionRange)? {
        guard selectionRange.isNonEmpty else { return nil }

        let currentNSString = currentValue as NSString
        guard selectionRange.location <= currentNSString.length,
              selectionRange.length <= currentNSString.length - selectionRange.location else {
            return nil
        }
        let range = NSRange(location: selectionRange.location, length: selectionRange.length)
        if let expectedSelectedText,
           currentNSString.substring(with: range) != expectedSelectedText {
            return nil
        }

        let updatedValue = currentNSString.replacingCharacters(
            in: range,
            with: replacementText
        )
        let replacementNSString = replacementText as NSString

        let insertionRange = AXTextSelectionRange(
            location: selectionRange.location + replacementNSString.length,
            length: 0
        )
        return (updatedValue: updatedValue, insertionRange: insertionRange)
    }

    static func isDirectReplacementContextValid(
        expectedFocusedElementID: Int,
        currentFocusedElementID: Int,
        preferredSelectionRange: AXTextSelectionRange,
        currentSelectionRange: AXTextSelectionRange?
    ) -> Bool {
        guard expectedFocusedElementID != 0, currentFocusedElementID == expectedFocusedElementID else {
            return false
        }

        return currentSelectionRange == preferredSelectionRange
    }

    static func isReplacementContextValid(selection: TextSelection, snapshot: AXTextSelectionSnapshot) -> Bool {
        guard let expectedPID = selection.sourceAppPID, expectedPID > 0,
              snapshot.sourceAppPID == expectedPID,
              selection.focusedElementID != 0,
              snapshot.focusedElementID == selection.focusedElementID,
              !selection.text.isEmpty,
              snapshot.selectedText == selection.text,
              snapshot.hasDiscontiguousSelection == selection.hasDiscontiguousSelection else {
            return false
        }
        if let expectedRange = selection.selectedTextRange,
           snapshot.selectedTextRange != expectedRange {
            return false
        }
        let evidences = [snapshot.rawSelectedTextEvidence] + snapshot.rangeBackedEvidences
        if selection.hasDiscontiguousSelection {
            guard selection.selectedTextRanges.count > 1,
                  snapshot.selectedTextRanges == selection.selectedTextRanges else { return false }
        } else {
            // The resolved range can hide another source selecting identical text elsewhere.
            let ranges = selection.selectedTextRanges + snapshot.selectedTextRanges + evidences.compactMap(\.range)
            if let expectedRange = selection.selectedTextRange ?? ranges.first,
               !ranges.allSatisfy({ $0 == expectedRange }) {
                return false
            }
        }
        // Conflicting or explicitly empty evidence cannot authorize a write.
        return evidences.allSatisfy { evidence in
            !evidence.isExplicitlyEmpty && (evidence.text == nil || evidence.text == selection.text)
        }
    }

    nonisolated private static func selectionBoundsCandidates(
        axRect: CGRect,
        primaryScreenFrame: CGRect,
        mode: SelectionBoundsCoordinateMode
    ) -> (preferred: NSRect, alternate: NSRect) {
        // AX's top-left origin belongs to the primary display, not the combined desktop.
        let convertedRect = NSRect(
            x: axRect.origin.x,
            y: primaryScreenFrame.maxY - axRect.origin.y - axRect.size.height,
            width: axRect.size.width,
            height: axRect.size.height
        )
        let rawRect = NSRect(origin: axRect.origin, size: axRect.size)

        switch mode {
        case .topLeftNeedsConversion:
            return (preferred: convertedRect, alternate: rawRect)
        case .alreadyAppKit:
            return (preferred: rawRect, alternate: convertedRect)
        }
    }

    nonisolated private static func isValidSelectionBounds(_ rect: NSRect, screenFrames: [CGRect]) -> Bool {
        isUsableRect(rect) &&
        screenFrames.contains(where: { $0.intersects(rect) })
    }

    nonisolated private static func isUsableRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.size.width.isFinite && rect.size.width > 0 &&
        rect.size.height.isFinite && rect.size.height > 0 &&
        rect.maxX.isFinite && rect.maxY.isFinite
    }

    private func focusedElementContext(for processIdentifier: pid_t?) -> FocusedElementContext? {
        if let processIdentifier, processIdentifier > 0 {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            guard let focusedElement = copyFocusedElement(from: appElement) else { return nil }
            return FocusedElementContext(element: focusedElement, sourceAppPID: processIdentifier)
        }

        let systemWide = AXUIElementCreateSystemWide()
        guard let focusedElement = copyFocusedElement(from: systemWide) else { return nil }
        return FocusedElementContext(
            element: focusedElement,
            sourceAppPID: copyFocusedApplicationPID(from: systemWide)
        )
    }

    private func selectedTextAttributeEvidence(from element: AXUIElement) -> AXSelectionEvidence {
        guard let value = copyAttributeValue(kAXSelectedTextAttribute as CFString, from: element) else {
            return .unsupported
        }

        return makeSelectionEvidence(
            text: textFromValue(value),
            range: nil,
            rangeIsAuthoritative: false
        )
    }

    private func selectedTextRangesEvidence(
        from element: AXUIElement,
        selectedRanges: [AXTextSelectionRange]? = nil
    ) -> AXSelectionEvidence {
        guard let rangesValue = copyAttributeValue(kAXSelectedTextRangesAttribute as CFString, from: element),
              let ranges = rangesValue as? NSArray else {
            return .unsupported
        }

        let resolvedRanges = selectedRanges ?? extractSelectedTextRanges(from: element)
        var fragments: [String] = []

        for range in ranges {
            guard let rangeValue = range as AnyObject? else { continue }
            if let text = stringForRange(rangeValue, in: element) {
                fragments.append(text)
            }
        }

        let combined = fragments.joined()
        let resolvedRange = resolvedRanges.count == 1 ? resolvedRanges[0] : nil

        return makeSelectionEvidence(
            text: combined.isEmpty ? nil : combined,
            range: resolvedRange,
            rangeIsAuthoritative: true
        )
    }

    private func selectedTextRangeEvidence(from element: AXUIElement) -> AXSelectionEvidence {
        guard let rangeValue = copyAttributeValue(kAXSelectedTextRangeAttribute as CFString, from: element) else {
            return .unsupported
        }

        return makeSelectionEvidence(
            text: stringForRange(rangeValue, in: element),
            range: textSelectionRange(from: rangeValue),
            rangeIsAuthoritative: true
        )
    }

    private func selectedTextMarkerRangeEvidence(from element: AXUIElement) -> AXSelectionEvidence {
        guard let markerRange = copyAttributeValue(AXTextMarkerAttributes.selectedRange as CFString, from: element) else {
            return .unsupported
        }

        return makeSelectionEvidence(
            text: stringForTextMarkerRange(markerRange, in: element),
            range: nil,
            rangeIsAuthoritative: false
        )
    }

    private func stringForTextMarkerRange(_ markerRange: AnyObject, in element: AXUIElement) -> String? {
        var attributedValue: AnyObject?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            AXTextMarkerAttributes.attributedStringForRange as CFString,
            markerRange,
            &attributedValue
        )
        guard result == .success, let attributedValue else { return nil }

        if let text = attributedValue as? String, !text.isEmpty {
            return text
        }

        let attributedString = attributedValue as? NSAttributedString
        let text = attributedString?.string ?? ""
        return text.isEmpty ? nil : text
    }

    private func textFromValue(_ value: AnyObject) -> String? {
        if let text = value as? String, !text.isEmpty {
            return text
        }

        let attributedString = value as? NSAttributedString
        let text = attributedString?.string ?? ""
        return text.isEmpty ? nil : text
    }

    private func stringForRange(_ rangeValue: AnyObject, in element: AXUIElement) -> String? {
        var textValue: AnyObject?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &textValue
        )
        guard result == .success, let textValue else { return nil }

        if let text = textValue as? String, !text.isEmpty {
            return text
        }

        let attributedString = textValue as? NSAttributedString
        let text = attributedString?.string ?? ""
        return text.isEmpty ? nil : text
    }

    private func makeSelectionEvidence(
        text: String?,
        range: AXTextSelectionRange?,
        rangeIsAuthoritative: Bool
    ) -> AXSelectionEvidence {
        if rangeIsAuthoritative, let range {
            guard range.length > 0 else {
                return .empty
            }
            return .nonEmpty(text: text, range: range)
        }

        if let text, !text.isEmpty {
            return .nonEmpty(text: text, range: range)
        }

        if let range, range.length > 0 {
            return .nonEmpty(text: text, range: range)
        }

        return .empty
    }

    private func textSelectionRange(from value: AnyObject) -> AXTextSelectionRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return AXTextSelectionRange(location: range.location, length: range.length)
    }

    private func extractSelectedTextRanges(from element: AXUIElement) -> [AXTextSelectionRange] {
        guard let rangesValue = copyAttributeValue(kAXSelectedTextRangesAttribute as CFString, from: element),
              let ranges = rangesValue as? NSArray else {
            return []
        }

        return ranges.compactMap { range in
            guard let rangeValue = range as AnyObject? else { return nil }
            return textSelectionRange(from: rangeValue)
        }
    }

    private func extractSelectedTextRange(from element: AXUIElement) -> AXTextSelectionRange? {
        if let rangeValue = copyAttributeValue(kAXSelectedTextRangeAttribute as CFString, from: element),
           let range = textSelectionRange(from: rangeValue) {
            return range
        }

        let ranges = extractSelectedTextRanges(from: element)
        guard ranges.count == 1 else { return nil }
        return ranges[0]
    }

    private func boundsForSelectedTextRange(in element: AXUIElement) -> CGRect? {
        guard let rangeValue = copyAttributeValue(kAXSelectedTextRangeAttribute as CFString, from: element) else {
            return nil
        }
        return bounds(
            for: rangeValue,
            parameterizedAttribute: kAXBoundsForRangeParameterizedAttribute as CFString,
            in: element
        )
    }

    private func boundsForSelectedTextMarkerRange(in element: AXUIElement) -> CGRect? {
        guard let markerRange = copyAttributeValue(AXTextMarkerAttributes.selectedRange as CFString, from: element) else {
            return nil
        }
        return bounds(
            for: markerRange,
            parameterizedAttribute: AXTextMarkerAttributes.boundsForRange as CFString,
            in: element
        )
    }

    private func bounds(for parameter: AnyObject, parameterizedAttribute: CFString, in element: AXUIElement) -> CGRect? {
        var boundsValue: AnyObject?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            parameterizedAttribute,
            parameter,
            &boundsValue
        )
        guard result == .success, let boundsValue else { return nil }

        if CFGetTypeID(boundsValue) == AXValueGetTypeID() {
            let axValue = boundsValue as! AXValue
            var rect = CGRect.zero
            guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
            return rect
        }

        if let value = boundsValue as? NSValue {
            return value.rectValue
        }

        return nil
    }

    private func copyAttributeValue(_ attribute: CFString, from element: AXUIElement) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value
    }

    private func attributeStringValue(_ attribute: CFString, from element: AXUIElement) -> String? {
        textValue(from: copyAttributeValue(attribute, from: element))
    }

    private func copyFocusedApplicationPID(from systemWide: AXUIElement) -> pid_t? {
        guard let focusedApp = copyAttributeValue(kAXFocusedApplicationAttribute as CFString, from: systemWide) else {
            return nil
        }
        let appElement = focusedApp as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(appElement, &pid) == .success else { return nil }
        return pid
    }

    func replacementTextAreaValue(in processIdentifier: pid_t, expectedFocusedElementID: Int) -> String? {
        guard isTrusted, expectedFocusedElementID != 0,
              let context = focusedElementContext(for: processIdentifier),
              Int(CFHash(context.element)) == expectedFocusedElementID,
              attributeStringValue(kAXRoleAttribute as CFString, from: context.element) == kAXTextAreaRole,
              isAttributeSettable(kAXValueAttribute as CFString, on: context.element) else { return nil }
        return editableTextValue(from: context.element)
    }

    func setSelectedTextRange(_ range: AXTextSelectionRange, for selection: TextSelection) -> Bool {
        guard isTrusted else { return false }
        guard let snapshot = selectionSnapshot(in: selection.sourceAppPID),
              Self.isReplacementContextValid(selection: selection, snapshot: snapshot),
              let context = focusedElementContext(for: selection.sourceAppPID),
              Self.isDirectReplacementContextValid(
                  expectedFocusedElementID: selection.focusedElementID,
                  currentFocusedElementID: Int(CFHash(context.element)),
                  preferredSelectionRange: range,
                  currentSelectionRange: extractSelectedTextRange(from: context.element)
              ) else { return false }
        return setSelectedTextRange(range, on: context.element)
    }

    func replaceSelectedText(
        with text: String,
        in processIdentifier: pid_t?,
        expectedFocusedElementID: Int,
        preferredSelectionRange: AXTextSelectionRange?,
        expectedSelectedText: String
    ) -> Bool {
        guard isTrusted, !text.isEmpty else { return false }
        guard let preferredSelectionRange, preferredSelectionRange.isNonEmpty else { return false }
        guard let context = focusedElementContext(for: processIdentifier) else { return false }

        let element = context.element
        guard Self.isDirectReplacementContextValid(
            expectedFocusedElementID: expectedFocusedElementID,
            currentFocusedElementID: Int(CFHash(element)),
            preferredSelectionRange: preferredSelectionRange,
            currentSelectionRange: extractSelectedTextRange(from: element)
        ) else {
            return false
        }
        guard let currentValue = editableTextValue(from: element) else { return false }
        guard isAttributeSettable(kAXValueAttribute as CFString, on: element),
              isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element),
              let replacement = Self.replacingValue(
                  currentValue,
                  replacing: preferredSelectionRange,
                  with: text,
                  expectedSelectedText: expectedSelectedText
              ) else {
            return false
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              let currentContext = focusedElementContext(for: processIdentifier),
              CFEqual(currentContext.element, element),
              extractSelectedTextRange(from: element) == preferredSelectionRange,
              editableTextValue(from: element) == currentValue else { return false }

        let writeResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            replacement.updatedValue as CFTypeRef
        )
        guard writeResult == .success else { return false }

        if !setSelectedTextRange(replacement.insertionRange, on: element) {
            Log.accessibility.warning("AX replace updated value but failed to collapse insertion range")
        }

        return true
    }

    private func copyFocusedElement(from rootElement: AXUIElement) -> AXUIElement? {
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            rootElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard focusResult == .success else { return nil }
        return focusedElement as! AXUIElement?
    }

    private func textValue(from value: AnyObject?) -> String? {
        if let text = value as? String {
            return text
        }
        if let attributedText = value as? NSAttributedString {
            return attributedText.string
        }
        return nil
    }

    private func editableTextValue(from element: AXUIElement) -> String? {
        textValue(from: copyAttributeValue(kAXValueAttribute as CFString, from: element))
    }

    private func setSelectedTextRange(_ range: AXTextSelectionRange, on element: AXUIElement) -> Bool {
        guard range.isValid,
              isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element),
              let rangeValue = axValue(for: range) else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )
        return result == .success
    }

    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute, &isSettable)
        return result == .success && isSettable.boolValue
    }

    private func axValue(for range: AXTextSelectionRange) -> AXValue? {
        var cfRange = range.cfRange
        return AXValueCreate(.cfRange, &cfRange)
    }
}
