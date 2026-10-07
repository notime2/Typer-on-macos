// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

@MainActor
struct MarkdownBlockquoteView: View {
    @Environment(\.dialogTheme) private var theme
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Rectangle()
                .fill(theme.border)
                .frame(width: 3)

            MarkdownInlineTextView(
                text: text,
                font: .system(size: 13),
                textColor: theme.textSecondary
            )
        }
        .padding(DS.Spacing.md)
        .background(
            theme.codeBackground,
            in: RoundedRectangle(cornerRadius: theme.cardRadius)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
