// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

struct LoadingIndicator: View {
    @Environment(\.dialogTheme) private var theme
    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            ProgressView()
                .controlSize(.small)

            Text("Processing...")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
        }
    }
}
