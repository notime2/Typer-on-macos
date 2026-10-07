// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import ApplicationServices

enum AXSelectionReadOutcome: Sendable {
    case snapshot(AXTextSelectionSnapshot)
    case cleared
    case unavailable(focusedElementID: Int?)
}

struct AXSelectionReadContext: Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let cursorPosition: CGPoint
    let screenFrames: [CGRect]
    let primaryScreenFrame: CGRect?
}

/// AX references never leave this serial queue. AppKit state is captured by the caller.
final class AXSelectionReader: Sendable {
    private let queue = DispatchQueue(label: "typer-on.selection-reader", qos: .userInitiated)
    private let manualAccessibilityActivator: AXManualAccessibilityActivator

    init(manualAccessibilityActivator: AXManualAccessibilityActivator = .shared) {
        self.manualAccessibilityActivator = manualAccessibilityActivator
    }

    func read(_ context: AXSelectionReadContext) async -> AXSelectionReadOutcome {
        await withCheckedContinuation { continuation in
            queue.async { [manualAccessibilityActivator] in
                // Before the snapshot starts so the one-time IPC does not consume its read budget.
                manualAccessibilityActivator.prepare(pid: context.processIdentifier, bundleIdentifier: context.bundleIdentifier)
                let reader = SnapshotRead(context: context)
                continuation.resume(returning: reader.read())
            }
        }
    }

    static func canUseSelectionEvidence(raw: AXSelectionEvidence, ranges: [AXSelectionEvidence],
                                        hadUnavailableRead: Bool) -> Bool {
        guard ([raw] + ranges).contains(where: \.isSupported) else { return false }
        guard hadUnavailableRead else { return true }
        // Partial failures cannot establish deselection. A readable, nonempty source
        // may still win, with the observer retaining its existing conflict precedence.
        guard ([raw] + ranges).contains(where: { $0.text != nil }) else { return false }
        return ranges.contains(where: \.isNonEmpty) || !ranges.contains(where: \.isExplicitlyEmpty)
    }

    static func resolveFocusedElement<Element>(
        requestedPID: pid_t,
        preferredRead: () -> Element?,
        systemWideRead: () -> Element?,
        ownerPID: (Element) -> pid_t?
    ) -> Element? {
        if let preferred = preferredRead() { return preferred }
        guard let fallback = systemWideRead(), ownerPID(fallback) == requestedPID else { return nil }
        return fallback
    }

    static func markerEvidence(value: AnyObject?, error: AXError) -> (evidence: AXSelectionEvidence, unavailable: Bool) {
        switch error {
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .noValue:
            return (.unsupported, false)
        case .success:
            guard let text = (value as? String) ?? (value as? NSAttributedString)?.string else {
                return (.unsupported, true)
            }
            return (text.isEmpty ? .empty : .nonEmpty(text: text, range: nil), false)
        default:
            return (.unsupported, true)
        }
    }

    private final class SnapshotRead {
        let context: AXSelectionReadContext
        let started = ProcessInfo.processInfo.systemUptime
        var unavailable = false
        var lastAttributeError: AXError = .success
        var lastParameterError: AXError = .success

        init(context: AXSelectionReadContext) { self.context = context }

        private func canRead() -> Bool {
            guard ProcessInfo.processInfo.systemUptime - started < 0.1 else {
                unavailable = true
                return false
            }
            return true
        }

        private func check(_ error: AXError) {
            if error != .success && error != .attributeUnsupported
                && error != .parameterizedAttributeUnsupported && error != .noValue {
                unavailable = true
            }
        }

        private func attribute(_ name: CFString, _ element: AXUIElement) -> AnyObject? {
            guard canRead() else { return nil }
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(element, name, &value)
            lastAttributeError = error
            check(error)
            return error == .success ? value : nil
        }

        private func parameter(_ name: CFString, _ value: AnyObject, _ element: AXUIElement) -> AnyObject? {
            // Budget exhaustion must not reuse a previous successful/unsupported result.
            lastParameterError = .cannotComplete
            guard canRead() else { return nil }
            var result: AnyObject?
            let error = AXUIElementCopyParameterizedAttributeValue(element, name, value, &result)
            lastParameterError = error
            check(error)
            return error == .success ? result : nil
        }

        private func text(_ value: AnyObject?) -> String? {
            if let string = value as? String { return string }
            return (value as? NSAttributedString)?.string
        }

        private func range(_ value: AnyObject?) -> AXTextSelectionRange? {
            guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            let axValue = value as! AXValue
            var range = CFRange()
            guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range),
                  range.location >= 0, range.length >= 0 else { return nil }
            return AXTextSelectionRange(location: range.location, length: range.length)
        }

        private func rangeEvidence(_ value: AnyObject?, _ element: AXUIElement) -> AXSelectionEvidence {
            guard let value, let range = range(value) else { return .unsupported }
            guard range.length > 0 else { return .empty }
            return .nonEmpty(text: text(parameter(kAXStringForRangeParameterizedAttribute as CFString, value, element)), range: range)
        }

        private func bounds(_ value: AnyObject?) -> CGRect? {
            guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
            return rect
        }

