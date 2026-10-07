// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct CustomPromptModule: TextModule {
    let id: String
    let name: String
    let icon: String
    let shortDescription: String?
    let category = ModuleCategory.custom
    let systemPrompt: String

    func buildPrompt(for inputText: String, context: ModuleContext) -> [ChatMessage] {
        let outputLanguage = resolvedOutputLanguageName(context: context)
        let basePrompt = resolvedSystemPrompt(defaultPrompt: systemPrompt, context: context)
        let promptWithLanguageRule = """
        \(basePrompt)

        Output language requirement:
        - The final response must be in \(outputLanguage)
        - Return only the final result, without extra commentary
        """

        return PromptBuilder.build(
            systemPrompt: promptWithLanguageRule,
            userText: inputText,
            userComment: context.userComment
        )
    }
}
