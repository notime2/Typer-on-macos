// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Combine

struct TextSelection: Sendable {
    let text: String
    let cursorPosition: NSPoint
    let selectionBounds: NSRect?
    let selectedTextRange: AXTextSelectionRange?
    let selectedTextRanges: [AXTextSelectionRange]
    let focusedElementID: Int
    let sourceAppPID: pid_t?
    let appBundleIdentifier: String?
    let appProfileID: String?
    let hasDiscontiguousSelection: Bool
    let captureConfidence: SelectionConfidence?
    let winningEvidenceSource: SelectionEvidenceSource?
    let capturedAt: Date

    init(
        text: String,
        cursorPosition: NSPoint,
        selectionBounds: NSRect? = nil,
        selectedTextRange: AXTextSelectionRange? = nil,
        selectedTextRanges: [AXTextSelectionRange] = [],
        focusedElementID: Int = 0,
        sourceAppPID: pid_t? = nil,
        appBundleIdentifier: String? = nil,
        appProfileID: String? = nil,
        hasDiscontiguousSelection: Bool = false,
        captureConfidence: SelectionConfidence? = nil,
        winningEvidenceSource: SelectionEvidenceSource? = nil,
        capturedAt: Date = Date()
    ) {
        self.text = text
        self.cursorPosition = cursorPosition
        self.selectionBounds = selectionBounds
        self.selectedTextRange = selectedTextRange
        self.selectedTextRanges = selectedTextRanges
        self.focusedElementID = focusedElementID
        self.sourceAppPID = sourceAppPID
        self.appBundleIdentifier = appBundleIdentifier
        self.appProfileID = appProfileID
        self.hasDiscontiguousSelection = hasDiscontiguousSelection
        self.captureConfidence = captureConfidence
        self.winningEvidenceSource = winningEvidenceSource
        self.capturedAt = capturedAt
    }
}

extension TextSelection {
    var supportsDirectAccessibilityReplace: Bool {
        selectedTextRange != nil && !hasDiscontiguousSelection
    }
}

@MainActor
@Observable
final class TextSelectionObserver {
    private static let explicitCaptureAutoClearGracePeriod: TimeInterval = 0.75

    typealias SelectionSnapshotReader = (pid_t?) -> AXTextSelectionSnapshot?
    typealias ClipboardSelectionCapture = (pid_t?) async -> TextSelection?
    typealias BundleIdentifierReader = (pid_t?) -> String?

    private struct ActiveSelectionState: Equatable {
        let text: String
        let selectedTextRange: AXTextSelectionRange?
        let sourceAppPID: pid_t?
        let focusedElementID: Int
        let appProfileID: String
        let winningEvidenceSource: SelectionEvidenceSource
    }

    private struct ResolvedSelection {
        let state: ActiveSelectionState
        let result: SelectionCaptureResult
    }

    private struct ReadOnlyClipboardSource: Equatable {
        let pid: pid_t
        let focusedElementID: Int
        let bundleIdentifier: String

        init?(_ snapshot: AXTextSelectionSnapshot?) {
            guard let snapshot, let pid = snapshot.sourceAppPID, pid > 0,
                  snapshot.focusedElementID != 0,
                  snapshot.appBundleIdentifier?.lowercased() == "one.ayugram.ayugramdesktop",
                  snapshot.focusedElementRole == "AXStaticText", !snapshot.isValueAttributeWritable else { return nil }
            self.pid = pid
            focusedElementID = snapshot.focusedElementID
            bundleIdentifier = "one.ayugram.AyuGramDesktop"
        }

        func matches(_ selection: TextSelection) -> Bool {
            selection.sourceAppPID == pid && selection.focusedElementID == focusedElementID
                && selection.appBundleIdentifier?.lowercased() == bundleIdentifier.lowercased()
        }
    }

    private struct ExplicitTelegramHoldState: Equatable {
        let text: String
        let sourceAppPID: pid_t?
        let focusedElementID: Int
        let bundleIdentifier: String?
        let appProfileID: String
        let readOnlyClipboardSource: ReadOnlyClipboardSource?
        var hasExhaustedRecovery = false

        func matches(_ result: SelectionCaptureResult) -> Bool {
            guard text == result.selection.text,
                  sourceAppPID == result.selection.sourceAppPID else {
                return false
            }

            if focusedElementID != 0,
               result.focusedElementID != 0,
               focusedElementID != result.focusedElementID {
                return false
            }

            guard let bundleIdentifier else {
                return true
            }

            guard let resultBundleIdentifier = result.selection.appBundleIdentifier?.lowercased() else {
                return true
            }

            return bundleIdentifier == resultBundleIdentifier
        }
    }

    private enum SelectionCheckSource: Equatable {
        case event
        case polling
        case axNotification(AXMonitoredNotification)

        var priority: Int {
            switch self {
            case .event: 2
            case .axNotification: 1
            case .polling: 0
            }
        }

        var logOrigin: String {
            switch self {
            case .event: "physical-event"
            case .polling: "polling"
            case .axNotification(let notification): notification.rawValue
            }
        }
    }

    private enum SnapshotEvaluation {
        case active(ResolvedSelection)
        case cleared
        case unavailable
    }

