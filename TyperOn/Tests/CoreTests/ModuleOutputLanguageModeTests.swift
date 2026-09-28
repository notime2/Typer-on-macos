// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@Test
func testResolvedOutputLanguageModeBuiltInDefaults() {
    let config = ModuleAIConfig(useGlobal: true)

    #expect(config.resolvedOutputLanguageMode(for: "translation") == .defaultLanguage)
    #expect(config.resolvedOutputLanguageMode(for: "summarization") == .defaultLanguage)
    #expect(config.resolvedOutputLanguageMode(for: "explain") == .defaultLanguage)
    #expect(config.resolvedOutputLanguageMode(for: "fact-check") == .defaultLanguage)
    #expect(config.resolvedOutputLanguageMode(for: "content-generation") == .defaultLanguage)

    #expect(config.resolvedOutputLanguageMode(for: "grammar-fix") == .sourceLanguage)
    #expect(config.resolvedOutputLanguageMode(for: "rephrasing") == .sourceLanguage)
    #expect(config.resolvedOutputLanguageMode(for: "tone-adjustment") == .sourceLanguage)
}

@Test
func testResolvedOutputLanguageModeCustomModuleDefault() {
    let config = ModuleAIConfig(useGlobal: true)
    #expect(config.resolvedOutputLanguageMode(for: "custom-abcd1234") == .defaultLanguage)
}

@Test
func testModuleAIConfigDecodesLegacyPayload() throws {
    let legacyJSON = """
    {"useGlobal":true,"customAPIKey":null,"customModel":"openai/gpt-4o","customTemperature":null,"customMaxTokens":null}
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(ModuleAIConfig.self, from: legacyJSON)
    #expect(decoded.customSystemPrompt == nil)
    #expect(decoded.outputLanguageMode == nil)
    #expect(decoded.autoReplaceOriginalText == false)
    #expect(decoded.resolvedOutputLanguageMode(for: "grammar-fix") == .sourceLanguage)
}

@Test
func testModuleAIConfigRoundTripsAutomaticReplacement() throws {
    let config = ModuleAIConfig(
        useGlobal: false,
        customModel: "openai/gpt-4o",
        autoReplaceOriginalText: true
    )

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(ModuleAIConfig.self, from: data)

    #expect(decoded.autoReplaceOriginalText)
    #expect(decoded.customModel == "openai/gpt-4o")
}
