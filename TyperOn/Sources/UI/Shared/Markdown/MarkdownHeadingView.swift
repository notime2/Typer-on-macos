// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

@MainActor
struct MarkdownHeadingView: View {
    let level: Int
    let text: String

    var body: some View {
        MarkdownInlineTextView(
            text: text,
            font: .system(size: fontSize, weight: fontWeight)
        )
    }

    private var fontSize: CGFloat {
        switch level {
        case 1: return 18
        case 2: return 16
        case 3: return 15
        case 4: return 14
        case 5, 6: return 13
        default: return 13
        }
    }

    private var fontWeight: Font.Weight {
        level <= 3 ? .semibold : .medium
    }
}
