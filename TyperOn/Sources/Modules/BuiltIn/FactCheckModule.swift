// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct FactCheckModule: TextModule {
    let id = "fact-check"
    let name = "Fact Check"
    let icon = "checkmark.shield"
    let shortDescription: String? = "Check claims for accuracy"
    let category = ModuleCategory.factCheck

    func buildPrompt(for inputText: String, context: ModuleContext) -> [ChatMessage] {
        let outputLanguage = resolvedOutputLanguageName(context: context)

        let defaultSystemPrompt = """
        You are a careful fact-checking assistant. Review the provided text and evaluate its factual claims using general knowledge only. \
        Rules:
        - Output ONLY the fact check, nothing else
        - The fact check must be in \(outputLanguage)
        - Use 1-6 bullet points depending on how many concrete claims appear in the text
        - Start each bullet point with "- "
        - Begin each bullet with one label: "Supported", "Unclear", "Likely incorrect", or "Opinion"
        - Briefly explain the reasoning in one concise sentence
        - If the text has no concrete factual claims, return one bullet that says so
        - If you cannot verify a claim confidently from general knowledge, mark it as "Unclear"
        - Do not invent sources, quotes, studies, dates, or statistics
        - Be cautious and explicit about uncertainty
        """
        let systemPrompt = resolvedSystemPrompt(defaultPrompt: defaultSystemPrompt, context: context)

        return PromptBuilder.build(
            systemPrompt: systemPrompt,
            userText: inputText,
            userComment: context.userComment
        )
    }
}