    private let accessibilityManager: AccessibilityManager
    private let clipboardManager: ClipboardManager
    private let selectionSnapshotReader: SelectionSnapshotReader
    private let clipboardSelectionCapture: ClipboardSelectionCapture
    private let bundleIdentifierReader: BundleIdentifierReader
    private let selectionCaptureEngine: SelectionCaptureEngine
    private weak var selectionEventMonitor: SelectionEventMonitor?
    private weak var axNotificationMonitor: AXNotificationMonitor?
    private var pollingTimer: Timer?
    private var eventCheckWork: (any SelectionScheduledWork)?
    private var scheduledCheck: (pid: pid_t, source: SelectionCheckSource)?
    private let scheduler: any SelectionScheduler
    private let automaticSnapshotReader: (AXSelectionReadContext) async -> AXSelectionReadOutcome
    private let frontmostPIDReader: () -> pid_t?
    private var readTask: Task<Void, Never>?
    private var queuedRead: ReadRequest?
    private var activeRead: ReadRequest?
    private var requestGeneration = 0
    private var recoveryWork: [any SelectionScheduledWork] = []
    private var isRecovering = false
    private var recoverySource: SelectionCheckSource = .event
    private var workspaceObserver: Any?

    private struct ReadRequest {
        let pid: pid_t
        let generation: Int
        let source: SelectionCheckSource
        var confirmation: SelectionCaptureResult?
        var completion: ((SelectionCaptureResult?) -> Void)?
    }
    private var lastActiveSelectionState: ActiveSelectionState?
    private var lastNotifiedCaptureMode: SelectionCaptureMode?
    private var automaticClearSuppressionDeadline: Date = .distantPast
    private var explicitTelegramHoldState: ExplicitTelegramHoldState?

    private(set) var currentSelection: TextSelection?
    private(set) var currentCaptureResult: SelectionCaptureResult?
    var onSelectionChanged: ((SelectionCaptureResult) -> Void)?
    var onSelectionCleared: (() -> Void)?

    var isPolling: Bool { pollingTimer != nil }

    init(
        accessibilityManager: AccessibilityManager,
        clipboardManager: ClipboardManager,
        selectionSnapshotReader: SelectionSnapshotReader? = nil,
        clipboardSelectionCapture: ClipboardSelectionCapture? = nil,
        bundleIdentifierReader: BundleIdentifierReader? = nil,
        selectionCaptureEngine: SelectionCaptureEngine = SelectionCaptureEngine(),
        scheduler: any SelectionScheduler = DispatchSelectionScheduler(),
        automaticSnapshotReader: ((AXSelectionReadContext) async -> AXSelectionReadOutcome)? = nil,
        frontmostPIDReader: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    ) {
        self.accessibilityManager = accessibilityManager
        self.clipboardManager = clipboardManager
        self.selectionCaptureEngine = selectionCaptureEngine
        self.scheduler = scheduler
        self.frontmostPIDReader = frontmostPIDReader
        if let automaticSnapshotReader {
            self.automaticSnapshotReader = automaticSnapshotReader
        } else if let selectionSnapshotReader {
            self.automaticSnapshotReader = { context in
                selectionSnapshotReader(context.processIdentifier).map(AXSelectionReadOutcome.snapshot)
                    ?? .unavailable(focusedElementID: nil)
            }
        } else {
            let reader = AXSelectionReader()
            self.automaticSnapshotReader = { context in await reader.read(context) }
        }
        let resolvedBundleIdentifierReader = bundleIdentifierReader ?? { processIdentifier in
            guard let processIdentifier else { return nil }
            return NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
        }
        self.bundleIdentifierReader = resolvedBundleIdentifierReader
        self.selectionSnapshotReader = selectionSnapshotReader ?? { processIdentifier in
            accessibilityManager.selectionSnapshot(in: processIdentifier)
        }
        self.clipboardSelectionCapture = clipboardSelectionCapture ?? { preferredSourceAppPID in
            await Self.captureViaClipboard(
                preferredSourceAppPID: preferredSourceAppPID,
                clipboardManager: clipboardManager,
                bundleIdentifierReader: resolvedBundleIdentifierReader
            )
        }
    }

