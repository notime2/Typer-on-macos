// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI

@MainActor
@Observable
final class AppCoordinator {
    private static let chatModeModuleID = "content-generation"

    let environment: AppEnvironment

    private var floatingToolbarVM: FloatingToolbarViewModel?
    private let panelManager: PanelLifecycleManager
    private let autoDetectCoordinator: AutoDetectCoordinator
    private let chatSelectionCaptureOverride: ((pid_t?) async -> TextSelection?)?
    private var openChatObserver: Any?
    private var selectionTriggerStyleObserver: Any?

    init(
        environment: AppEnvironment,
        chatSelectionCaptureOverride: ((pid_t?) async -> TextSelection?)? = nil
    ) {
        self.environment = environment
        self.panelManager = PanelLifecycleManager(environment: environment)
        self.autoDetectCoordinator = AutoDetectCoordinator(
            environment: environment,
            panelVisibility: panelManager
        )
        self.chatSelectionCaptureOverride = chatSelectionCaptureOverride
    }

    func start() {
        panelManager.setup()
        panelManager.onAutomaticProcessingEvent = { [weak self] event in
            self?.handleAutomaticProcessingEvent(event)
        }

        floatingToolbarVM = FloatingToolbarViewModel(environment: environment)
        floatingToolbarVM?.onModuleInvoked = { [weak self] module, selection in
            self?.presentModule(module, selection: selection) ?? false
        }
        floatingToolbarVM?.onUserDismiss = { [weak self] in
            self?.autoDetectCoordinator.cancelPendingSelectionWork()
            self?.environment.textSelectionObserver?.dismissExplicitSelectionHold()
        }
        floatingToolbarVM?.onProcessingCancel = { [weak self] in
            self?.panelManager.cancelProcessing()
            self?.floatingToolbarVM?.dismissProcessingIndicator()
        }
        floatingToolbarVM?.onProcessingIndicatorFinished = { [weak self] in
            self?.panelManager.completeAutomaticProcessing()
        }

        autoDetectCoordinator.onSelectionDetected = { [weak self] result in
            self?.floatingToolbarVM?.show(for: result.selection, source: .autoDetect)
        }
        autoDetectCoordinator.onSelectionCleared = { [weak self] in
            self?.floatingToolbarVM?.dismissForSelectionChange()
        }
        autoDetectCoordinator.start()

        installCarbonHotkey()

        openChatObserver = NotificationCenter.default.addObserver(
            forName: .openChatRequested, object: nil, queue: .main
        ) { [weak self] notification in
            // Settings -> Chat History names a conversation; onboarding sends no target.
            let target = notification.object as? ChatConversationTarget
            Task { @MainActor [weak self] in
                if let target {
                    self?.openChat(target)
                } else {
                    await self?.openChat()
                }
            }
        }

        selectionTriggerStyleObserver = NotificationCenter.default.addObserver(
            forName: .selectionTriggerStyleChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.floatingToolbarVM?.refreshAppearance()
            }
        }

