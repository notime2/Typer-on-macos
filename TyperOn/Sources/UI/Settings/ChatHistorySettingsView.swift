// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

struct ChatHistorySettingsView: View {
    let environment: AppEnvironment

    @State private var expandedID: UUID?
    @State private var isConfirmingClearAll = false

    private var store: ChatHistoryStore {
        environment.chatHistoryStore
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DS.Colors.background)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xl) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.md) {
                Text("Chats and module runs are saved on this Mac only. Screenshots and generated images are not saved.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button("Clear All", role: .destructive) {
                    isConfirmingClearAll = true
                }
                .font(.system(size: 13))
                .buttonStyle(.glass)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(store.conversations.isEmpty)
                .confirmationDialog(
                    "Delete all saved chats?",
                    isPresented: $isConfirmingClearAll
                ) {
                    Button("Delete All", role: .destructive) {
                        store.deleteAll()
                    }
                } message: {
                    Text("This cannot be undone.")
                }
            }

            if store.conversations.isEmpty {
                VStack(spacing: DS.Spacing.md) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(DS.Colors.textTertiary)
                    Text("No saved chats yet")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.xxl)
            }

            LazyVStack(spacing: DS.Spacing.sm) {
                ForEach(store.conversations) { conversation in
                    row(conversation)
                }
            }
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.background)
    }

    private func row(_ conversation: StoredChatConversation) -> some View {
        let isExpanded = expandedID == conversation.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Spacing.md) {
                Button {
                    expandedID = isExpanded ? nil : conversation.id
                } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Colors.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse \(conversation.title)" : "Expand \(conversation.title)")

                Button("Open in Chat") {
                    NotificationCenter.default.post(
                        name: .openChatRequested,
                        object: ChatConversationTarget.existing(conversation.id)
                    )
                }
                .font(.system(size: 12))
                .buttonStyle(.glass)
                .fixedSize()

                Button {
                    if isExpanded { expandedID = nil }
                    store.delete(id: conversation.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.7))
                .help("Delete")
                .accessibilityLabel("Delete \(conversation.title)")
            }
            .padding(DS.Spacing.md)

            if isExpanded {
                Divider().foregroundStyle(DS.Colors.separator)
                transcript(conversation)
                    .padding(DS.Spacing.md)
            }
        }
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.Colors.separator, lineWidth: 0.5))
    }

    private func transcript(_ conversation: StoredChatConversation) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if let context = conversation.conversationContextText {
                messageBlock(label: "Selected Text Context", text: context)
            }
            ForEach(conversation.messages) { message in
                messageBlock(
                    label: message.role == .user ? "You" : "Assistant",
                    text: message.invalidImageCount > 0
                        ? message.text + "\n[\(message.invalidImageCount) image(s) not saved]"
                        : message.text
                )
            }
        }
    }

    private func messageBlock(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Colors.textSecondary)
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
