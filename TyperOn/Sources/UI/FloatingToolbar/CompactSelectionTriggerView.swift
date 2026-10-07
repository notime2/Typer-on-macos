// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

@MainActor
struct CompactSelectionTriggerView: View {
    let theme: SelectionUITheme
    let onHoverChanged: (Bool) -> Void
    let onActivate: () -> Void

    @State private var isHovered = false
    private let layout = FloatingToolbarLayoutMetrics()

    var body: some View {
        Button(action: onActivate) {
            SelectionTriggerSeedView(
                theme: theme,
                isHovered: isHovered,
                showsBadge: true
            )
            .frame(width: layout.compactInteractiveSize, height: layout.compactInteractiveSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show toolbar")
        .onHover { hovering in
            isHovered = hovering
            onHoverChanged(hovering)
        }
    }
}

@MainActor
struct SelectionTriggerSeedView: View {
    let theme: SelectionUITheme
    var isHovered: Bool
    var showsBadge: Bool
    var drawsSurfaceChrome: Bool = true

    private let layout = FloatingToolbarLayoutMetrics()

    var body: some View {
        if drawsSurfaceChrome {
            seedContent
                .overlay(
                    Circle()
                        .stroke(theme.compactStrokeColor, lineWidth: 1)
                )
        } else {
            seedContent
        }
    }

    private var seedContent: some View {
        ZStack {
            if drawsSurfaceChrome {
                Circle()
                    .fill(theme.compactBackground)
            }

            SelectionSeedGlyphView(size: layout.compactVisibleSize * 0.72)
                .foregroundStyle(theme.compactGlyphColor)
        }
        .frame(width: layout.compactVisibleSize, height: layout.compactVisibleSize)
        .scaleEffect(isHovered ? 1.04 : 1)
        .animation(.timingCurve(0.16, 0.90, 0.24, 1.0, duration: 0.12), value: isHovered)
        .overlay(alignment: .bottomTrailing) {
            if showsBadge {
                Circle()
                    .fill(theme.compactLabelColor.opacity(0.9))
                    .frame(width: 4, height: 4)
                    .offset(x: -1, y: -1)
            }
        }
    }
}

@MainActor
struct SelectionStylePreviewStrip: View {
    @Binding var selectedStyle: SelectionTriggerStyle

    private let columns = [
        GridItem(.adaptive(minimum: 168), spacing: DS.Spacing.md, alignment: .top)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: DS.Spacing.md) {
            ForEach(SelectionTriggerStyle.allCases) { style in
                SelectionStylePreviewCard(
                    style: style,
                    isSelected: selectedStyle == style
                )
                .onTapGesture {
                    selectedStyle = style
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SelectionStylePreviewCard: View {
    let style: SelectionTriggerStyle
    let isSelected: Bool

    private var theme: SelectionUITheme {
        SelectionUITheme(style: style)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(style.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)

            HStack(spacing: DS.Spacing.sm) {
                CompactSelectionTriggerView(
                    theme: theme,
                    onHoverChanged: { _ in },
                    onActivate: {}
                )
                .allowsHitTesting(false)
                .dsShadow(theme.compactShadow)

                HStack(spacing: DS.Spacing.xs) {
                    previewIcon("sum")
                    previewIcon("app.background.dotted")
                    previewIcon("magnifyingglass")
                }
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.sm - 2)
                .background(theme.expandedBackground, in: RoundedRectangle(cornerRadius: theme.expandedCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.expandedCornerRadius)
                        .stroke(theme.toolbarStrokeColor, lineWidth: 1)
                )
                .dsShadow(theme.expandedShadow)
            }

            Text(style.shortDescription)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            DS.Colors.surface,
            in: RoundedRectangle(cornerRadius: DS.Radius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .stroke(
                    isSelected ? DS.Colors.accent.opacity(0.45) : DS.Colors.separator,
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
    }

    private func previewIcon(_ icon: String) -> some View {
        ModuleIconView(icon: icon, size: 12)
            .foregroundStyle(theme.toolbarGlyphColor)
            .frame(width: 26, height: 26)
            .background(
                theme.toolbarButtonHoverColor.opacity(style == .glassDot ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: DS.Radius.button)
            )
    }
}
