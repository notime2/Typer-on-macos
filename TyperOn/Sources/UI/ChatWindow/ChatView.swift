// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

struct ChatView: View {
    @Environment(\.dialogTheme) private var theme
    @Bindable var viewModel: ChatViewModel
    @State private var followsResponse = true
    @AppStorage(SettingsKey.showChatHistorySidebar.rawValue) private var showsHistory = false

    private let inputBarHeight: CGFloat = 32

    var body: some View {
        HStack(spacing: 0) {
            if showsHistory {
                DialogHistorySidebar(
                    conversations: viewModel.historyConversations,
                    selectedID: viewModel.currentConversationID
                ) { id in
                    viewModel.presentConversation(.existing(id))
                }
            }

            DialogScaffold {
                header
            } accessory: {
                DialogHistoryControls(isSidebarVisible: $showsHistory, onNewChat: viewModel.startNewChat)
            } content: {
                messageList
            } bottomBar: {
                bottomBar
            }
            .frame(minWidth: 400, idealWidth: ChatPanel.defaultContentSize.width, minHeight: 350, idealHeight: 500)
        }
        .task {
            await viewModel.refreshActiveModelCapabilities()
        }
        .onChange(of: viewModel.modelCatalogSnapshot) {
            Task {
                await viewModel.refreshActiveModelCapabilities()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiConfigurationChanged)) { _ in
            viewModel.invalidateActiveModelCapabilities()
            Task {
                await viewModel.refreshActiveModelCapabilities()
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(theme.textSecondary)
        Text("Chat Mode")
            .font(.system(size: 14, weight: .semibold))
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.messages.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: DS.Spacing.md) {
                        ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                            ChatMessageBubble(
                                message: message,
                                isLastMessage: index == viewModel.messages.count - 1,
                                isStreaming: viewModel.isStreaming,
                                copyFeedbackState: viewModel.copyFeedbackState(for: message),
                                onCopy: { viewModel.copyMessage(message) }
                            )
                            .id(message.id)
                        }

                        if let error = viewModel.error {
                            errorView(error)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(DS.Spacing.lg)
                    .background {
                        ChatScrollPositionObserver { followsResponse = $0 }
                            .frame(width: 0, height: 0)
                    }
                }
            }
            .onChange(of: viewModel.messages.last?.text) {
                if followsResponse {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.last(where: { $0.role == .user })?.id) {
                followsResponse = true
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
            .onChange(of: viewModel.messages.last?.id) {
                if followsResponse {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.last?.images.count) {
                if followsResponse {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.last?.invalidImageCount) {
                if followsResponse {
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.md) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(theme.textTertiary.opacity(0.5))
            Text(emptyStateText)
                .font(.system(size: 13))
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.xl)
    }

    private func errorView(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red.opacity(0.8))
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.isErrorRetryable {
                Button {
                    viewModel.retry()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(DS.Spacing.md)
        .background(
            Color.red.opacity(0.05),
            in: RoundedRectangle(cornerRadius: theme.contentRadius, style: theme.cornerStyle)
        )
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if let pendingSelectionText = viewModel.pendingSelectionText {
                pendingSelectionCard(pendingSelectionText)
            }

            if let pendingScreenshot = viewModel.pendingScreenshot {
                pendingScreenshotCard(pendingScreenshot)
            }

            if let captureError = viewModel.captureError {
                Label(captureError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.9))
                    .accessibilityElement(children: .combine)
            }

            HStack(alignment: .bottom, spacing: DS.Spacing.sm) {
                if viewModel.canCaptureScreenshot {
                    screenshotCaptureControl
                }

                AutoGrowingTextInput(
                    text: $viewModel.inputText,
                    placeholder: "Type a message...",
                    focusRequestID: viewModel.inputFocusRequestID,
                    onSubmit: viewModel.sendMessage
                )
                .disabled(viewModel.isPreparingSend)

                if viewModel.isStreaming {
                    Button {
                        viewModel.stopStreaming()
                    } label: {
                        Image(systemName: theme.usesNativeGlass ? "stop.fill" : "stop.circle.fill")
                            .font(.system(size: theme.usesNativeGlass ? 12 : 20))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: inputBarHeight, height: inputBarHeight)
                            .contentShape(Circle())
                            .glassEffect(theme.usesNativeGlass ? .regular.interactive() : .identity, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                    .accessibilityLabel("Stop")
                } else {
                    Button {
                        viewModel.sendMessage()
                    } label: {
                        Image(systemName: theme.usesNativeGlass ? "arrow.up" : "arrow.up.circle.fill")
                            .font(.system(size: theme.usesNativeGlass ? 14 : 20, weight: theme.usesNativeGlass ? .semibold : .regular))
                            .foregroundStyle(sendGlyphColor)
                            .frame(width: inputBarHeight, height: inputBarHeight)
                            .contentShape(Circle())
                            .glassEffect(
                                theme.usesNativeGlass ? .regular.tint(canSend ? theme.accent : nil).interactive() : .identity,
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send")
                    .accessibilityLabel("Send")
                }
            }
        }
    }

    private var screenshotCaptureControl: some View {
        HStack(spacing: 0) {
            Button {
                viewModel.captureScreenshot(mode: .area)
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    if viewModel.isCapturingScreenshot {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                    }

                    Text("Select Area")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.leading, theme.usesNativeGlass ? DS.Spacing.md : DS.Spacing.sm)
                .padding(.trailing, DS.Spacing.sm)
                .frame(height: inputBarHeight)
            }
            .buttonStyle(.plain)
            .help("Select Area")
            .accessibilityLabel("Select Area")
            .accessibilityHint(
                viewModel.isCapturingScreenshot ? "Press Escape to cancel" : "Select a screenshot area"
            )

            Divider()
                .frame(height: 18)

            Menu {
                Button {
                    viewModel.captureScreenshot(mode: .area)
                } label: {
                    Label("Select Area", systemImage: "camera.viewfinder")
                }

                Button {
                    viewModel.captureScreenshot(mode: .windowOrDisplay)
                } label: {
                    Label("Window or Display", systemImage: "macwindow.on.rectangle")
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 16, height: inputBarHeight)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Screenshot Options")
            .accessibilityLabel("Screenshot Options")
        }
        .padding(.trailing, theme.usesNativeGlass ? DS.Spacing.xs : 0)
        .clipShape(RoundedRectangle(cornerRadius: theme.controlRadius(height: inputBarHeight), style: theme.cornerStyle))
        .dialogControlSurface(
            RoundedRectangle(cornerRadius: theme.controlRadius(height: inputBarHeight), style: theme.cornerStyle),
            fill: theme.surface,
            lineWidth: 1
        )
        .disabled(
            viewModel.isCapturingScreenshot
                || viewModel.isStreaming
                || viewModel.isPreparingSend
        )
    }

    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isPreparingSend
    }

    private var sendGlyphColor: Color {
        guard canSend else { return theme.textTertiary }
        return theme.usesNativeGlass ? theme.primaryForeground : theme.accent
    }

    private var emptyStateText: String {
        if viewModel.pendingScreenshot != nil {
            return "Screenshot attached. Type a message to use it."
        }

        if viewModel.pendingSelectionText != nil {
            return "Selected text is attached as context. Type a message to use it."
        }

        return "Type a message to start a conversation"
    }

    private func pendingSelectionCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Selected text attached as context")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)

                Text(normalizedPreviewText(text))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                viewModel.clearPendingSelectionText()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        theme.usesNativeGlass ? Color.primary.opacity(0.08) : theme.surface,
                        in: RoundedRectangle(cornerRadius: theme.controlRadius(height: 20), style: theme.cornerStyle)
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isPreparingSend)
            .help("Remove context")
        }
        .padding(DS.Spacing.sm)
        .dialogControlSurface(
            RoundedRectangle(cornerRadius: theme.contentRadius, style: theme.cornerStyle),
            fill: theme.surfaceHover,
            isInteractive: false
        )
    }

    private func pendingScreenshotCard(_ screenshot: ChatImageAttachment) -> some View {
        HStack(alignment: .center, spacing: DS.Spacing.sm) {
            ChatImageAttachmentView(
                attachment: screenshot,
                maxHeight: 64,
                accessibilityLabel: "Pending screenshot"
            )
            .frame(width: 96, height: 64)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Screenshot attached")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)

                if let sizeDescription = screenshotSizeDescription(screenshot) {
                    Text(sizeDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                }
            }

            Spacer()

            Button {
                viewModel.clearPendingScreenshot()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        theme.usesNativeGlass ? Color.primary.opacity(0.08) : theme.surface,
                        in: RoundedRectangle(cornerRadius: theme.controlRadius(height: 20), style: theme.cornerStyle)
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isPreparingSend)
            .help("Remove screenshot")
            .accessibilityLabel("Remove screenshot")
        }
        .padding(DS.Spacing.sm)
        .dialogControlSurface(
            RoundedRectangle(cornerRadius: theme.contentRadius, style: theme.cornerStyle),
            fill: theme.surfaceHover,
            isInteractive: false
        )
    }

    private func screenshotSizeDescription(_ screenshot: ChatImageAttachment) -> String? {
        guard let width = screenshot.pixelWidth, let height = screenshot.pixelHeight else {
            return nil
        }
        return "\(width) x \(height) PNG"
    }

    private func normalizedPreviewText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
