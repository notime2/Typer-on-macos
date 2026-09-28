// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct ImageGenerationInputReference: Codable, Sendable, Equatable {
    let imageURL: String

    init(imageURL: String) {
        self.imageURL = imageURL
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case imageURL = "image_url"
    }

    private enum ImageURLCodingKeys: String, CodingKey {
        case url
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == "image_url" else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported image input reference type"
            )
        }

        let imageURLContainer = try container.nestedContainer(
            keyedBy: ImageURLCodingKeys.self,
            forKey: .imageURL
        )
        imageURL = try imageURLContainer.decode(String.self, forKey: .url)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("image_url", forKey: .type)

        var imageURLContainer = container.nestedContainer(
            keyedBy: ImageURLCodingKeys.self,
            forKey: .imageURL
        )
        try imageURLContainer.encode(imageURL, forKey: .url)
    }
}

struct ImageGenerationRequest: Codable, Sendable, Equatable {
    let model: String
    let prompt: String
    let inputReferences: [ImageGenerationInputReference]?

    init(
        model: String,
        prompt: String,
        inputReferences: [ImageGenerationInputReference]? = nil
    ) {
        self.model = model
        self.prompt = prompt
        self.inputReferences = inputReferences?.isEmpty == false ? inputReferences : nil
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case prompt
        case inputReferences = "input_references"
    }
}

struct GeneratedImage: Sendable, Equatable {
    let data: Data
    let mimeType: String

    init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

struct ImageGenerationResult: Sendable, Equatable {
    let images: [GeneratedImage]
    let invalidImageCount: Int

    init(images: [GeneratedImage], invalidImageCount: Int = 0) {
        self.images = images
        self.invalidImageCount = invalidImageCount
    }
}
