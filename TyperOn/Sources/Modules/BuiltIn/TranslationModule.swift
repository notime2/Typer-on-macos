// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import NaturalLanguage

struct TranslationModule: TextModule {
    let id = "translation"
    let name = "Translate"
    let icon = "globe"
    let shortDescription: String? = "Translate to target language"
    let category = ModuleCategory.translation

    func buildPrompt(for inputText: String, context: ModuleContext) -> [ChatMessage] {
        let targetLanguage = resolveTargetLanguage(for: inputText, context: context)

        let defaultSystemPrompt = """
        You are a professional translator. Translate the given text to \(targetLanguage). \
        Rules:
        - Output ONLY the translated text, nothing else
        - Preserve the original formatting, line breaks, and structure
        - Maintain the tone and style of the original
        - Do not add explanations, notes, or commentary
        - If the text contains technical terms, translate them appropriately for the target language
        """
        let systemPrompt = resolvedSystemPrompt(defaultPrompt: defaultSystemPrompt, context: context)

        return PromptBuilder.build(
            systemPrompt: systemPrompt,
            userText: inputText,
            userComment: context.userComment
        )
    }

    private func resolveTargetLanguage(for text: String, context: ModuleContext) -> String {
        switch context.outputLanguageMode {
        case .defaultLanguage:
            // The caller normally detects the source language once; detect here only when it did not.
            let sourceLanguageName = context.sourceLanguageName ?? text.detectedLanguageDisplayName
            return resolveTargetLanguage(
                preferred: context.targetLanguage,
                sourceLanguageName: sourceLanguageName,
                fallback: context.fallbackTargetLanguage
            )
        case .sourceLanguage:
            return context.sourceLanguageName ?? String.defaultLanguageDetectionFallback
        }
    }

    /// Targets the default language unless the input is already in it. Then the context
    /// fallback applies, otherwise English, and an English default with no distinct
    /// alternative keeps English.
    private func resolveTargetLanguage(preferred: String, sourceLanguageName: String, fallback: String?) -> String {
        guard TargetLanguageCatalog.isSameLanguage(sourceLanguageName, preferred) else {
            return preferred
        }
        if let fallback, !TargetLanguageCatalog.isSameLanguage(fallback, preferred) {
            return fallback
        }
        let english = TargetLanguageCatalog.universalFallbackLanguage
        return TargetLanguageCatalog.isSameLanguage(preferred, english) ? preferred : english
    }
}
