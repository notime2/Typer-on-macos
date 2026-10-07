// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

@MainActor
struct MarkdownListView: View {
    @Environment(\.dialogTheme) private var theme
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: DS.Spacing.sm) {
                    Text("•")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)

                    MarkdownInlineTextView(
                        text: item,
                        font: .system(size: 13)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
