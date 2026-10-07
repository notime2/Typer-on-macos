// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit

@MainActor
@Observable
final class AutoDetectCoordinator {
    private let environment: AppEnvironment
    private weak var panelVisibility: (any PanelVisibilityProvider)?

    var onSelectionDetected: ((SelectionCaptureResult) -> Void)?
    var onSelectionCleared: (() -> Void)?

    private var autoDetectEnabled: Bool
    private var autoShowWork: (any SelectionScheduledWork)?
    private let scheduler: any SelectionScheduler
    private var showGeneration = 0
    private var autoDetectRetryWork: DispatchWorkItem?
    private var autoDetectObserver: Any?
    private var appDidBecomeActiveObserver: Any?
    private(set) var isStarted = false

    private static let minSelectionLength = 3
    private static let autoShowDelay: TimeInterval = 0.3
    private static let lowConfidenceConfirmationDelay: TimeInterval = 0.12
    private static let autoDetectRetryDelay: TimeInterval = 2

    init(environment: AppEnvironment, panelVisibility: any PanelVisibilityProvider,
         scheduler: any SelectionScheduler = DispatchSelectionScheduler()) {
        self.scheduler = scheduler
        self.environment = environment
        self.panelVisibility = panelVisibility
        self.autoDetectEnabled = UserDefaults.standard.autoDetectSelectionEnabled
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        startAutoDetection()

        autoDetectObserver = NotificationCenter.default.addObserver(
            forName: .autoDetectSelectionChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.setEnabled(UserDefaults.standard.autoDetectSelectionEnabled)
            }
        }

        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Log.accessibility.info("App became active, re-checking auto-detection")
                self.startAutoDetection()
            }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        autoShowWork?.cancel()
        autoShowWork = nil
        autoDetectRetryWork?.cancel()
        autoDetectRetryWork = nil

        if let autoDetectObserver {
            NotificationCenter.default.removeObserver(autoDetectObserver)
            self.autoDetectObserver = nil
        }
        if let appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
            self.appDidBecomeActiveObserver = nil
        }

        stopAutoDetection()
    }

    func setEnabled(_ enabled: Bool) {
        autoDetectEnabled = enabled
        UserDefaults.standard.setAutoDetectSelectionEnabled(enabled)

        if enabled {
            startAutoDetection()
            return
        }

        stopAutoDetection()
        onSelectionCleared?()
        autoDetectRetryWork?.cancel()
        autoDetectRetryWork = nil
        Log.accessibility.info("Auto-detection paused")
    }

    func cancelPendingSelectionWork() {
        showGeneration += 1
        autoShowWork?.cancel()
        autoShowWork = nil
    }

    // MARK: - Private

    private func startAutoDetection() {
        guard autoDetectEnabled else {
            stopAutoDetection()
            return
        }

        autoDetectRetryWork?.cancel()
        autoDetectRetryWork = nil

        environment.accessibilityManager.checkPermission()

        guard environment.accessibilityManager.isTrusted else {
            scheduleAutoDetectionRetry(reason: "permission-not-granted")
            return
        }

        guard let observer = environment.textSelectionObserver else {
            Log.accessibility.warning("Auto-detection skipped: text observer unavailable")
            scheduleAutoDetectionRetry(reason: "observer-unavailable")
            return
        }

        bindAutoDetectionCallbacks(to: observer)
        observer.installEventMonitor(environment.selectionEventMonitor)
        observer.installAXNotificationMonitor(environment.selectionNotificationMonitor)
        environment.selectionEventMonitor?.start()
        environment.selectionNotificationMonitor?.start()

        if observer.isPolling {
            Log.accessibility.info("Auto-detection already running")
            return
        }

        observer.startPolling()
        Log.accessibility.info("Auto-detection started")
    }

    private func stopAutoDetection() {
        cancelPendingSelectionWork()

        if let observer = environment.textSelectionObserver {
            observer.onSelectionChanged = nil
            observer.onSelectionCleared = nil
            observer.installEventMonitor(nil)
            observer.installAXNotificationMonitor(nil)
            observer.stopPolling()
        }

        environment.selectionEventMonitor?.stop()
        environment.selectionNotificationMonitor?.stop()
    }

    func bindAutoDetectionCallbacks(to observer: TextSelectionObserver) {
        observer.onSelectionChanged = { [weak self] result in
            guard let self,
                  self.autoDetectEnabled,
                  self.panelVisibility?.isProcessingActive != true,
                  self.panelVisibility?.isChatVisible != true else { return }
            guard result.selection.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minSelectionLength else {
                self.cancelPendingSelectionWork()
                self.onSelectionCleared?()
                return
            }

            self.cancelPendingSelectionWork()

            if result.confidence == .low {
                self.scheduleLowConfidenceToolbarShow(for: result)
                return
            }

            if result.captureMode == .event {
                self.showToolbarIfSelectionStillCurrent(result)
            } else {
                let generation = self.showGeneration
                self.autoShowWork = self.scheduler.schedule(after: Self.autoShowDelay) { [weak self] in
                    guard let self, self.showGeneration == generation else { return }
                    self.showToolbarIfSelectionStillCurrent(result)
                }
            }
        }

        observer.onSelectionCleared = { [weak self] in
            guard let self else { return }
            self.cancelPendingSelectionWork()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let obs = self.environment.textSelectionObserver,
                      obs.currentSelection == nil else { return }
                Log.accessibility.info("Dismissing toolbar after selection cleared")
                self.onSelectionCleared?()
            }
        }
    }

    private func scheduleLowConfidenceToolbarShow(for result: SelectionCaptureResult) {
        let generation = showGeneration
        autoShowWork = scheduler.schedule(after: Self.lowConfidenceConfirmationDelay) { [weak self] in
            guard let self, self.showGeneration == generation,
                  let observer = self.environment.textSelectionObserver else { return }
            observer.confirmSelectionCapture(result) { [weak self] confirmed in
                guard let self, self.showGeneration == generation, let confirmed else { return }
                self.showToolbarIfSelectionStillCurrent(confirmed)
            }
        }
    }

    private func showToolbarIfSelectionStillCurrent(_ result: SelectionCaptureResult) {
        guard autoDetectEnabled, panelVisibility?.isProcessingActive != true,
              panelVisibility?.isChatVisible != true else {
            Log.accessibility.info("Suppressing toolbar show while another panel is visible: \(result.logSummary)")
            return
        }

        guard let observer = environment.textSelectionObserver,
              let currentCaptureResult = observer.currentCaptureResult,
              observer.isCurrentSourceApplication(currentCaptureResult.selection.sourceAppPID),
              currentCaptureResult.selection.sourceAppPID == result.selection.sourceAppPID,
              currentCaptureResult.focusedElementID == result.focusedElementID,
              currentCaptureResult.selection.text == result.selection.text else {
            Log.accessibility.info("Suppressing toolbar show for stale capture: \(result.logSummary)")
            return
        }

        Log.accessibility.info("Showing toolbar: \(result.logSummary)")
        onSelectionDetected?(currentCaptureResult)
    }

    private func scheduleAutoDetectionRetry(reason: String) {
        let retryDelay = Self.autoDetectRetryDelay

        autoDetectRetryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoDetectRetryWork = nil
            self.startAutoDetection()
        }
        autoDetectRetryWork = work

        Log.accessibility.info("Auto-detection retry in \(retryDelay)s (\(reason))")
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
    }
}
