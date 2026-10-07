// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct ExplainModule: TextModule {
    let id = "explain"
    let name = "Explain"
    let icon = "magnifyingglass"
    let shortDescription: String? = "Explain in simple terms"
    let category = ModuleCategory.explain

    func buildPrompt(for inputText: String, context: ModuleContext) -> [ChatMessage] {
        let outputLanguage = resolvedOutputLanguageName(context: context)

        let defaultSystemPrompt = """
        You are a clear writing coach. Explain the meaning of the provided text in short, simple bullet points. \
        Rules:
        - Output ONLY the explanation, nothing else
        - The explanation must be in \(outputLanguage)
        - Use 3-6 bullet points depending on text complexity
        - Start each bullet point with "- "
        - Keep each bullet concise and easy to understand
        - Focus on the core meaning, intent, and key details
        - Do not add meta-commentary, introductions, or conclusions
        """
        let systemPrompt = resolvedSystemPrompt(defaultPrompt: defaultSystemPrompt, context: context)

        return PromptBuilder.build(
            systemPrompt: systemPrompt,
            userText: inputText,
            userComment: context.userComment
        )
    }
}
