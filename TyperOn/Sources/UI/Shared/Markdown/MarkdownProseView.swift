// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

@MainActor
struct MarkdownProseView: View {
    let text: String

    var body: some View {
        MarkdownInlineTextView(
            text: text,
            font: .system(size: 13)
        )
    }
}
