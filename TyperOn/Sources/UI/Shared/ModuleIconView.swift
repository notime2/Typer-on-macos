// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

@MainActor
struct ModuleIconView: View {
    let icon: String
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size, weight: .medium))
    }
}

@MainActor
struct SelectionSeedGlyphView: View {
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: "pointer.arrow.click")
            .font(.system(size: size, weight: .medium))
    }
}
