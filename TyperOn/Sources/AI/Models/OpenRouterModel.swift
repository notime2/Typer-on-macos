// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct OpenRouterModel: Codable, Identifiable, Sendable, Hashable {
    struct Architecture: Codable, Sendable, Hashable {
        let input_modalities: [String]?
        let output_modalities: [String]?

        init(input_modalities: [String]? = nil, output_modalities: [String]? = nil) {
            self.input_modalities = input_modalities
            self.output_modalities = output_modalities
        }
    }

    let id: String
    let name: String
    let context_length: Int?
    let architecture: Architecture?

    init(
        id: String,
        name: String,
        context_length: Int?,
        architecture: Architecture? = nil
    ) {
        self.id = id
        self.name = name
        self.context_length = context_length
        self.architecture = architecture
    }

    var displayName: String {
        name.isEmpty ? id : name
    }

    var providerName: String {
        id.components(separatedBy: "/").first?.capitalized ?? ""
    }

    var supportsImageInput: Bool {
        architecture?.input_modalities?.contains(where: Self.isImageModality) == true
    }

    var supportsImageOutput: Bool {
        architecture?.output_modalities?.contains(where: Self.isImageModality) == true
    }

    var hasCompleteModalityMetadata: Bool {
        architecture?.input_modalities != nil && architecture?.output_modalities != nil
    }

    private static func isImageModality(_ modality: String) -> Bool {
        modality.lowercased() == "image"
    }
}

struct OpenRouterModelsResponse: Codable, Sendable {
    let data: [OpenRouterModel]
}

struct OpenRouterModelResponse: Codable, Sendable {
    let data: OpenRouterModel
}
