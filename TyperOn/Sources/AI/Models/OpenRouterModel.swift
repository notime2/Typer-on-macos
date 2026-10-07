// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct ReasoningEffortOption: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let detail: String

    var displayName: String {
        id.lowercased() == "xhigh" ? "XHigh" : id.capitalized
    }
}

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
    let reasoningEfforts: [ReasoningEffortOption]?
    let defaultReasoningEffort: String?

    init(
        id: String,
        name: String,
        context_length: Int?,
        architecture: Architecture? = nil,
        reasoningEfforts: [ReasoningEffortOption]? = nil,
        defaultReasoningEffort: String? = nil
    ) {
        self.id = id
        self.name = name
        self.context_length = context_length
        self.architecture = architecture
        self.reasoningEfforts = reasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
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

    func reconciledReasoningEffort(_ requested: String?) -> String? {
        guard let requested, let reasoningEfforts else { return nil }
        if reasoningEfforts.contains(where: { $0.id == requested }) { return requested }
        guard let defaultReasoningEffort,
              reasoningEfforts.contains(where: { $0.id == defaultReasoningEffort }) else { return nil }
        return defaultReasoningEffort
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