        private func focusedElement(from root: AXUIElement) -> AXUIElement? {
            AXUIElementSetMessagingTimeout(root, 0.05)
            guard let value = attribute(kAXFocusedUIElementAttribute as CFString, root),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return value as! AXUIElement
        }

        func read() -> AXSelectionReadOutcome {
            let focused = AXSelectionReader.resolveFocusedElement(
                requestedPID: context.processIdentifier,
                preferredRead: { self.focusedElement(from: AXUIElementCreateApplication(self.context.processIdentifier)) },
                systemWideRead: {
                    guard self.canRead() else { return nil }
                    return self.focusedElement(from: AXUIElementCreateSystemWide())
                },
                ownerPID: { element in
                    guard self.canRead() else { return nil }
                    var pid: pid_t = 0
                    let error = AXUIElementGetPid(element, &pid)
                    self.check(error)
                    return error == .success ? pid : nil
                }
            )
            guard let element = focused else {
                return !unavailable && lastAttributeError == .noValue ? .cleared : .unavailable(focusedElementID: nil)
            }
            // A successful fallback recovers the failed preferred lookup. Both used
            // the same queue and budget; subsequent evidence tracks its own failures.
            unavailable = false
            AXUIElementSetMessagingTimeout(element, 0.05)
            let focusedID = Int(CFHash(element))
            let rawValue = attribute(kAXSelectedTextAttribute as CFString, element)
            let rangesValue = attribute(kAXSelectedTextRangesAttribute as CFString, element) as? [AnyObject]
            let rangeValue = attribute(kAXSelectedTextRangeAttribute as CFString, element)
            let markerValue = attribute(AXTextMarkerAttributes.selectedRange as CFString, element)
            let ranges = rangesValue?.compactMap { range($0) } ?? []

            var rangesEvidence: AXSelectionEvidence = .unsupported
            if let rangesValue {
                let evidences = rangesValue.map { rangeEvidence($0, element) }
                if evidences.contains(where: \.isNonEmpty) {
                    let fragments = evidences.compactMap(\.text).joined()
                    rangesEvidence = .nonEmpty(text: fragments.isEmpty ? nil : fragments,
                                              range: ranges.count == 1 ? ranges[0] : nil)
                } else {
                    rangesEvidence = .empty
                }
            }
            let singleRange = range(rangeValue)
            let singleEvidence: AXSelectionEvidence
            if let singleRange, ranges.count == 1, ranges[0] == singleRange {
                singleEvidence = rangesEvidence
            } else {
                singleEvidence = rangeEvidence(rangeValue, element)
            }
            var markerEvidence: AXSelectionEvidence = .unsupported
            if let markerValue {
                let markerText = parameter(AXTextMarkerAttributes.attributedStringForRange as CFString, markerValue, element)
                let result = AXSelectionReader.markerEvidence(value: markerText, error: lastParameterError)
                markerEvidence = result.evidence
                unavailable = unavailable || result.unavailable
            }
            let rawText = text(rawValue)
            let rawEvidence: AXSelectionEvidence = rawValue == nil ? .unsupported
                : (rawText?.isEmpty == false ? .nonEmpty(text: rawText, range: nil) : .empty)
            guard AXSelectionReader.canUseSelectionEvidence(
                raw: rawEvidence, ranges: [rangesEvidence, singleEvidence, markerEvidence],
                hadUnavailableRead: unavailable
            ) else { return .unavailable(focusedElementID: focusedID) }
            let hasSelection = [rawEvidence, rangesEvidence, singleEvidence, markerEvidence].contains(where: \.isNonEmpty)
            var selectionBounds: CGRect?
            if hasSelection {
                if let rangeValue, singleRange?.length ?? 0 > 0 {
                    selectionBounds = bounds(parameter(kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, element))
                }
                if selectionBounds == nil, let markerValue {
                    selectionBounds = bounds(parameter(AXTextMarkerAttributes.boundsForRange as CFString, markerValue, element))
                }
            }
            let role = text(attribute(kAXRoleAttribute as CFString, element))
            let subrole = text(attribute(kAXSubroleAttribute as CFString, element))
            var writable = DarwinBoolean(false)
            if canRead() { check(AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &writable)) }
            let mode = AccessibilityManager.coordinateMode(forBundleIdentifier: context.bundleIdentifier)
            return .snapshot(AXTextSelectionSnapshot(
                rawSelectedTextEvidence: rawEvidence,
                selectedTextRangesEvidence: rangesEvidence,
                selectedTextRangeEvidence: singleEvidence,
                selectedTextMarkerRangeEvidence: markerEvidence,
                selectedTextRanges: ranges,
                cursorPosition: context.cursorPosition,
                selectionBounds: selectionBounds.flatMap {
                    AccessibilityManager.resolveSelectionBounds(
                        axRect: $0,
                        screenFrames: context.screenFrames,
                        primaryScreenFrame: context.primaryScreenFrame,
                        mode: mode
                    )
                },
                sourceAppPID: context.processIdentifier,
                appBundleIdentifier: context.bundleIdentifier,
                focusedElementRole: role,
                focusedElementSubrole: subrole,
                isValueAttributeWritable: writable.boolValue,
                boundsMode: mode,
                focusedElementID: focusedID
            ))
        }
    }
}
