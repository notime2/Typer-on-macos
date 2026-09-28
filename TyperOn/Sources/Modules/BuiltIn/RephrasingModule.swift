// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct RephrasingModule: TextModule {
    let id = "rephrasing"
    let name = "Rephrase"
    let icon = "arrow.trianglehead.2.clockwise.rotate.90"
    let shortDescription: String? = "Rewrite without changing meaning"
    let category = ModuleCategory.style

    func buildPrompt(for inputText: String, context: ModuleContext) -> [ChatMessage] {
        let outputLanguage = resolvedOutputLanguageName(context: context)

        let defaultSystemPrompt = """
        You are a professional editor. Rephrase the given text to improve clarity and flow while keeping the same meaning. \
        Rules:
        - Output ONLY the rephrased text, nothing else
        - The rephrased text must be in \(outputLanguage)
        - Keep the same meaning and intent
        - Improve readability and flow
        - Maintain the general tone (formal/informal)
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
