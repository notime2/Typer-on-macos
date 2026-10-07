// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI

@MainActor
@Observable
final class PanelLifecycleManager: PanelVisibilityProvider {
    private let environment: AppEnvironment
    private(set) var processingVM: ProcessingViewModel?
    private(set) var chatVM: ChatViewModel?
    private(set) var processingPanel: ProcessingPanel?
    private(set) var chatPanel: ChatPanel?
    private(set) var isProcessingVisible = false
    private(set) var isProcessingActive = false
    private(set) var isChatVisible = false
    var onAutomaticProcessingEvent: ((AutomaticProcessingEvent) -> Void)?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func setup() {
        guard processingVM == nil, chatVM == nil else { return }

        processingVM = ProcessingViewModel(
            environment: environment,
            aiServiceProvider: { [environment] in environment.requestAIService }
        )
        chatVM = ChatViewModel(
            environment: environment,
            aiServiceProvider: { [environment] in environment.requestAIService },
            cachedModelProvider: { [environment] in
                environment.isStreamReplay ? nil : environment.modelCatalog.model(for: $0)
            },
            modelResolver: { [environment] modelID, apiKey in
                guard !environment.isStreamReplay else { return nil }
                return await environment.modelCatalog.resolveModel(for: modelID, apiKey: apiKey)
            }
        )

        processingVM?.onDismiss = { [weak self] in
            self?.dismissProcessing()
        }
        processingVM?.onAutomaticProcessingEvent = { [weak self] event in
            self?.handleAutomaticProcessingEvent(event)
        }
        processingVM?.onOpenChat = { [weak self] target in
            self?.showChat(target)
        }

        chatVM?.onDismiss = { [weak self] in
            self?.dismissChat()
        }
    }

    func showProcessing(
        module: any TextModule,
        selection: TextSelection,
        mode: ProcessingMode = .review
    ) {
        guard let processingVM else { return }

        isProcessingActive = true

        if mode == .automaticReplacement {
            processingPanel?.hideAndReleaseContent()
            isProcessingVisible = false
        } else {
            showProcessingPanel()
        }

        processingVM.process(module: module, selection: selection, mode: mode)
    }

    func dismissProcessing() {
        processingPanel?.dismiss()
        isProcessingVisible = false
        isProcessingActive = false
    }

    func cancelProcessing() {
        processingVM?.dismiss()
    }

    func completeAutomaticProcessing() {
        guard isProcessingVisible == false else { return }
        isProcessingActive = false
    }

    func showChat(_ target: ChatConversationTarget) {
        guard let chatVM else { return }

        NSApp.activate(ignoringOtherApps: true)
        chatVM.presentConversation(target)

        if isChatVisible {
            chatPanel?.makeKeyAndOrderFront(nil)
            chatVM.requestInputFocus()
            return
        }

        if chatPanel == nil {
            let panel = ChatPanel()
            panel.onEscape = { [weak self] in
                self?.chatVM?.dismiss()
            }
            chatPanel = panel
        }

        let hostingView = NSHostingView(
            rootView: DialogThemeRoot { ChatView(viewModel: chatVM) }
        )

        chatPanel?.contentView = hostingView
        chatPanel?.showCentered(on: NSScreen.screenContainingCursor)
        chatVM.requestInputFocus()
        isChatVisible = true
    }

    func dismissChat() {
        chatPanel?.dismiss()
        isChatVisible = false
    }

    func teardown() {
        processingVM?.cancel()
        processingVM?.onDismiss = nil
        processingVM?.onAutomaticProcessingEvent = nil
        processingVM?.onOpenChat = nil
        processingVM = nil
        processingPanel?.hideAndReleaseContent()
        processingPanel = nil
        isProcessingVisible = false
        isProcessingActive = false

        chatVM?.reset()
        chatVM?.onDismiss = nil
        chatVM = nil
        chatPanel?.hideAndReleaseContent()
        chatPanel = nil
        isChatVisible = false
    }

    private func showProcessingPanel() {
        guard let processingVM else { return }

        if processingPanel == nil {
            let panel = ProcessingPanel()
            panel.onEscape = { [weak self] in
                self?.processingVM?.dismiss()
            }
            processingPanel = panel
        }

        let hostingView = NSHostingView(
            rootView: DialogThemeRoot { ProcessingView(viewModel: processingVM) }
        )

        processingPanel?.contentView = hostingView
        processingPanel?.showCentered(on: NSScreen.screenContainingCursor)
        isProcessingVisible = true
    }

    private func hideProcessingPanelKeepingSession() {
        processingPanel?.dismiss()
        isProcessingVisible = false
    }

    private func handleAutomaticProcessingEvent(_ event: AutomaticProcessingEvent) {
        switch event {
        case .replaceStarted:
            onAutomaticProcessingEvent?(.replaceStarted)
        case .succeeded:
            hideProcessingPanelKeepingSession()
            onAutomaticProcessingEvent?(.succeeded)
        case .requiresPresentation:
            showProcessingPanel()
            onAutomaticProcessingEvent?(.requiresPresentation)
        }
    }
}

/// Observes the existing preference without rebuilding panels or models.
struct DialogThemeRoot<Content: View>: View {
    @AppStorage(SettingsKey.selectionTriggerStyle.rawValue)
    private var style = SelectionTriggerStyle.glassDot.rawValue
    @ViewBuilder let content: () -> Content

    var body: some View {
        let theme = DialogTheme(style: SelectionTriggerStyle(rawValue: style) ?? .glassDot)
        content()
            .environment(\.dialogTheme, theme)
            .foregroundStyle(theme.textPrimary)
            .tint(theme.accent)
    }
}
