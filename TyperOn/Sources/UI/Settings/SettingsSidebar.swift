// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

/// System Settings style badge tints. The tint is a named case rather than a raw `Color`
/// so the sidebar row model stays comparable in tests.
enum SettingsSidebarBadgeTint: String, CaseIterable {
    case gray
    case blue
    case purple
    case orange
    case green

    var color: Color {
        switch self {
        case .gray: Color(nsColor: .systemGray)
        case .blue: Color(nsColor: .systemBlue)
        case .purple: Color(nsColor: .systemPurple)
        case .orange: Color(nsColor: .systemOrange)
        case .green: Color(nsColor: .systemGreen)
        }
    }
}

extension SettingsTab {
    var badgeTint: SettingsSidebarBadgeTint {
        switch self {
        case .general: .gray
        case .api: .blue
        case .modules: .purple
        case .customPrompts: .orange
        case .chatHistory: .green
        }
    }
}

/// One sidebar row. Every value is derived from `SettingsTab`, so the sidebar can never
/// drift from the tab order the rest of Settings and `AppEnvironment.settingsState` use.
struct SettingsSidebarItem: Identifiable, Equatable {
    let tab: SettingsTab

    var id: SettingsTab { tab }
    var title: String { tab.title }
    var systemImage: String { tab.icon }
    var badgeTint: SettingsSidebarBadgeTint { tab.badgeTint }

    static var all: [SettingsSidebarItem] {
        SettingsTab.allCases.map(SettingsSidebarItem.init)
    }
}

enum SettingsSidebarLayout {
    /// System Settings uses a small filled rounded square, not a bare glyph.
    static let badgeSize: CGFloat = 20
    static let badgeCornerRadius: CGFloat = 5
    static let badgeSymbolSize: CGFloat = 12
    static let rowSpacing: CGFloat = DS.Spacing.sm
}

struct SettingsSidebarBadge: View {
    let systemImage: String
    let tint: SettingsSidebarBadgeTint

    var body: some View {
        RoundedRectangle(cornerRadius: SettingsSidebarLayout.badgeCornerRadius, style: .continuous)
            .fill(tint.color)
            .frame(width: SettingsSidebarLayout.badgeSize, height: SettingsSidebarLayout.badgeSize)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: SettingsSidebarLayout.badgeSymbolSize, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

struct SettingsSidebarRow: View {
    let item: SettingsSidebarItem

    var body: some View {
        HStack(spacing: SettingsSidebarLayout.rowSpacing) {
            SettingsSidebarBadge(systemImage: item.systemImage, tint: item.badgeTint)
            Text(item.title)
            Spacer(minLength: 0)
        }
        // The whole row stays the hit target, not only the badge and the label.
        .contentShape(Rectangle())
        .accessibilityLabel(item.title)
    }
}
