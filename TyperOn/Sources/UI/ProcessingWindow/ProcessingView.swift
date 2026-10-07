// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

struct ProcessingView: View {
    @Environment(\.dialogTheme) private var theme
    @Bindable var viewModel: ProcessingViewModel

    @State private var isOriginalExpanded = false
    @AppStorage(SettingsKey.showChatHistorySidebar.rawValue) private var showsHistory = false

    private let maxTruncatedLength = 200
    private let bottomBarControlHeight: CGFloat = 32
    private let copyButtonMinWidth: CGFloat = 88
    private let replaceButtonMinWidth: CGFloat = 92

    var body: some View {
        HStack(spacing: 0) {
            if showsHistory {
                DialogHistorySidebar(
                    conversations: viewModel.historyConversations,
                    selectedID: viewModel.historyConversation?.id
                ) { id in
                    viewModel.openChat(.existing(id))
                }
            }

            DialogScaffold {
                header
            } accessory: {
                DialogHistoryControls(isSidebarVisible: $showsHistory) {
                    viewModel.openChat(.newDraft(pendingSelectionText: nil))
                }
            } content: {
                scrollContent
            } bottomBar: {
                bottomBar
            }
            .frame(minWidth: 360, idealWidth: 480, minHeight: 300, idealHeight: 400)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if let module = viewModel.currentModule {
            ModuleIconView(icon: module.icon, size: 14)
                .foregroundStyle(theme.textSecondary)
            Text(module.name)
                .font(.system(size: 14, weight: .semibold))
        }
    }

    // MARK: - Content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                originalTextSection
                resultSection
            }
            .padding(DS.Spacing.lg)
        }
    }

    private var originalTextSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Original")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .textCase(.uppercase)

            let shouldTruncate = viewModel.originalText.count > maxTruncatedLength && !isOriginalExpanded
            let displayText = shouldTruncate
                ? String(viewModel.originalText.prefix(maxTruncatedLength)) + "..."
                : viewModel.originalText

            Text(displayText)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if viewModel.originalText.count > maxTruncatedLength {
                Button(isOriginalExpanded ? "Show less" : "Show more") {
                    withAnimation(DS.Animation.quick) {
                        isOriginalExpanded.toggle()
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(DS.Spacing.md)
        .background(theme.contentSurface, in: RoundedRectangle(cornerRadius: theme.contentRadius, style: theme.cornerStyle))
        .dialogCardBorder(theme)
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Result")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textTertiary)
                .textCase(.uppercase)

            if let error = viewModel.error {
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
            } else if viewModel.resultText.isEmpty && viewModel.isStreaming {
                LoadingIndicator()
                    .padding(.vertical, DS.Spacing.sm)
            } else {
                StreamingTextView(text: viewModel.resultText, isStreaming: viewModel.isStreaming)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let replaceStatusMessage = viewModel.replaceStatusMessage {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(theme.textSecondary)
                    Text(replaceStatusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(DS.Spacing.md)
        .background(
            theme.accent.opacity(theme.usesNativeGlass ? 0.08 : 0.04),
            in: RoundedRectangle(cornerRadius: theme.contentRadius, style: theme.cornerStyle)
        )
        .dialogCardBorder(theme)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: DS.Spacing.sm) {
            AutoGrowingTextInput(
                text: $viewModel.userComment,
                placeholder: "Add instructions for refinement...",
                onSubmit: viewModel.refine
            )

            if !viewModel.userComment.isEmpty {
                ActionButton("Refine", icon: "arrow.clockwise", style: .ghost, fixedHeight: bottomBarControlHeight) {
                    viewModel.refine()
                }
            }

            ActionButton(
                viewModel.copyFeedbackState == .copied ? "Copied" : "Copy",
                icon: viewModel.copyFeedbackState == .copied ? "checkmark" : "doc.on.doc",
                style: .ghost,
                minWidth: copyButtonMinWidth,
                fixedHeight: bottomBarControlHeight
            ) {
                viewModel.copyResult()
            }
            .disabled(viewModel.resultText.isEmpty)
            .fixedSize(horizontal: true, vertical: false)

            if viewModel.lastReplacement != nil {
                ActionButton(
                    "Undo Replace",
                    icon: "arrow.uturn.backward",
                    style: .ghost,
                    fixedHeight: bottomBarControlHeight
                ) {
                    Task { await viewModel.undoLastReplace() }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            ActionButton(
                "Replace",
                icon: "arrow.turn.down.left",
                style: .primary,
                minWidth: replaceButtonMinWidth,
                fixedHeight: bottomBarControlHeight
            ) {
                Task { await viewModel.replaceOriginal() }
            }
            .disabled(viewModel.resultText.isEmpty || viewModel.isStreaming)
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}
