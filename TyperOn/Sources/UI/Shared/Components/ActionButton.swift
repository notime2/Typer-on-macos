// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

struct ActionButton: View {
    @Environment(\.dialogTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let icon: String?
    let style: ActionButtonStyle
    let minWidth: CGFloat?
    let fixedHeight: CGFloat?
    let action: () -> Void

    init(
        _ title: String,
        icon: String? = nil,
        style: ActionButtonStyle = .ghost,
        minWidth: CGFloat? = nil,
        fixedHeight: CGFloat? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.style = style
        self.minWidth = minWidth
        self.fixedHeight = fixedHeight
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .regular))
                }
                Text(title)
                    .font(.system(size: 13, weight: style == .primary ? .medium : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .frame(minWidth: minWidth, minHeight: fixedHeight, maxHeight: fixedHeight)
            .foregroundStyle(style == .primary ? theme.primaryForeground : (style == .destructive ? .red : theme.textPrimary))
            .dialogControlSurface(
                RoundedRectangle(cornerRadius: theme.controlRadius(height: fixedHeight ?? 32), style: theme.cornerStyle),
                fill: style == .primary ? theme.primaryBackground : .clear,
                lineWidth: 0,
                tint: style == .primary && isEnabled ? theme.accent : nil
            )
            .contentShape(RoundedRectangle(cornerRadius: theme.controlRadius(height: fixedHeight ?? 32)))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

enum ActionButtonStyle {
    case primary
    case ghost
    case destructive
}
