// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

enum PromptBuilder {
    static func build(
        systemPrompt: String,
        userText: String,
        userComment: String? = nil
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = [
            .system(systemPrompt),
            .user(userText)
        ]

        if let comment = userComment, !comment.isEmpty {
            messages.append(.user("Additional instructions: \(comment)"))
        }

        return messages
    }
}
