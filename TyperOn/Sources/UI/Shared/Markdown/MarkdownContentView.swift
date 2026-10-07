// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

@MainActor
struct MarkdownContentView: View {
    let text: String
    let isStreaming: Bool
    @State private var cache = MarkdownTextCache<[MarkdownBlock]>()

    var body: some View {
        let blocks = cache.value(for: text, parse: MarkdownParser.parse)

        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            ForEach(blocks) { block in
                switch block.kind {
                case .prose(let content):
                    MarkdownProseView(text: content)
                case .heading(let level, let content):
                    MarkdownHeadingView(level: level, text: content)
                case .unorderedList(let items):
                    MarkdownListView(items: items)
                case .blockquote(let content):
                    MarkdownBlockquoteView(text: content)
                case .codeBlock(let language, let code):
                    MarkdownCodeBlockView(language: language, code: code)
                }
            }

            if isStreaming {
                StreamingCursor()
            }
        }
    }
}
