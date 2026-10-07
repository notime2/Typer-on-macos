// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@Test
func testTextOnlyChatRequestKeepsStringContentWireShape() throws {
    let request = ChatRequest(
        model: "vendor/text-model",
        messages: [
            .system("System prompt"),
            .user("Hello"),
            .assistant("Hi")
        ],
        temperature: 0.4,
        maxTokens: 1024,
        stream: true
    )

    let data = try JSONEncoder().encode(request)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let messages = try #require(object["messages"] as? [[String: Any]])

    #expect(messages.count == 3)
    #expect(messages.map { $0["content"] as? String } == ["System prompt", "Hello", "Hi"])
    #expect(messages.allSatisfy { Set($0.keys) == ["role", "content"] })
}

@Test
func testMultimodalChatRequestEncodesTextBeforeImageURL() throws {
    let pngDataURL = "data:image/png;base64,AQIDBA=="
    let request = ChatRequest(
        model: "vendor/vision-model",
        messages: [.user("Describe this screenshot", imageURLs: [pngDataURL])],
        stream: true
    )

    let data = try JSONEncoder().encode(request)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let messages = try #require(object["messages"] as? [[String: Any]])
    let message = try #require(messages.first)
    let content = try #require(message["content"] as? [[String: Any]])

    #expect(content.count == 2)
    #expect(content[0]["type"] as? String == "text")
    #expect(content[0]["text"] as? String == "Describe this screenshot")
    #expect(content[0]["image_url"] == nil)
    #expect(content[1]["type"] as? String == "image_url")
    #expect(content[1]["text"] == nil)

    let imageURL = try #require(content[1]["image_url"] as? [String: Any])
    #expect(imageURL["url"] as? String == pngDataURL)
}

@Test
func testMultipartChatMessageDecodingPreservesTextAndImages() throws {
    let data = Data(
        #"{"role":"user","content":[{"type":"text","text":"Inspect"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AQID"}}]}"#.utf8
    )

    let message = try JSONDecoder().decode(ChatMessage.self, from: data)

    #expect(message.role == "user")
    #expect(message.content == "Inspect")
    #expect(message.imageURLs == ["data:image/png;base64,AQID"])
}
