// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct ToneAdjustmentModule: TextModule {
    let id = "tone-adjustment"
    let name = "Adjust Tone"
    let icon = "eyeglasses"
    let shortDescription: String? = "Change tone, keep meaning"
    let category = ModuleCategory.style

    func buildPrompt(for inputText: String, context: ModuleContext) -> [ChatMessage] {
        let tone = "professional"
        let outputLanguage = resolvedOutputLanguageName(context: context)

        let defaultSystemPrompt = """
        You are a professional editor. Rewrite the given text to match a \(tone) tone. \
        Rules:
        - Output ONLY the rewritten text, nothing else
        - The rewritten text must be in \(outputLanguage)
        - Adjust vocabulary, sentence structure, and phrasing to match the \(tone) tone
        - Keep the same meaning and core message
        - Preserve formatting and structure
        - Do not add explanations or notes
        """
        let systemPrompt = resolvedSystemPrompt(defaultPrompt: defaultSystemPrompt, context: context)

        return PromptBuilder.build(
            systemPrompt: systemPrompt,
            userText: inputText,
            userComment: context.userComment
        )
    }
}