        Log.app.info("AppCoordinator started")
    }

    // MARK: - Trigger

    func triggerCapture(preferredSourceAppPID: pid_t? = nil) async {
        environment.accessibilityManager.checkPermission()

        guard environment.accessibilityManager.isTrusted else {
            environment.accessibilityManager.requestPermission()
            return
        }

        if floatingToolbarVM?.handleExplicitTriggerIfVisible() == true {
            return
        }

        guard let observer = environment.textSelectionObserver,
              let selection = await observer.captureSelection(preferredSourceAppPID: preferredSourceAppPID) else {
            Log.app.info("No text selected - opening chat")
            panelManager.showChat(.newDraft(pendingSelectionText: nil))
            return
        }

        Log.app.info("Captured selection: \(Self.captureLogMetadata(for: selection))")
        autoDetectCoordinator.cancelPendingSelectionWork()
        floatingToolbarVM?.show(for: selection, source: .explicit)
    }

    func triggerDirectModule(_ moduleId: String, preferredSourceAppPID: pid_t? = nil) async {
        environment.accessibilityManager.checkPermission()

        guard environment.accessibilityManager.isTrusted else {
            environment.accessibilityManager.requestPermission()
            return
        }

        guard let observer = environment.textSelectionObserver,
              let selection = await observer.captureSelection(preferredSourceAppPID: preferredSourceAppPID) else {
            panelManager.showChat(.newDraft(pendingSelectionText: nil))
            return
        }

        guard let module = environment.moduleRegistry.module(byId: moduleId) else { return }

        presentModule(module, selection: selection)
    }

    func openChat(preferredSourceAppPID: pid_t? = nil) async {
        let selection = if let chatSelectionCaptureOverride {
            await chatSelectionCaptureOverride(preferredSourceAppPID)
        } else {
            await captureSelectionForChat(preferredSourceAppPID: preferredSourceAppPID)
        }
        panelManager.showChat(
            selection.map { .newDraft(pendingSelectionText: $0.text) } ?? .continueCurrentOrMostRecent
        )
    }

    /// Opens a saved conversation or a new chat without capturing a selection.
    func openChat(_ target: ChatConversationTarget) {
        panelManager.showChat(target)
    }

    // MARK: - Global Hotkey (Carbon)

    private var currentCombo: KeyCombo {
        KeyCombo.load() ?? KeyCombo.defaultGlobalHotkey
    }

    private func installCarbonHotkey() {
        guard let manager = environment.hotkeyManager else {
            Log.hotkeys.warning("HotkeyManager unavailable - skipping hotkey install")
            return
        }

        manager.onHotkey = { [weak self] id in
            guard id == "globalTrigger" else { return }
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            Task { @MainActor [weak self] in
                await self?.triggerCapture(preferredSourceAppPID: frontmostPID)
            }
        }

        do {
            try manager.start()
            let combo = currentCombo
            try manager.applyRegistrations([
                HotkeyRegistration(id: "globalTrigger", combo: combo)
            ])
            Log.hotkeys.info("Carbon global hotkey installed: \(combo.displayString)")
        } catch {
            Log.hotkeys.error("Failed to install Carbon hotkey: \(error)")
        }
    }

    func stop() {
        environment.hotkeyManager?.onHotkey = nil
        environment.hotkeyManager?.stop()

        floatingToolbarVM?.dismiss()
        floatingToolbarVM?.onModuleInvoked = nil
        floatingToolbarVM = nil

        panelManager.teardown()
        panelManager.onAutomaticProcessingEvent = nil
        autoDetectCoordinator.stop()

        if let openChatObserver {
            NotificationCenter.default.removeObserver(openChatObserver)
            self.openChatObserver = nil
        }

        if let selectionTriggerStyleObserver {
            NotificationCenter.default.removeObserver(selectionTriggerStyleObserver)
            self.selectionTriggerStyleObserver = nil
        }
    }

    @discardableResult
    private func presentModule(_ module: any TextModule, selection: TextSelection) -> Bool {
        if module.id == Self.chatModeModuleID {
            panelManager.showChat(.newDraft(pendingSelectionText: selection.text))
            return false
        }

        let shouldAutoReplace = environment.moduleAIConfig(for: module.id)?.autoReplaceOriginalText == true
        let mode: ProcessingMode = shouldAutoReplace ? .automaticReplacement : .review

        if shouldAutoReplace {
            floatingToolbarVM?.beginProcessingIndicator(
                for: selection,
                source: floatingToolbarVM?.presentationSource ?? .explicit
            )
        }

        panelManager.showProcessing(module: module, selection: selection, mode: mode)
        return shouldAutoReplace
    }

    private func handleAutomaticProcessingEvent(_ event: AutomaticProcessingEvent) {
        switch event {
        case .replaceStarted:
            floatingToolbarVM?.markProcessingReplacementStarted()
        case .succeeded:
            floatingToolbarVM?.showProcessingSuccess()
        case .requiresPresentation:
            floatingToolbarVM?.dismissProcessingIndicator()
        }
    }

    private func captureSelectionForChat(preferredSourceAppPID: pid_t?) async -> TextSelection? {
        environment.accessibilityManager.checkPermission()

        guard environment.accessibilityManager.isTrusted,
              let observer = environment.textSelectionObserver else {
            return nil
        }

        return await observer.captureSelection(preferredSourceAppPID: preferredSourceAppPID)
    }

    nonisolated static func captureLogMetadata(for selection: TextSelection) -> String {
        let source = selection.winningEvidenceSource?.rawValue ?? "unknown"
        let confidence = selection.captureConfidence?.rawValue ?? "unknown"
        let bundleIdentifier = selection.appBundleIdentifier ?? "unknown"
        return "utf16len=\(selection.text.utf16.count) pid=\(selection.sourceAppPID ?? -1) bundle=\(bundleIdentifier) confidence=\(confidence) source=\(source)"
    }

#if DEBUG
    var panelManagerForTesting: PanelLifecycleManager {
        panelManager
    }

    func presentModuleForTesting(_ module: any TextModule, selection: TextSelection) {
        _ = presentModule(module, selection: selection)
    }
#endif
}
