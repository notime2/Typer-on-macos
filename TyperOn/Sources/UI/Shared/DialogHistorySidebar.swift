// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

/// Saved conversations beside the Chat and Processing content. Styles differ only through
/// theme values, so a theme change never rebuilds the list.
struct DialogHistorySidebar: View {
    @Environment(\.dialogTheme) private var theme
    let conversations: [StoredChatConversation]
    let selectedID: UUID?
    let onSelect: (UUID) -> Void

    static let width: CGFloat = 220

    var body: some View {
        Group {
            if conversations.isEmpty {
                Text("No saved chats yet")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(conversations) { conversation in
                            row(conversation)
                        }
                    }
                    .padding(DS.Spacing.sm)
                }
            }
        }
        .frame(width: Self.width)
        .background(theme.background, ignoresSafeAreaEdges: .all)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.border)
                .frame(width: theme.usesNativeGlass ? 0.5 : theme.borderWidth)
                .ignoresSafeArea()
        }
    }

    private func row(_ conversation: StoredChatConversation) -> some View {
        let isSelected = conversation.id == selectedID
        return Button {
            onSelect(conversation.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(conversation.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textTertiary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, 6)
            .background(
                isSelected ? theme.surfaceHover : Color.clear,
                in: RoundedRectangle(cornerRadius: theme.buttonRadius, style: theme.cornerStyle)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A borderless icon control for the dialog header row.
struct DialogHeaderButton: View {
    @Environment(\.dialogTheme) private var theme
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The shared header controls: history sidebar toggle and New Chat.
struct DialogHistoryControls: View {
    @Binding var isSidebarVisible: Bool
    let onNewChat: () -> Void

    var body: some View {
        DialogHeaderButton(
            systemImage: "sidebar.left",
            label: isSidebarVisible ? "Hide Chat History" : "Show Chat History"
        ) {
            isSidebarVisible.toggle()
        }
        DialogHeaderButton(systemImage: "square.and.pencil", label: "New Chat", action: onNewChat)
    }
}
