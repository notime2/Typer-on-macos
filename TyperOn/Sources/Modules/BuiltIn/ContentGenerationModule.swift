// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct ContentGenerationModule: TextModule {
    let id = "content-generation"
    let name = "Chat Mode"
    let icon = "app.background.dotted"
    let shortDescription: String? = "Chat on any topic or with context"
    let category = ModuleCategory.generation

    static func buildSystemPrompt(context: ModuleContext) -> String {
        let module = ContentGenerationModule()
        let outputLanguage = module.resolvedOutputLanguageName(context: context)

        let defaultSystemPrompt = """
        You are a helpful AI assistant. Answer the user's requests clearly and concisely. \
        Rules:
        - Respond in \(outputLanguage)
        - Use any provided source text as context when it helps answer the user's request
        - Be direct, practical, and focused
        - Ask for clarification only when the request is genuinely ambiguous
        - Avoid unnecessary meta-commentary
        """

        return module.resolvedSystemPrompt(defaultPrompt: defaultSystemPrompt, context: context)
    }

    func buildPrompt(for inputText: String, context: ModuleContext) -> [ChatMessage] {
        return PromptBuilder.build(
            systemPrompt: Self.buildSystemPrompt(context: context),
            userText: inputText,
            userComment: context.userComment
        )
    }
}
