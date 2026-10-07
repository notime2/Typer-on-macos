// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@MainActor
@Suite("Chat history store")
struct ChatHistoryStoreTests {
    @Test func persistsAndReloadsNewestFirst() {
        let fileURL = makeHistoryFileURL()
        let store = ChatHistoryStore(fileURL: fileURL)
        let older = StoredChatConversation(
            updatedAt: Date(timeIntervalSince1970: 2_000),
            messages: [ChatConversationMessage(role: .user, text: "Older")]
        )
        let newer = StoredChatConversation(
            updatedAt: Date(timeIntervalSince1970: 3_000),
            moduleName: "Translate",
            messages: [
                ChatConversationMessage(role: .user, text: "Newer   text\nwith lines"),
                ChatConversationMessage(role: .assistant, text: "Answer")
            ],
            conversationContextText: "Context"
        )

        store.upsert(older)
        store.upsert(newer)

        let reloaded = ChatHistoryStore(fileURL: fileURL)
        #expect(reloaded.conversations.map(\.id) == [newer.id, older.id])
        #expect(reloaded.conversations.map(\.title) == ["Translate: Newer text with lines", "Older"])
        #expect(reloaded.conversations.first?.preview == "Answer")
        #expect(reloaded.conversations.first?.conversationContextText == "Context")
        #expect(reloaded.conversations.first?.messages.map(\.role) == [.user, .assistant])
    }

    @Test func upsertReplacesExistingConversationAndResorts() {
        let store = ChatHistoryStore(fileURL: nil)
        var first = StoredChatConversation(
            updatedAt: Date(timeIntervalSince1970: 1_000),
            messages: [ChatConversationMessage(role: .user, text: "First")]
        )
        let second = StoredChatConversation(
            updatedAt: Date(timeIntervalSince1970: 2_000),
            messages: [ChatConversationMessage(role: .user, text: "Second")]
        )
        store.upsert(first)
        store.upsert(second)

        first.updatedAt = Date(timeIntervalSince1970: 3_000)
        first.messages.append(ChatConversationMessage(role: .assistant, text: "Reply"))
        store.upsert(first)

        #expect(store.conversations.map(\.id) == [first.id, second.id])
        #expect(store.conversation(id: first.id)?.messages.map(\.text) == ["First", "Reply"])
    }

    @Test func imageBytesAreNeverWrittenAndReloadAsPlaceholders() throws {
        let fileURL = makeHistoryFileURL()
        let store = ChatHistoryStore(fileURL: fileURL)
        let imageData = Data("synthetic-image-bytes".utf8)
        let conversation = StoredChatConversation(messages: [
            ChatConversationMessage(
                role: .user,
                text: "Look",
                images: [ChatImageAttachment(data: imageData, mimeType: "image/png")]
            ),
            ChatConversationMessage(
                role: .assistant,
                images: [ChatImageAttachment(data: imageData, mimeType: "image/png")],
                invalidImageCount: 1
            )
        ])

        store.upsert(conversation)
        #expect(store.conversations.first?.messages.allSatisfy { $0.images.isEmpty } == true)

        let fileText = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!fileText.contains(imageData.base64EncodedString()))
        #expect(!fileText.contains("synthetic-image-bytes"))
        #expect(!fileText.contains("\"images\""))

        let messages = try #require(ChatHistoryStore(fileURL: fileURL).conversations.first?.messages)
        #expect(messages.allSatisfy { $0.images.isEmpty })
        #expect(messages.map(\.invalidImageCount) == [1, 2])
    }

    @Test func deleteAndDeleteAllPersist() {
        let fileURL = makeHistoryFileURL()
        let store = ChatHistoryStore(fileURL: fileURL)
        let kept = StoredChatConversation(messages: [ChatConversationMessage(role: .user, text: "Keep")])
        let removed = StoredChatConversation(messages: [ChatConversationMessage(role: .user, text: "Remove")])
        store.upsert(kept)
        store.upsert(removed)

        store.delete(id: removed.id)
        #expect(ChatHistoryStore(fileURL: fileURL).conversations.map(\.id) == [kept.id])

        store.deleteAll()
        #expect(store.conversations.isEmpty)
        #expect(ChatHistoryStore(fileURL: fileURL).conversations.isEmpty)
    }

    @Test func keepsOnlyTheMostRecentConversations() {
        let store = ChatHistoryStore(fileURL: nil)
        let limit = ChatHistoryStore.maximumConversationCount
        for index in 0...limit {
            store.upsert(StoredChatConversation(
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                messages: [ChatConversationMessage(role: .user, text: "Chat \(index)")]
            ))
        }

        #expect(store.conversations.count == limit)
        #expect(store.conversations.first?.title == "Chat \(limit)")
        #expect(!store.conversations.contains { $0.title == "Chat 0" })
    }

    @Test func unreadableFileIsKeptAsideInsteadOfOverwritten() throws {
        let fileURL = makeHistoryFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)

        let store = ChatHistoryStore(fileURL: fileURL)
        #expect(store.conversations.isEmpty)

        store.upsert(StoredChatConversation(messages: [ChatConversationMessage(role: .user, text: "New")]))
        let backup = try Data(contentsOf: fileURL.appendingPathExtension("unreadable"))
        #expect(String(decoding: backup, as: UTF8.self) == "not json")
        #expect(ChatHistoryStore(fileURL: fileURL).conversations.count == 1)
    }

    @Test func readsHistoryWrittenByTheEarlierExperimentalBuild() throws {
        let fileURL = makeHistoryFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let id = UUID()
        let legacyJSON = """
        [{"id":"\(id.uuidString)","createdAt":1000,"updatedAt":2000,"pendingSelectionText":"Draft",\
        "conversationContextText":"Context","messages":[\
        {"id":"\(UUID().uuidString)","role":"user","text":"Question"},\
        {"id":"\(UUID().uuidString)","role":"assistant","text":"Answer"}]}]
        """
        try Data(legacyJSON.utf8).write(to: fileURL)

        let conversation = try #require(ChatHistoryStore(fileURL: fileURL).conversations.first)
        #expect(conversation.id == id)
        #expect(conversation.messages.map(\.text) == ["Question", "Answer"])
        #expect(conversation.messages.map(\.invalidImageCount) == [0, 0])
        #expect(conversation.conversationContextText == "Context")
        #expect(!FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("unreadable").path))
    }

    @Test func realHistoryLocationIsUnusedUnderTests() {
        #expect(ChatHistoryStore.defaultFileURL() == nil)
        #expect(AppEnvironment().chatHistoryStore.conversations.isEmpty)
    }

    private func makeHistoryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TyperOnChatHistoryTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("chat-history.json")
    }
}
