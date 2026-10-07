// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct ChatImageAttachment: Identifiable, Sendable, Equatable {
    let id: UUID
    let data: Data
    let mimeType: String
    let pixelWidth: Int?
    let pixelHeight: Int?

    init(
        id: UUID = UUID(),
        data: Data,
        mimeType: String,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

struct ChatConversationMessage: Identifiable, Sendable, Codable {
    let id: UUID
    let role: Role
    var text: String
    var images: [ChatImageAttachment] = []
    var invalidImageCount: Int

    enum Role: String, Sendable, Codable {
        case user
        case assistant
    }

    /// Chat history stores only role and text; image bytes stay in the live session.
    private enum CodingKeys: String, CodingKey {
        case id, role, text, invalidImageCount
    }

    init(
        id: UUID = UUID(),
        role: Role,
        text: String = "",
        images: [ChatImageAttachment] = [],
        invalidImageCount: Int = 0
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
        self.invalidImageCount = invalidImageCount
    }

    /// Histories written by earlier builds carry no placeholder count.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            role: try container.decode(Role.self, forKey: .role),
            text: try container.decode(String.self, forKey: .text),
            invalidImageCount: try container.decodeIfPresent(Int.self, forKey: .invalidImageCount) ?? 0
        )
    }

    /// The history copy: each image becomes an "Image unavailable" placeholder.
    var withoutImages: ChatConversationMessage {
        var copy = self
        copy.invalidImageCount += copy.images.count
        copy.images = []
        return copy
    }
}
