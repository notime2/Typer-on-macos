// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

enum SettingsDetailLayout {
    /// Fallback for hosts that report no titlebar inset, so the title never collapses.
    static let minimumTitlebarHeight: CGFloat = 32
    /// Keeps a long tab name off the detail column edges at the minimum window width.
    static let titleHorizontalPadding: CGFloat = DS.Spacing.md
    static let titleFontSize: CGFloat = 13

    static func headerHeight(titlebarInset: CGFloat) -> CGFloat {
        max(titlebarInset, minimumTitlebarHeight)
    }
}

/// One titlebar row for every tab. The bar is applied here, above the tab switch, so the
/// detail column's top content inset can never depend on which tab is selected, and tab
/// content scrolls under the transparent titlebar with the native soft scroll edge effect.
///
/// The window title itself stays hidden, so the tab name appears exactly once.
struct SettingsDetailScaffold<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    @State private var titlebarInset: CGFloat = 0

    var body: some View {
        content()
            .safeAreaBar(edge: .top, spacing: 0) {
                Text(title)
                    .font(.system(size: SettingsDetailLayout.titleFontSize, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, SettingsDetailLayout.titleHorizontalPadding)
                    .frame(maxWidth: .infinity)
                    .frame(height: SettingsDetailLayout.headerHeight(titlebarInset: titlebarInset))
                    .accessibilityAddTraits(.isHeader)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .ignoresSafeArea(.container, edges: .top)
            .background(DS.Colors.background)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { titlebarInset = $0 }
    }
}