    func startPolling(interval: TimeInterval = 0.24) {
        stopPolling()

        pollingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkSelection()
            }
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sourceApplicationChanged() }
        }
        Log.accessibility.info("Selection polling started (interval: \(interval)s)")
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        eventCheckWork?.cancel()
        eventCheckWork = nil
        invalidateAutomaticReads()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    func captureSelection(preferredSourceAppPID: pid_t? = nil) async -> TextSelection? {
        invalidateAutomaticReads()
        lastNotifiedCaptureMode = nil
        var readOnlyClipboardSource: ReadOnlyClipboardSource?
        if let resolvedSelection = resolvedSelectionForExplicitCapture(
            preferredSourceAppPID: preferredSourceAppPID, readOnlyClipboardSource: &readOnlyClipboardSource
        ) {
            currentSelection = resolvedSelection.result.selection
            currentCaptureResult = resolvedSelection.result
            lastActiveSelectionState = resolvedSelection.state
            updateExplicitCaptureState(
                result: resolvedSelection.result,
                preferredSourceAppPID: preferredSourceAppPID
            )
            Log.accessibility.info("Explicit capture resolved: \(resolvedSelection.result.logSummary)")
            return resolvedSelection.result.selection
        }

        if let source = readOnlyClipboardSource {
            guard preferredSourceAppPID == nil || preferredSourceAppPID == source.pid,
                  isCurrentReadOnlyClipboardSource(source) else {
                resetSelectionState()
                onSelectionCleared?()
                return nil
            }
        }
        guard let selection = await clipboardSelectionCapture(preferredSourceAppPID) else {
            return nil
        }

        var resolvedSelection = selectionByResolvingSourceContext(
            selection,
            preferredSourceAppPID: preferredSourceAppPID
        )
        if let source = readOnlyClipboardSource {
            guard isCurrentReadOnlyClipboardSource(source),
                  selection.sourceAppPID == nil || selection.sourceAppPID == source.pid,
                  selection.focusedElementID == 0 || selection.focusedElementID == source.focusedElementID,
                  selection.appBundleIdentifier == nil || selection.appBundleIdentifier?.lowercased() == source.bundleIdentifier.lowercased() else {
                resetSelectionState()
                onSelectionCleared?()
                return nil
            }
            invalidateAutomaticReads()
            // The AX zero range describes this read-only surface, not the private clipboard selection.
            resolvedSelection = TextSelection(
                text: selection.text, cursorPosition: selection.cursorPosition, selectionBounds: selection.selectionBounds,
                focusedElementID: source.focusedElementID, sourceAppPID: source.pid,
                appBundleIdentifier: source.bundleIdentifier, appProfileID: "clipboard-fallback",
                captureConfidence: .low, winningEvidenceSource: .raw, capturedAt: selection.capturedAt
            )
        }

        currentSelection = resolvedSelection
        let captureResult = selectionCaptureEngine.makeClipboardFallbackResult(
            selection: resolvedSelection,
            mode: .explicit
        )
        currentCaptureResult = captureResult
        lastActiveSelectionState = nil
        updateExplicitCaptureState(
            result: captureResult,
            preferredSourceAppPID: preferredSourceAppPID,
            readOnlyClipboardSource: readOnlyClipboardSource
        )
        return resolvedSelection
    }

    private func isCurrentReadOnlyClipboardSource(_ source: ReadOnlyClipboardSource) -> Bool {
        guard frontmostPIDReader() == source.pid else { return false }
        let snapshot = selectionSnapshotReader(source.pid)
        return frontmostPIDReader() == source.pid && ReadOnlyClipboardSource(snapshot) == source
    }

    func dismissExplicitSelectionHold() {
        guard explicitTelegramHoldState != nil else { return }
        let deduplicationState = lastActiveSelectionState
        invalidateAutomaticReads()
        resetSelectionState()
        // A readable, unchanged editor selection must not re-open the toolbar on the next poll.
        lastActiveSelectionState = deduplicationState
        onSelectionCleared?()
    }

    func installEventMonitor(_ eventMonitor: SelectionEventMonitor?) {
        selectionEventMonitor?.onPotentialSelectionChange = nil
        selectionEventMonitor = eventMonitor
        selectionEventMonitor?.onPotentialSelectionChange = { [weak self] pid in
            self?.checkSelectionFromEvent(frontmostPID: pid)
        }
    }

    func installAXNotificationMonitor(_ notificationMonitor: AXNotificationMonitor?) {
        axNotificationMonitor?.onPotentialSelectionChange = nil
        axNotificationMonitor?.onFocusedElementChanged = nil
        axNotificationMonitor = notificationMonitor
        axNotificationMonitor?.onFocusedElementChanged = { [weak self] pid, focusedID in
            guard let self, self.frontmostPIDReader() == pid else { return }
            let alreadyCaptured = focusedID != nil && focusedID != 0
                && self.currentSelection?.sourceAppPID == pid
                && self.currentSelection?.focusedElementID == focusedID
            Log.accessibility.debug("AX focus subscription updated: pid=\(pid) matchesCurrentCapture=\(alreadyCaptured)")
            guard !alreadyCaptured else { return }
            // A deferred subscription result may predate explicit capture. Only
            // a fresh snapshot may clear the currently held focused identity.
            self.checkSelectionFromAXNotification(frontmostPID: pid, notification: .focusedUIElementChanged)
        }
        axNotificationMonitor?.onPotentialSelectionChange = { [weak self] pid, notification in
            self?.checkSelectionFromAXNotification(frontmostPID: pid, notification: notification)
        }
    }

    func checkSelectionFromEvent(frontmostPID: pid_t) {
        scheduleSelectionCheck(frontmostPID: frontmostPID, source: .event)
    }

    private func checkSelectionFromAXNotification(frontmostPID: pid_t, notification: AXMonitoredNotification) {
        guard frontmostPIDReader() == frontmostPID else { return }
        let scheduledPhysical = scheduledCheck?.pid == frontmostPID && scheduledCheck?.source == .event
        let activePhysical = activeRead?.pid == frontmostPID && activeRead?.generation == requestGeneration
            && activeRead?.source == .event
        let queuedPhysical = queuedRead?.pid == frontmostPID && queuedRead?.generation == requestGeneration
            && queuedRead?.source == .event
        let physicalHoldRecovery = isRecovering && recoverySource == .event
            && explicitTelegramHoldState?.readOnlyClipboardSource != nil
        let protectsReadOnlyHold = currentSelection.map {
            explicitTelegramHoldState?.readOnlyClipboardSource?.matches($0) == true
        } ?? false
        guard !protectsReadOnlyHold || (!scheduledPhysical && !activePhysical && !queuedPhysical && !physicalHoldRecovery) else {
            Log.accessibility.debug("AX notification deferred to physical selection work: type=\(notification.rawValue, privacy: .public)")
            return
        }
        scheduleSelectionCheck(frontmostPID: frontmostPID, source: .axNotification(notification))
    }

    private func scheduleSelectionCheck(frontmostPID: pid_t, source: SelectionCheckSource) {
        guard frontmostPIDReader() == frontmostPID else { return }
        requestGeneration += 1
        let generation = requestGeneration
        eventCheckWork?.cancel()
        scheduledCheck = (frontmostPID, source)
        eventCheckWork = scheduler.schedule(after: 0.05) { [weak self] in
            guard let self, self.requestGeneration == generation else { return }
            self.eventCheckWork = nil
            self.scheduledCheck = nil
            guard self.frontmostPIDReader() == frontmostPID else { return }
            self.performSelectionCheck(frontmostPID: frontmostPID, source: source)
        }
    }

    private func checkSelection() {
        guard eventCheckWork == nil else { return }
        performSelectionCheck(frontmostPID: frontmostPIDReader(), source: .polling)
    }

    func isCurrentSourceApplication(_ pid: pid_t?) -> Bool { pid == frontmostPIDReader() }

    func sourceApplicationChanged() {
        invalidateAutomaticReads()
        if currentSelection?.sourceAppPID != frontmostPIDReader() {
            resetSelectionState()
            onSelectionCleared?()
        }
        checkSelection()
    }

    private func invalidateAutomaticReads() {
        requestGeneration += 1
        queuedRead?.completion?(nil)
        queuedRead = nil
        eventCheckWork?.cancel()
        eventCheckWork = nil
        scheduledCheck = nil
        cancelRecovery()
    }

    func confirmSelectionCapture(_ pendingResult: SelectionCaptureResult) -> SelectionCaptureResult? {
        lastNotifiedCaptureMode = nil
        let snapshot = selectionSnapshotReader(pendingResult.selection.sourceAppPID)
            ?? selectionSnapshotReader(nil)

        guard case .active(let resolvedSelection) = evaluateSnapshot(
            snapshot,
            allowStaleFallbackText: false,
            captureMode: pendingResult.captureMode
        ) else {
            lastActiveSelectionState = nil
            return nil
        }

        guard resolvedSelection.result.selection.sourceAppPID == pendingResult.selection.sourceAppPID,
              resolvedSelection.result.focusedElementID == pendingResult.focusedElementID,
              resolvedSelection.result.selection.text == pendingResult.selection.text else {
            return nil
        }

        cancelRecovery()
        currentSelection = resolvedSelection.result.selection
        currentCaptureResult = resolvedSelection.result
        lastActiveSelectionState = resolvedSelection.state
        if explicitTelegramHoldState?.matches(resolvedSelection.result) == true {
            explicitTelegramHoldState = makeExplicitTelegramHoldState(
                result: resolvedSelection.result,
                preferredSourceAppPID: pendingResult.selection.sourceAppPID,
                readOnlyClipboardSource: matchingReadOnlyClipboardSource(snapshot, result: resolvedSelection.result)
            )
            return resolvedSelection.result
        }

        explicitTelegramHoldState = nil
        automaticClearSuppressionDeadline = .distantPast
        return resolvedSelection.result
    }

    func confirmSelectionCapture(
        _ pendingResult: SelectionCaptureResult,
        completion: @escaping (SelectionCaptureResult?) -> Void
    ) {
        guard let pid = pendingResult.selection.sourceAppPID, frontmostPIDReader() == pid else {
            completion(nil)
            return
        }
        enqueueRead(ReadRequest(pid: pid, generation: requestGeneration, source: .event,
                                confirmation: pendingResult, completion: completion))
    }

    private func performSelectionCheck(frontmostPID: pid_t?, source: SelectionCheckSource) {
        guard let pid = frontmostPID, pid > 0 else { return }
        enqueueRead(ReadRequest(pid: pid, generation: requestGeneration, source: source))
    }

    private func enqueueRead(_ request: ReadRequest) {
        if readTask != nil {
            // Polls may replace polls, but cannot discard an outstanding confirmation.
            if queuedRead?.confirmation != nil && queuedRead?.generation == request.generation && request.confirmation == nil { return }
            if let queuedRead, queuedRead.generation == request.generation, queuedRead.pid == request.pid,
               queuedRead.source.priority > request.source.priority, request.confirmation == nil { return }
            queuedRead?.completion?(nil)
            queuedRead = request
            return
        }
        let screens = NSScreen.screens
        let context = AXSelectionReadContext(
            processIdentifier: request.pid, bundleIdentifier: bundleIdentifierReader(request.pid),
            cursorPosition: NSEvent.mouseLocation, screenFrames: screens.map(\.frame),
            primaryScreenFrame: screens.first?.frame
        )
        activeRead = request
        readTask = Task { [weak self, automaticSnapshotReader] in
            let outcome = await automaticSnapshotReader(context)
            guard let self else { return }
            self.readTask = nil
            self.activeRead = nil
            if self.requestGeneration == request.generation, self.frontmostPIDReader() == request.pid {
                if let pending = request.confirmation {
                    self.applyConfirmation(outcome, pending: pending, request: request)
                } else {
                    self.applyReadOutcome(outcome, pid: request.pid, source: request.source)
                }
            } else {
                request.completion?(nil)
            }
            if let queued = self.queuedRead {
                self.queuedRead = nil
                if queued.generation == self.requestGeneration, self.frontmostPIDReader() == queued.pid {
                    self.enqueueRead(queued)
                } else { queued.completion?(nil) }
            }
        }
    }

    private func applyConfirmation(_ outcome: AXSelectionReadOutcome, pending: SelectionCaptureResult, request: ReadRequest) {
        lastNotifiedCaptureMode = nil
        if case .snapshot(let snapshot) = outcome,
           case .active(let resolved) = evaluateSnapshot(snapshot, allowStaleFallbackText: false, captureMode: pending.captureMode),
           resolved.result.selection.sourceAppPID == pending.selection.sourceAppPID,
           resolved.result.focusedElementID == pending.focusedElementID,
           resolved.result.selection.text == pending.selection.text {
            cancelRecovery()
            if explicitTelegramHoldState?.matches(resolved.result) == true {
                explicitTelegramHoldState = makeExplicitTelegramHoldState(
                    result: resolved.result, preferredSourceAppPID: request.pid,
                    readOnlyClipboardSource: matchingReadOnlyClipboardSource(snapshot, result: resolved.result)
                )
            } else {
                explicitTelegramHoldState = nil
            }
            currentSelection = resolved.result.selection
            currentCaptureResult = resolved.result
            lastActiveSelectionState = resolved.state
            request.completion?(resolved.result)
        } else {
            // Let the next successful sample rediscover this exact same selection.
            lastActiveSelectionState = nil
            applyReadOutcome(outcome, pid: request.pid, source: request.source)
            request.completion?(nil)
        }
    }

    /// A held clipboard-fallback capture has no focused element (ID 0). That is unknown, not a focus change;
    /// the snapshot/clear rules of the hold still decide. Non-held captures keep the conservative clear.
    private var heldFocusIsUnknown: Bool {
        explicitTelegramHoldState != nil && currentSelection?.focusedElementID == 0
    }

    private func applyReadOutcome(_ outcome: AXSelectionReadOutcome, pid: pid_t, source: SelectionCheckSource) {
        switch outcome {
        case .snapshot(let snapshot):
            guard snapshot.sourceAppPID == pid else { return }
            if let previous = currentSelection, !heldFocusIsUnknown,
               previous.focusedElementID != snapshot.focusedElementID {
                resetSelectionState()
                onSelectionCleared?()
            }
            applySelectionCheckSnapshot(snapshot, frontmostPID: pid, source: source)
        case .cleared:
            // Apps without a focused element report this on every poll; notify only when state existed.
            let hadSelectionState = currentSelection != nil || lastActiveSelectionState != nil
                || explicitTelegramHoldState != nil
            resetSelectionState()
            if hadSelectionState { onSelectionCleared?() }
        case .unavailable(let focusedID):
            if let previous = currentSelection,
               previous.sourceAppPID != pid
                || (focusedID != nil && !heldFocusIsUnknown && focusedID != previous.focusedElementID) {
                resetSelectionState()
                onSelectionCleared?()
            } else {
                beginRecovery(pid: pid, source: source, allowWithoutSelection: source == .event)
            }
        }
    }

    private func beginRecovery(pid: pid_t?, source: SelectionCheckSource, allowWithoutSelection: Bool = false) {
        guard currentSelection != nil || allowWithoutSelection else { return }
        if isRecovering {
            // A real event can strengthen the remaining resamples without moving their deadlines.
            if source == .event { recoverySource = .event }
            return
        }
        guard explicitTelegramHoldState?.hasExhaustedRecovery != true, let pid else { return }
        isRecovering = true
        // Preserve passive provenance only for the verified read-only hold.
        // Genuine input and existing Telegram/editor recovery remain authoritative.
        recoverySource = source != .event
            && explicitTelegramHoldState?.readOnlyClipboardSource != nil ? source : .event
        // This window is anchored to the first failure; subsequent failures never extend it.
        for delay in [0.1, 0.25] {
            recoveryWork.append(scheduler.schedule(after: delay) { [weak self] in
                guard let self, self.isRecovering, self.frontmostPIDReader() == pid else { return }
                self.performSelectionCheck(frontmostPID: pid, source: self.recoverySource)
            })
        }
        recoveryWork.append(scheduler.schedule(after: 0.5) { [weak self] in
            guard let self, self.isRecovering else { return }
            if self.explicitTelegramHoldState != nil,
               self.currentSelection?.sourceAppPID == pid,
               self.frontmostPIDReader() == pid {
                // Keep explicitly captured context, not evidence that a replacement target is still current.
                self.explicitTelegramHoldState?.hasExhaustedRecovery = true
                self.cancelRecovery()
                return
            }
            let hadSelection = self.currentSelection != nil
            self.resetSelectionState()
            if hadSelection { self.onSelectionCleared?() }
        })
    }

    private func cancelRecovery() {
        recoveryWork.forEach { $0.cancel() }
        recoveryWork.removeAll()
        isRecovering = false
        recoverySource = .event
    }

    private func applySelectionCheckSnapshot(
        _ snapshot: AXTextSelectionSnapshot?,
        frontmostPID: pid_t?,
        source: SelectionCheckSource
    ) {
        if let snapshot, let heldSource = explicitTelegramHoldState?.readOnlyClipboardSource,
           ReadOnlyClipboardSource(snapshot) != heldSource {
            resetSelectionState()
            Log.accessibility.info("Selection hold cleared after read-only source identity changed")
            onSelectionCleared?()
        }
        switch evaluateSnapshot(
            snapshot,
            allowStaleFallbackText: false,
            captureMode: selectionCaptureMode(for: source)
        ) {
        case .active(let resolvedSelection):
            cancelRecovery()
            let readOnlySource = matchingReadOnlyClipboardSource(snapshot, result: resolvedSelection.result)
            if explicitTelegramHoldState?.matches(resolvedSelection.result) == true {
                explicitTelegramHoldState = makeExplicitTelegramHoldState(
                    result: resolvedSelection.result,
                    preferredSourceAppPID: frontmostPID,
                    readOnlyClipboardSource: readOnlySource
                )
            } else {
                explicitTelegramHoldState = nil
            }

            currentSelection = resolvedSelection.result.selection
            currentCaptureResult = resolvedSelection.result
            if explicitTelegramHoldState == nil {
                automaticClearSuppressionDeadline = .distantPast
            }
            if readOnlySource != nil {
                // A successful read revalidates the held message; it does not request a new auto-show.
                lastActiveSelectionState = resolvedSelection.state
                return
            }
            // A poll may discover selection before its gesture event arrives. Promote
            // that notification once so the event can replace the pending slow show.
            let promotesPollingCapture = lastNotifiedCaptureMode == .polling && source != .polling
            guard lastActiveSelectionState != resolvedSelection.state || promotesPollingCapture else { return }
            lastActiveSelectionState = resolvedSelection.state
            lastNotifiedCaptureMode = resolvedSelection.result.captureMode
            Log.accessibility.info("Selection capture active: mode=\(resolvedSelection.result.captureMode.rawValue, privacy: .public) confidence=\(resolvedSelection.result.confidence.rawValue, privacy: .public) details=\(resolvedSelection.result.logSummary)")
            onSelectionChanged?(resolvedSelection.result)
        case .cleared:
            clearSelection(frontmostPID: frontmostPID, source: source, snapshot: snapshot)
        case .unavailable:
            beginRecovery(pid: frontmostPID ?? currentSelection?.sourceAppPID, source: source)
        }
    }

    private func clearSelection(frontmostPID: pid_t?, source: SelectionCheckSource, snapshot: AXTextSelectionSnapshot?) {
        guard currentSelection != nil || lastActiveSelectionState != nil else {
            resetSelectionState()
            return
        }

        let resolvedFrontmostPID = frontmostPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let currentSelection,
           let sourceAppPID = currentSelection.sourceAppPID,
           let resolvedFrontmostPID,
           resolvedFrontmostPID != sourceAppPID {
            if explicitTelegramHoldState != nil {
                Log.accessibility.info("released hold on app switch")
            }
            resetSelectionState()
            Log.accessibility.info("Selection cleared because frontmost app changed")
            onSelectionCleared?()
            return
        }

        if explicitTelegramHoldState != nil, source == .polling {
            Log.accessibility.debug("Ignoring polling clear while Telegram explicit hold is active")
            return
        }
        if case .axNotification = source,
           let heldSource = explicitTelegramHoldState?.readOnlyClipboardSource,
           ReadOnlyClipboardSource(snapshot) == heldSource {
            Log.accessibility.debug("Ignoring passive AX clear for verified read-only hold: origin=\(source.logOrigin, privacy: .public)")
            return
        }

        guard !Self.shouldSuppressAutomaticClear(
            currentSelection: currentSelection,
            until: automaticClearSuppressionDeadline
        ) else {
            Log.accessibility.debug("Ignoring transient automatic clear after explicit capture")
            return
        }

        resetSelectionState()
        Log.accessibility.info("Selection cleared: origin=\(source.logOrigin, privacy: .public)")
        onSelectionCleared?()
    }

    private func resolvedSelectionForExplicitCapture(
        preferredSourceAppPID: pid_t?, readOnlyClipboardSource: inout ReadOnlyClipboardSource?
    ) -> ResolvedSelection? {
        if let preferredSourceAppPID {
            let snapshot = selectionSnapshotReader(preferredSourceAppPID)
            if case .active(let resolvedSelection) = evaluateSnapshot(snapshot, allowStaleFallbackText: true, captureMode: .explicit) {
                return resolvedSelection
            }
            readOnlyClipboardSource = ReadOnlyClipboardSource(snapshot)
        }

        let snapshot = selectionSnapshotReader(nil)
        if case .active(let resolvedSelection) = evaluateSnapshot(
            snapshot,
            allowStaleFallbackText: true,
            captureMode: .explicit
        ) {
            return resolvedSelection
        }
        if readOnlyClipboardSource == nil { readOnlyClipboardSource = ReadOnlyClipboardSource(snapshot) }
        return nil
    }

    private func evaluateSnapshot(
        _ snapshot: AXTextSelectionSnapshot?,
        allowStaleFallbackText: Bool,
        captureMode: SelectionCaptureMode
    ) -> SnapshotEvaluation {
        guard let snapshot else {
            return .unavailable
        }

        if snapshot.hasSupportedRangeBackedEvidence {
            if snapshot.hasNonEmptyRangeBackedEvidence {
                guard let resolvedSelection = makeResolvedSelection(
                    from: snapshot,
                    captureMode: captureMode
                ) else {
                    return .unavailable
                }

                if !allowStaleFallbackText,
                   snapshot.hasExplicitlyEmptyRangeBackedEvidence,
                   isStaleConflictingSelection(snapshot, text: resolvedSelection.result.selection.text) {
                    return .cleared
                }

                return .active(resolvedSelection)
            }

            if snapshot.hasExplicitlyEmptyRangeBackedEvidence {
                if allowStaleFallbackText,
                   let resolvedSelection = makeResolvedSelection(
                       from: snapshot,
                       captureMode: captureMode
                   ) {
                    return .active(resolvedSelection)
                }
                return .cleared
            }
        }

        guard let resolvedSelection = makeResolvedSelection(
            from: snapshot,
            captureMode: captureMode
        ) else {
            return .cleared
        }

        return .active(resolvedSelection)
    }

    private func isStaleConflictingSelection(_ snapshot: AXTextSelectionSnapshot, text: String) -> Bool {
        let emptyRangeBackedEvidenceCount = [
            snapshot.selectedTextRangesEvidence,
            snapshot.selectedTextRangeEvidence,
            snapshot.selectedTextMarkerRangeEvidence,
        ]
        .filter { $0.isExplicitlyEmpty }
        .count
        guard emptyRangeBackedEvidenceCount >= 2,
              !snapshot.selectedTextMarkerRangeEvidence.isNonEmpty,
              snapshot.selectedTextRangesEvidence.isNonEmpty || snapshot.selectedTextRangeEvidence.isNonEmpty else {
            return false
        }

        guard let lastActiveSelectionState,
              lastActiveSelectionState.text == text else {
            return false
        }

        if snapshot.focusedElementID == lastActiveSelectionState.focusedElementID {
            if let selectedTextRange = snapshot.selectedTextRange,
               let previousRange = lastActiveSelectionState.selectedTextRange {
                return selectedTextRange == previousRange
            }
            return true
        }

        if let sourceAppPID = snapshot.sourceAppPID,
           let previousSourceAppPID = lastActiveSelectionState.sourceAppPID,
           sourceAppPID == previousSourceAppPID {
            if let selectedTextRange = snapshot.selectedTextRange,
               let previousRange = lastActiveSelectionState.selectedTextRange {
                return selectedTextRange == previousRange
            }
            return true
        }

        return false
    }

    private func makeResolvedSelection(
        from snapshot: AXTextSelectionSnapshot,
        captureMode: SelectionCaptureMode
    ) -> ResolvedSelection? {
        guard let result = selectionCaptureEngine.resolveCaptureResult(
            from: snapshot,
            mode: captureMode
        ) else {
            return nil
        }

        return ResolvedSelection(
            state: makeActiveSelectionState(
                from: snapshot,
                selection: result.selection
            ),
            result: result
        )
    }

    private func makeActiveSelectionState(
        from snapshot: AXTextSelectionSnapshot,
        selection: TextSelection
    ) -> ActiveSelectionState {
        ActiveSelectionState(
            text: selection.text,
            selectedTextRange: snapshot.selectedTextRange,
            sourceAppPID: snapshot.sourceAppPID,
            focusedElementID: snapshot.focusedElementID,
            appProfileID: selection.appProfileID ?? "unknown",
            winningEvidenceSource: selection.winningEvidenceSource ?? .raw
        )
    }

    private func updateExplicitCaptureState(
        result: SelectionCaptureResult,
        preferredSourceAppPID: pid_t?,
        readOnlyClipboardSource: ReadOnlyClipboardSource? = nil
    ) {
        if let holdState = makeExplicitTelegramHoldState(
            result: result,
            preferredSourceAppPID: preferredSourceAppPID,
            readOnlyClipboardSource: readOnlyClipboardSource
        ) {
            explicitTelegramHoldState = holdState
            automaticClearSuppressionDeadline = .distantPast
            Log.accessibility.info("Explicit selection hold activated")
            return
        }

        explicitTelegramHoldState = nil
        suppressAutomaticClearsAfterExplicitCapture(now: result.selection.capturedAt)
    }

    private func makeExplicitTelegramHoldState(
        result: SelectionCaptureResult,
        preferredSourceAppPID: pid_t?,
        readOnlyClipboardSource: ReadOnlyClipboardSource? = nil
    ) -> ExplicitTelegramHoldState? {
        let resolvedBundleIdentifier = resolvedBundleIdentifier(
            for: result.selection,
            preferredSourceAppPID: preferredSourceAppPID
        )?.lowercased()

        guard result.appProfileID == "telegram-editor"
                || SelectionAppProfile.isTelegramBundleIdentifier(resolvedBundleIdentifier)
                || readOnlyClipboardSource?.matches(result.selection) == true else {
            return nil
        }

        return ExplicitTelegramHoldState(
            text: result.selection.text,
            sourceAppPID: result.selection.sourceAppPID ?? preferredSourceAppPID,
            focusedElementID: result.focusedElementID,
            bundleIdentifier: resolvedBundleIdentifier,
            appProfileID: result.appProfileID,
            readOnlyClipboardSource: readOnlyClipboardSource
        )
    }

    private func matchingReadOnlyClipboardSource(
        _ snapshot: AXTextSelectionSnapshot?, result: SelectionCaptureResult
    ) -> ReadOnlyClipboardSource? {
        guard let source = explicitTelegramHoldState?.readOnlyClipboardSource,
              explicitTelegramHoldState?.matches(result) == true,
              ReadOnlyClipboardSource(snapshot) == source else { return nil }
        return source
    }

    private func resolvedBundleIdentifier(
        for selection: TextSelection,
        preferredSourceAppPID: pid_t?
    ) -> String? {
        if let appBundleIdentifier = selection.appBundleIdentifier {
            return appBundleIdentifier
        }

        let sourceAppPID = selection.sourceAppPID
            ?? preferredSourceAppPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        return bundleIdentifierReader(sourceAppPID)
    }

    private func selectionByResolvingSourceContext(
        _ selection: TextSelection,
        preferredSourceAppPID: pid_t?
    ) -> TextSelection {
        let sourceAppPID = selection.sourceAppPID
            ?? preferredSourceAppPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let appBundleIdentifier = selection.appBundleIdentifier
            ?? bundleIdentifierReader(sourceAppPID)

        guard selection.sourceAppPID != sourceAppPID
                || selection.appBundleIdentifier != appBundleIdentifier else {
            return selection
        }

        return TextSelection(
            text: selection.text,
            cursorPosition: selection.cursorPosition,
            selectionBounds: selection.selectionBounds,
            selectedTextRange: selection.selectedTextRange,
            selectedTextRanges: selection.selectedTextRanges,
            focusedElementID: selection.focusedElementID,
            sourceAppPID: sourceAppPID,
            appBundleIdentifier: appBundleIdentifier,
            appProfileID: selection.appProfileID,
            hasDiscontiguousSelection: selection.hasDiscontiguousSelection,
            captureConfidence: selection.captureConfidence,
            winningEvidenceSource: selection.winningEvidenceSource,
            capturedAt: selection.capturedAt
        )
    }

    private func resetSelectionState() {
        cancelRecovery()
        currentSelection = nil
        currentCaptureResult = nil
        lastActiveSelectionState = nil
        lastNotifiedCaptureMode = nil
        automaticClearSuppressionDeadline = .distantPast
        explicitTelegramHoldState = nil
    }

