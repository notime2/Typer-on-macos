// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import ApplicationServices

enum SelectionEvidenceSource: String, Sendable, CaseIterable {
    case ranges
    case range
    case marker
    case raw
}

enum SelectionConfidence: String, Sendable {
    case high
    case low
}

enum SelectionCaptureMode: String, Sendable {
    case event
    case polling
    case explicit
}

enum SelectionEvidenceState: String, Sendable {
    case unsupported
    case empty
    case nonEmpty

    init(_ evidence: AXSelectionEvidence) {
        if evidence.isNonEmpty {
            self = .nonEmpty
        } else if evidence.isExplicitlyEmpty {
            self = .empty
        } else {
            self = .unsupported
        }
    }
}

struct SelectionEvidenceStates: Sendable, Equatable {
    let ranges: SelectionEvidenceState
    let range: SelectionEvidenceState
    let marker: SelectionEvidenceState
    let raw: SelectionEvidenceState

    init(
        ranges: SelectionEvidenceState,
        range: SelectionEvidenceState,
        marker: SelectionEvidenceState,
        raw: SelectionEvidenceState
    ) {
        self.ranges = ranges
        self.range = range
        self.marker = marker
        self.raw = raw
    }

    init(snapshot: AXTextSelectionSnapshot) {
        self.ranges = SelectionEvidenceState(snapshot.selectedTextRangesEvidence)
        self.range = SelectionEvidenceState(snapshot.selectedTextRangeEvidence)
        self.marker = SelectionEvidenceState(snapshot.selectedTextMarkerRangeEvidence)
        self.raw = SelectionEvidenceState(snapshot.rawSelectedTextEvidence)
    }

    func state(for source: SelectionEvidenceSource) -> SelectionEvidenceState {
        switch source {
        case .ranges:
            ranges
        case .range:
            range
        case .marker:
            marker
        case .raw:
            raw
        }
    }

    var logSummary: String {
        "ranges=\(ranges.rawValue), range=\(range.rawValue), marker=\(marker.rawValue), raw=\(raw.rawValue)"
    }
}

struct SelectionCaptureResult: Sendable {
    let selection: TextSelection
    let appBundleIdentifier: String?
    let appProfileID: String
    let captureMode: SelectionCaptureMode
    let winningEvidenceSource: SelectionEvidenceSource
    let allEvidenceStates: SelectionEvidenceStates
    let confidence: SelectionConfidence
    let boundsMode: AccessibilityManager.SelectionBoundsCoordinateMode
    let focusedElementID: Int

    var logSummary: String {
        let bundle = appBundleIdentifier ?? "unknown"
        return "bundle=\(bundle) profile=\(appProfileID) mode=\(captureMode.rawValue) winning=\(winningEvidenceSource.rawValue) confidence=\(confidence.rawValue) states=\(allEvidenceStates.logSummary)"
    }
}

struct SelectionAppProfile: Sendable, Equatable {
    let id: String
    let evidencePrecedence: [SelectionEvidenceSource]
    let allowsRawOnlyAutoShow: Bool
    let requiresDoubleConfirmation: Bool
    let boundsMode: AccessibilityManager.SelectionBoundsCoordinateMode

