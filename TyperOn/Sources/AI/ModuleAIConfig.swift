// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

enum ModuleOutputLanguageMode: String, Codable, CaseIterable, Sendable {
    case defaultLanguage
    case sourceLanguage

    static func defaultMode(for moduleID: String) -> ModuleOutputLanguageMode {
        switch moduleID {
        case "grammar-fix", "rephrasing", "tone-adjustment":
            return .sourceLanguage
        default:
            return .defaultLanguage
        }
    }
}

struct ModuleAIConfig: Codable, Sendable {
    var useGlobal: Bool
    var usesModuleAPIKey: Bool
    var customModel: String?
    var customTemperature: Double?
    var customMaxTokens: Int?
    var customSystemPrompt: String?
    var outputLanguageMode: ModuleOutputLanguageMode?
    var autoReplaceOriginalText: Bool

    init(
        useGlobal: Bool,
        usesModuleAPIKey: Bool = false,
        customModel: String? = nil,
        customTemperature: Double? = nil,
        customMaxTokens: Int? = nil,
        customSystemPrompt: String? = nil,
        outputLanguageMode: ModuleOutputLanguageMode? = nil,
        autoReplaceOriginalText: Bool = false
    ) {
        self.useGlobal = useGlobal
        self.usesModuleAPIKey = usesModuleAPIKey
        self.customModel = customModel
        self.customTemperature = customTemperature
        self.customMaxTokens = customMaxTokens
        self.customSystemPrompt = customSystemPrompt
        self.outputLanguageMode = outputLanguageMode
        self.autoReplaceOriginalText = autoReplaceOriginalText
    }

    static let global = ModuleAIConfig(useGlobal: true)

    func resolvedOutputLanguageMode(for moduleID: String) -> ModuleOutputLanguageMode {
        outputLanguageMode ?? ModuleOutputLanguageMode.defaultMode(for: moduleID)
    }

    private enum CodingKeys: String, CodingKey {
        case useGlobal
        case usesModuleAPIKey
        case customAPIKey
        case customModel
        case customTemperature
        case customMaxTokens
        case customSystemPrompt
        case outputLanguageMode
        case autoReplaceOriginalText
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        useGlobal = try container.decode(Bool.self, forKey: .useGlobal)
        let legacyCustomAPIKey = try container.decodeIfPresent(String.self, forKey: .customAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        usesModuleAPIKey = try container.decodeIfPresent(Bool.self, forKey: .usesModuleAPIKey)
            ?? (legacyCustomAPIKey?.isEmpty == false)
        customModel = try container.decodeIfPresent(String.self, forKey: .customModel)
        customTemperature = try container.decodeIfPresent(Double.self, forKey: .customTemperature)
        customMaxTokens = try container.decodeIfPresent(Int.self, forKey: .customMaxTokens)
        customSystemPrompt = try container.decodeIfPresent(String.self, forKey: .customSystemPrompt)
        outputLanguageMode = try container.decodeIfPresent(ModuleOutputLanguageMode.self, forKey: .outputLanguageMode)
        autoReplaceOriginalText = try container.decodeIfPresent(Bool.self, forKey: .autoReplaceOriginalText) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(useGlobal, forKey: .useGlobal)
        try container.encode(usesModuleAPIKey, forKey: .usesModuleAPIKey)
        try container.encodeIfPresent(customModel, forKey: .customModel)
        try container.encodeIfPresent(customTemperature, forKey: .customTemperature)
        try container.encodeIfPresent(customMaxTokens, forKey: .customMaxTokens)
        try container.encodeIfPresent(customSystemPrompt, forKey: .customSystemPrompt)
        try container.encodeIfPresent(outputLanguageMode, forKey: .outputLanguageMode)
        try container.encode(autoReplaceOriginalText, forKey: .autoReplaceOriginalText)
    }
}

struct ResolvedAIConfig: Sendable {
    let apiKey: String
    let model: String
    let temperature: Double
    let maxTokens: Int
    var reasoningEffort: String? = nil
}
