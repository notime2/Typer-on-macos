// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct GrammarFixModule: TextModule {
    let id = "grammar-fix"
    let name = "Grammar & Spelling"
    let icon = "checkmark.circle.dotted"
    let shortDescription: String? = "Fix grammar and spelling"
    let category = ModuleCategory.correction

    func buildPrompt(for inputText: String, context: ModuleContext) -> [ChatMessage] {
        let outputLanguage = resolvedOutputLanguageName(context: context)

        let defaultSystemPrompt = """
        You are a professional proofreader. Fix all grammar, spelling, and punctuation errors in the given text. \
        Rules:
        - Output ONLY the corrected text, nothing else
        - The corrected text must be in \(outputLanguage)
        - Preserve the original meaning, tone, and style
        - Preserve formatting and line breaks
        - If the text has no errors, return it unchanged
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