    static func resolve(for snapshot: AXTextSelectionSnapshot) -> SelectionAppProfile {
        let fallbackBoundsMode = snapshot.boundsMode
        let bundleIdentifier = snapshot.appBundleIdentifier
        let loweredBundleIdentifier = bundleIdentifier?.lowercased()
        let role = snapshot.focusedElementRole?.lowercased() ?? ""
        let subrole = snapshot.focusedElementSubrole?.lowercased() ?? ""

        if isTelegramBundleIdentifier(loweredBundleIdentifier) {
            return SelectionAppProfile(
                id: "telegram-editor",
                evidencePrecedence: [.ranges, .range, .raw, .marker],
                allowsRawOnlyAutoShow: true,
                requiresDoubleConfirmation: true,
                boundsMode: fallbackBoundsMode
            )
        }

        if isSafari(loweredBundleIdentifier) {
            return SelectionAppProfile(
                id: "safari-web",
                evidencePrecedence: [.marker, .ranges, .range, .raw],
                allowsRawOnlyAutoShow: true,
                requiresDoubleConfirmation: false,
                boundsMode: .topLeftNeedsConversion
            )
        }

        if isElectron(loweredBundleIdentifier) {
            return SelectionAppProfile(
                id: "electron-editor",
                evidencePrecedence: [.ranges, .range, .raw, .marker],
                allowsRawOnlyAutoShow: true,
                requiresDoubleConfirmation: true,
                boundsMode: .alreadyAppKit
            )
        }

        if isChromium(bundleIdentifier) {
            return SelectionAppProfile(
                id: "chromium-browser",
                evidencePrecedence: [.ranges, .range, .marker, .raw],
                allowsRawOnlyAutoShow: true,
                requiresDoubleConfirmation: false,
                boundsMode: .alreadyAppKit
            )
        }

        if role.contains("webarea") {
            return SelectionAppProfile(
                id: "unknown",
                evidencePrecedence: [.marker, .ranges, .range, .raw],
                allowsRawOnlyAutoShow: true,
                requiresDoubleConfirmation: true,
                boundsMode: fallbackBoundsMode
            )
        }

        if isCocoaEditor(role: role, subrole: subrole, isValueAttributeWritable: snapshot.isValueAttributeWritable) {
            return SelectionAppProfile(
                id: "cocoa-editor",
                evidencePrecedence: [.ranges, .range, .marker, .raw],
                allowsRawOnlyAutoShow: true,
                requiresDoubleConfirmation: false,
                boundsMode: .topLeftNeedsConversion
            )
        }

        return SelectionAppProfile(
            id: "unknown",
            evidencePrecedence: [.ranges, .range, .marker, .raw],
            allowsRawOnlyAutoShow: true,
            requiresDoubleConfirmation: true,
            boundsMode: fallbackBoundsMode
        )
    }

    private static func isSafari(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.apple.safari"
            || bundleIdentifier.hasPrefix("com.apple.webkit")
    }

    private static func isChromium(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return AccessibilityManager.coordinateMode(forBundleIdentifier: bundleIdentifier) == .alreadyAppKit
            && !isElectron(bundleIdentifier)
    }

    private static func isElectron(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.anthropic.claudefordesktop"
            || bundleIdentifier == "com.github.electron"
            || bundleIdentifier == "com.microsoft.vscode"
            || bundleIdentifier == "com.tinyspeck.slackmacgap"
            || bundleIdentifier == "com.getpostman.postman"
            || bundleIdentifier == "notion.id"
            || bundleIdentifier.contains(".electron.")
            || bundleIdentifier.contains(".electron")
            || bundleIdentifier.contains("electron.")
    }

    static func isTelegramBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "ru.keepcoder.telegram"
            || bundleIdentifier == "ru.keepcoder.telegram-desktop"
            || bundleIdentifier.contains("telegram")
    }

    private static func isCocoaEditor(role: String, subrole: String, isValueAttributeWritable: Bool) -> Bool {
        guard isValueAttributeWritable else { return false }
        return role.contains("text")
            || role.contains("field")
            || role.contains("area")
            || subrole.contains("text")
            || subrole.contains("document")
    }
}

