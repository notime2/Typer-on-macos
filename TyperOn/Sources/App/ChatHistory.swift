// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

enum ChatConversationTarget: Equatable, Sendable {
    /// Keeps whatever the chat window holds; an empty window restores the most recent conversation.
    case continueCurrentOrMostRecent
    case newDraft(pendingSelectionText: String?)
    case existing(UUID)
}

/// One saved Chat Mode conversation or Processing run. Messages keep role and text only;
/// `ChatHistoryStore.upsert` replaces images with placeholders.
struct StoredChatConversation: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    /// Set for Processing runs, so the title names the module that produced them.
    var moduleName: String?
    var messages: [ChatConversationMessage]
    /// Selected text promoted to hidden chat context.
    var conversationContextText: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        moduleName: String? = nil,
        messages: [ChatConversationMessage] = [],
        conversationContextText: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.moduleName = moduleName
        self.messages = messages
        self.conversationContextText = conversationContextText
    }

    var title: String {
        let snippet = messages.first { $0.role == .user && !Self.isBlank($0.text) }
            .map { Self.singleLineSnippet($0.text, limit: 60) } ?? "New Chat"
        return moduleName.map { "\($0): \(snippet)" } ?? snippet
    }

    var preview: String {
        messages.last { !Self.isBlank($0.text) }.map { Self.singleLineSnippet($0.text, limit: 90) } ?? ""
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func singleLineSnippet(_ text: String, limit: Int) -> String {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit - 1)) + "…"
    }
}

/// Chat history, newest first. Persists to one JSON file; a nil `fileURL` keeps it in memory
/// (tests and stream replay).
@MainActor
@Observable
final class ChatHistoryStore {
    // ponytail: the whole file is rewritten on every save; the cap keeps that cheap.
    // Move to one file per conversation if a longer history is needed.
    static let maximumConversationCount = 500

    private let fileURL: URL?
    private(set) var conversations: [StoredChatConversation] = []

    init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    /// `~/Library/Application Support/Typer On/chat-history.json`; nil under XCTest so the
    /// suite never touches a real history.
    static func defaultFileURL() -> URL? {
        guard !AppRuntime.isRunningTests,
              let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return baseURL
            .appendingPathComponent("Typer On", isDirectory: true)
            .appendingPathComponent("chat-history.json")
    }

    func conversation(id: UUID) -> StoredChatConversation? {
        conversations.first { $0.id == id }
    }

    /// Screenshots and generated images never enter history, neither in memory nor on disk.
    func upsert(_ conversation: StoredChatConversation) {
        var conversation = conversation
        conversation.messages = conversation.messages.map(\.withoutImages)
        conversations.removeAll { $0.id == conversation.id }
        conversations.append(conversation)
        conversations.sort(by: Self.isNewer)
        if conversations.count > Self.maximumConversationCount {
            conversations.removeLast(conversations.count - Self.maximumConversationCount)
        }
        save()
    }

    func delete(id: UUID) {
        conversations.removeAll { $0.id == id }
        save()
    }

    func deleteAll() {
        conversations.removeAll()
        save()
    }

    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            conversations = try JSONDecoder().decode([StoredChatConversation].self, from: data)
                .sorted(by: Self.isNewer)
        } catch {
            // Keep the unreadable file for recovery instead of overwriting it on the next save.
            let backupURL = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            Log.app.error("Failed to load chat history: \(error)")
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(conversations).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Failed to save chat history: \(error)")
        }
    }

    private static func isNewer(_ lhs: StoredChatConversation, _ rhs: StoredChatConversation) -> Bool {
        lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt > rhs.updatedAt : lhs.createdAt > rhs.createdAt
    }
}
