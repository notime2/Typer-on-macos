// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

struct ChatMessageBubble: View {
    @Environment(\.dialogTheme) private var theme
    let message: ChatConversationMessage
    let isLastMessage: Bool
    let isStreaming: Bool
    let copyFeedbackState: ChatMessageCopyFeedbackState
    let onCopy: () -> Void

    private let copyButtonWidth: CGFloat = 88
    private let copyButtonHeight: CGFloat = 28

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: DS.Spacing.xs) {
                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: DS.Spacing.sm) {
                    bubbleContent

                    if showsCopyButton {
                        copyButton
                            .frame(maxWidth: .infinity, alignment: theme.usesNativeGlass ? .leading : .trailing)
                    }
                }
                .padding(.vertical, DS.Spacing.md)
                .padding(.horizontal, isBubbleless ? DS.Spacing.xs : DS.Spacing.md)
                .background(bubbleBackground, in: RoundedRectangle(cornerRadius: bubbleRadius, style: theme.cornerStyle))
                .dialogCardBorder(theme)
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(
            alignment: message.role == .user ? .trailing : .leading,
            spacing: DS.Spacing.sm
        ) {
            if message.text.isEmpty,
               message.images.isEmpty,
               message.invalidImageCount == 0,
               isLastMessage,
               isStreaming {
                LoadingIndicator()
            } else if !message.text.isEmpty, message.role == .assistant {
                MarkdownContentView(
                    text: message.text,
                    isStreaming: isLastMessage && isStreaming
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.usesNativeGlass ? theme.primaryForeground : theme.textPrimary)
                    .textSelection(.enabled)
                    // A solid Glass Dot bubble hugs its text instead of spanning the row.
                    .frame(maxWidth: theme.usesNativeGlass ? nil : .infinity, alignment: .trailing)
            }

            ForEach(message.images) { image in
                ChatImageAttachmentView(
                    attachment: image,
                    accessibilityLabel: message.role == .user
                        ? "Screenshot attachment"
                        : "Assistant image"
                )
            }

            ForEach(0..<message.invalidImageCount, id: \.self) { _ in
                ChatInvalidImageView()
            }
        }
    }

    /// Glass Dot follows native Messages: a solid accent bubble for the user and
    /// bubble-free assistant prose on the window background.
    private var isBubbleless: Bool {
        theme.usesNativeGlass && message.role == .assistant
    }

    private var bubbleBackground: Color {
        switch (theme.usesNativeGlass, message.role) {
        case (true, .user): theme.accent
        case (true, _): .clear
        case (false, .user): theme.accent.opacity(0.08)
        case (false, _): theme.surface
        }
    }

    private var bubbleRadius: CGFloat {
        theme.usesNativeGlass ? 18 : theme.contentRadius
    }

    private var showsCopyButton: Bool {
        message.role == .assistant && !message.text.isEmpty
    }

    private var copyButton: some View {
        Button {
            onCopy()
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: copyFeedbackState == .copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                Text(copyFeedbackState == .copied ? "Copied" : "Copy")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(theme.textSecondary)
            .frame(width: copyButtonWidth, height: copyButtonHeight, alignment: theme.usesNativeGlass ? .leading : .center)
            .background(
                theme.usesNativeGlass ? Color.clear : theme.surfaceHover,
                in: RoundedRectangle(cornerRadius: theme.buttonRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.buttonRadius)
                    .stroke(theme.contentBorder, lineWidth: theme.borderWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: theme.buttonRadius))
        }
        .buttonStyle(.plain)
        .help("Copy message")
    }
}