struct SelectionCaptureEngine {
    func resolveCaptureResult(
        from snapshot: AXTextSelectionSnapshot,
        mode: SelectionCaptureMode
    ) -> SelectionCaptureResult? {
        let profile = SelectionAppProfile.resolve(for: snapshot)
        let winningEvidenceSource = resolveWinningEvidenceSource(snapshot: snapshot, profile: profile)

        guard let winningEvidenceSource,
              let text = text(for: winningEvidenceSource, in: snapshot),
              !text.isEmpty else {
            return nil
        }

        let confidence = resolveConfidence(
            winningEvidenceSource: winningEvidenceSource,
            snapshot: snapshot,
            profile: profile
        )

        let selection = TextSelection(
            text: text,
            cursorPosition: snapshot.cursorPosition,
            selectionBounds: snapshot.selectionBounds,
            selectedTextRange: snapshot.selectedTextRange,
            selectedTextRanges: snapshot.selectedTextRanges,
            focusedElementID: snapshot.focusedElementID,
            sourceAppPID: snapshot.sourceAppPID,
            appBundleIdentifier: snapshot.appBundleIdentifier,
            appProfileID: profile.id,
            hasDiscontiguousSelection: snapshot.hasDiscontiguousSelection,
            captureConfidence: confidence,
            winningEvidenceSource: winningEvidenceSource
        )

        return SelectionCaptureResult(
            selection: selection,
            appBundleIdentifier: snapshot.appBundleIdentifier,
            appProfileID: profile.id,
            captureMode: mode,
            winningEvidenceSource: winningEvidenceSource,
            allEvidenceStates: SelectionEvidenceStates(snapshot: snapshot),
            confidence: confidence,
            boundsMode: profile.boundsMode,
            focusedElementID: snapshot.focusedElementID
        )
    }

    func makeClipboardFallbackResult(
        selection: TextSelection,
        mode: SelectionCaptureMode
    ) -> SelectionCaptureResult {
        SelectionCaptureResult(
            selection: selection,
            appBundleIdentifier: selection.appBundleIdentifier,
            appProfileID: selection.appProfileID ?? "clipboard-fallback",
            captureMode: mode,
            winningEvidenceSource: selection.winningEvidenceSource ?? .raw,
            allEvidenceStates: SelectionEvidenceStates(
                ranges: .unsupported,
                range: .unsupported,
                marker: .unsupported,
                raw: .nonEmpty
            ),
            confidence: selection.captureConfidence ?? .low,
            boundsMode: .topLeftNeedsConversion,
            focusedElementID: selection.focusedElementID
        )
    }

    private func resolveWinningEvidenceSource(
        snapshot: AXTextSelectionSnapshot,
        profile: SelectionAppProfile
    ) -> SelectionEvidenceSource? {
        for source in profile.evidencePrecedence {
            guard let readableText = text(for: source, in: snapshot), !readableText.isEmpty else { continue }
            switch source {
            case .ranges:
                if snapshot.selectedTextRangesEvidence.isNonEmpty { return .ranges }
            case .range:
                if snapshot.selectedTextRangeEvidence.isNonEmpty { return .range }
            case .marker:
                if snapshot.selectedTextMarkerRangeEvidence.isNonEmpty { return .marker }
            case .raw:
                if snapshot.rawSelectedTextEvidence.isNonEmpty { return .raw }
            }
        }

        if snapshot.rawSelectedTextEvidence.isNonEmpty {
            return .raw
        }

        return nil
    }

    private func text(
        for source: SelectionEvidenceSource,
        in snapshot: AXTextSelectionSnapshot
    ) -> String? {
        switch source {
        case .ranges:
            snapshot.selectedTextRangesEvidence.text
                ?? snapshot.rawSelectedText
        case .range:
            snapshot.selectedTextRangeEvidence.text
                ?? snapshot.rawSelectedText
        case .marker:
            snapshot.selectedTextMarkerRangeEvidence.text
                ?? snapshot.rawSelectedText
        case .raw:
            snapshot.rawSelectedText
        }
    }

    private func resolveConfidence(
        winningEvidenceSource: SelectionEvidenceSource,
        snapshot: AXTextSelectionSnapshot,
        profile: SelectionAppProfile
    ) -> SelectionConfidence {
        if profile.requiresDoubleConfirmation {
            return .low
        }

        switch winningEvidenceSource {
        case .ranges, .range:
            return .high
        case .marker:
            return profile.id == "safari-web" ? .high : .low
        case .raw:
            if !profile.allowsRawOnlyAutoShow {
                return .low
            }

            if snapshot.hasExplicitlyEmptyRangeBackedEvidence || snapshot.hasSupportedRangeBackedEvidence {
                return .low
            }

            return .low
        }
    }
}
