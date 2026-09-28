// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct ChatResponse: Codable, Sendable {
    let id: String?
    let choices: [Choice]
    let usage: Usage?
    let error: ProviderError?

    struct Choice: Codable, Sendable {
        let index: Int
        let message: Message?
        let delta: Delta?
        let finish_reason: String?
    }

    struct Message: Codable, Sendable {
        let role: String?
        let content: String?
        let images: [Image]?
        let hasMalformedImagesPayload: Bool

        private enum CodingKeys: String, CodingKey {
            case role
            case content
            case images
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try? container.decodeIfPresent(String.self, forKey: .role)
            content = try? container.decodeIfPresent(String.self, forKey: .content)
            if !container.contains(.images) || (try? container.decodeNil(forKey: .images)) == true {
                images = nil
                hasMalformedImagesPayload = false
            } else if let decodedImages = try? container.decode([Image].self, forKey: .images) {
                images = decodedImages
                hasMalformedImagesPayload = false
            } else {
                images = []
                hasMalformedImagesPayload = true
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(role, forKey: .role)
            try container.encodeIfPresent(content, forKey: .content)
            try container.encodeIfPresent(images, forKey: .images)
        }
    }

    struct Delta: Codable, Sendable {
        let role: String?
        let content: String?
        let images: [Image]?
        let hasMalformedImagesPayload: Bool

        private enum CodingKeys: String, CodingKey {
            case role
            case content
            case images
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try? container.decodeIfPresent(String.self, forKey: .role)
            content = try? container.decodeIfPresent(String.self, forKey: .content)
            if !container.contains(.images) || (try? container.decodeNil(forKey: .images)) == true {
                images = nil
                hasMalformedImagesPayload = false
            } else if let decodedImages = try? container.decode([Image].self, forKey: .images) {
                images = decodedImages
                hasMalformedImagesPayload = false
            } else {
                images = []
                hasMalformedImagesPayload = true
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(role, forKey: .role)
            try container.encodeIfPresent(content, forKey: .content)
            try container.encodeIfPresent(images, forKey: .images)
        }
    }

    struct Image: Codable, Sendable {
        let type: String?
        let imageURL: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case imageURL = "image_url"
        }

        private enum ImageURLCodingKeys: String, CodingKey {
            case url
        }

        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                type = nil
                imageURL = nil
                return
            }

            type = try? container.decodeIfPresent(String.self, forKey: .type)

            guard let imageURLContainer = try? container.nestedContainer(
                keyedBy: ImageURLCodingKeys.self,
                forKey: .imageURL
            ) else {
                imageURL = nil
                return
            }
            imageURL = try? imageURLContainer.decodeIfPresent(String.self, forKey: .url)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(type, forKey: .type)

            if let imageURL {
                var imageURLContainer = container.nestedContainer(
                    keyedBy: ImageURLCodingKeys.self,
                    forKey: .imageURL
                )
                try imageURLContainer.encode(imageURL, forKey: .url)
            }
        }
    }

    struct Usage: Codable, Sendable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }

    struct ProviderError: Codable, Sendable {
        let code: Int?
        let message: String

        private enum CodingKeys: String, CodingKey {
            case code
            case message
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let numericCode = try? container.decode(Int.self, forKey: .code) {
                code = numericCode
            } else if let stringCode = try? container.decode(String.self, forKey: .code) {
                code = Int(stringCode)
            } else {
                code = nil
            }
            message = (try? container.decode(String.self, forKey: .message))
                ?? "OpenRouter stream failed."
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(code, forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }
}
