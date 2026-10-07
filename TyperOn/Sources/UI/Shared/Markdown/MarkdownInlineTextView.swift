// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

@MainActor
struct MarkdownInlineTextView: View {
    @Environment(\.dialogTheme) private var theme
    let text: String
    let font: Font
    var textColor: Color?
    @State private var cache = MarkdownTextCache<AttributedString>()

    var body: some View {
        let syntax = cache.value(for: text, parse: MarkdownInlineRenderer.parseSyntax)

        Text(MarkdownInlineRenderer.styled(syntax, theme: theme))
            .font(font)
            .foregroundStyle(textColor ?? theme.textPrimary)
            .tint(theme.accent)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// Keep presentation attributes out of the single-entry syntax cache so an
/// existing response can adopt a new theme without parsing its Markdown again.
enum MarkdownInlineRenderer {
    static func parseSyntax(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func styled(_ syntax: AttributedString, theme: DialogTheme) -> AttributedString {
        var result = syntax

        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                let range = run.range
                result[range].font = .system(size: 12, design: .monospaced)
                result[range].foregroundColor = theme.textPrimary
                result[range].backgroundColor = theme.codeInlineBackground
            }
        }

        return result
    }
}
