// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct ChatMessage: Codable, Sendable, Equatable {
    let role: String
    let content: String
    let imageURLs: [String]

    init(role: String, content: String, imageURLs: [String] = []) {
        self.role = role
        self.content = content
        self.imageURLs = imageURLs
    }

    static func system(_ content: String) -> ChatMessage {
        ChatMessage(role: "system", content: content)
    }

    static func user(_ content: String, imageURLs: [String] = []) -> ChatMessage {
        ChatMessage(role: "user", content: content, imageURLs: imageURLs)
    }

    static func assistant(_ content: String) -> ChatMessage {
        ChatMessage(role: "assistant", content: content)
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)

        if let textContent = try? container.decode(String.self, forKey: .content) {
            content = textContent
            imageURLs = []
            return
        }

        let parts = try container.decode([ContentPart].self, forKey: .content)
        content = parts.compactMap(\.text).joined()
        imageURLs = parts.compactMap(\.imageURL)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)

        guard !imageURLs.isEmpty else {
            try container.encode(content, forKey: .content)
            return
        }

        let parts = [ContentPart(text: content)] + imageURLs.map { ContentPart(imageURL: $0) }
        try container.encode(parts, forKey: .content)
    }

    private struct ContentPart: Codable {
        let type: String
        let text: String?
        let imageURLValue: ImageURLValue?

        var imageURL: String? { imageURLValue?.url }

        init(text: String) {
            type = "text"
            self.text = text
            imageURLValue = nil
        }

        init(imageURL: String) {
            type = "image_url"
            text = nil
            imageURLValue = ImageURLValue(url: imageURL)
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURLValue = "image_url"
        }
    }

    private struct ImageURLValue: Codable {
        let url: String
    }
}

struct ChatRequest: Codable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let max_tokens: Int?
    let stream: Bool

    init(
        model: String,
        messages: [ChatMessage],
        temperature: Double = AIModelDefaults.defaultTemperature,
        maxTokens: Int = AIModelDefaults.defaultMaxTokens,
        stream: Bool = true
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.max_tokens = maxTokens
        self.stream = stream
    }
}