#if DEBUG
    func processReadOutcomeForTesting(_ outcome: AXSelectionReadOutcome, pid: pid_t) {
        applyReadOutcome(outcome, pid: pid, source: .event)
    }

    func pollForTesting() { checkSelection() }

    func waitForPendingSelectionReadForTesting() async {
        while let readTask { await readTask.value }
    }
#endif

    private static func captureViaClipboard(
        preferredSourceAppPID: pid_t? = nil,
        clipboardManager: ClipboardManager,
        bundleIdentifierReader: BundleIdentifierReader
    ) async -> TextSelection? {
        let sourceAppPID = preferredSourceAppPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let previousChangeCount = clipboardManager.changeCount
        let maxWait: TimeInterval = 0.35
        let pollInterval: TimeInterval = 0.025

        clipboardManager.backup()
        KeySimulator.simulateCopy()

        var copiedText: String?
        var copyChangeCount: Int?
        let deadline = Date().addingTimeInterval(maxWait)
        repeat {
            try? await Task.sleep(for: .milliseconds(Int((pollInterval * 1000).rounded())))

            if clipboardManager.changeCount != previousChangeCount {
                copyChangeCount = clipboardManager.changeCount
                copiedText = clipboardManager.currentText
                break
            }
        } while Date() < deadline

        guard let copyChangeCount,
              let text = copiedText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if copyChangeCount == nil {
                Log.accessibility.debug("Clipboard fallback did not detect copy result")
            } else {
                Log.accessibility.debug("Clipboard fallback copied non-string or empty selection")
            }
            if let copyChangeCount {
                clipboardManager.restoreBackupIfUnchanged(expectedChangeCount: copyChangeCount)
            }
            return nil
        }

        clipboardManager.restoreBackupIfUnchanged(expectedChangeCount: copyChangeCount)

        let selection = TextSelection(
            text: text,
            cursorPosition: NSEvent.mouseLocation,
            sourceAppPID: sourceAppPID,
            appBundleIdentifier: bundleIdentifierReader(sourceAppPID),
            appProfileID: "clipboard-fallback",
            captureConfidence: .low,
            winningEvidenceSource: .raw
        )
        return selection
    }

    private func selectionCaptureMode(for source: SelectionCheckSource) -> SelectionCaptureMode {
        switch source {
        case .event, .axNotification:
            .event
        case .polling:
            .polling
        }
    }

    static func shouldSuppressAutomaticClear(
        currentSelection: TextSelection?,
        until deadline: Date,
        now: Date = Date()
    ) -> Bool {
        guard currentSelection != nil else { return false }
        return now < deadline
    }

    private func suppressAutomaticClearsAfterExplicitCapture(now: Date) {
        automaticClearSuppressionDeadline = now.addingTimeInterval(Self.explicitCaptureAutoClearGracePeriod)
    }
}
