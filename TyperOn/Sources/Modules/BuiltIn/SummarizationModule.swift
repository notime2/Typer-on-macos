// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct SummarizationModule: TextModule {
    let id = "summarization"
    let name = "Summarize"
    let icon = "sum"
    let shortDescription: String? = "Condense to key points"
    let category = ModuleCategory.summarization

    func buildPrompt(for inputText: String, context: ModuleContext) -> [ChatMessage] {
        let outputLanguage = resolvedOutputLanguageName(context: context)

        let defaultSystemPrompt = """
        You are a professional summarizer. Condense the given text into concise bullet points. \
        Rules:
        - Output ONLY the bullet-point summary, nothing else
        - The summary must be in \(outputLanguage)
        - Use "- " prefix for each bullet point
        - Capture the key points and essential information
        - Keep bullet points concise (1-2 sentences each)
        - Aim for 3-7 bullet points depending on text length
        - Do not add introductions, conclusions, or notes
        """
        let systemPrompt = resolvedSystemPrompt(defaultPrompt: defaultSystemPrompt, context: context)

        return PromptBuilder.build(
            systemPrompt: systemPrompt,
            userText: inputText,
            userComment: context.userComment
        )
    }
}
