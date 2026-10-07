// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

/// Presentation-only values. Never use a theme as a view identity or session key.
struct DialogTheme {
    let style: SelectionTriggerStyle
    private let selection: SelectionUITheme

    init(style: SelectionTriggerStyle) {
        self.style = style
        self.selection = SelectionUITheme(style: style)
    }

    /// Native Liquid Glass belongs only to Glass Dot dialog chrome.
    var usesNativeGlass: Bool { style == .glassDot }

    var background: AnyShapeStyle {
        style == .glassDot ? AnyShapeStyle(DS.Colors.background) : selection.expandedBackground
    }
    var textPrimary: Color { selection.toolbarGlyphColor }
    var textSecondary: Color { style == .glassDot ? DS.Colors.textSecondary : textPrimary.opacity(0.72) }
    var textTertiary: Color { style == .glassDot ? DS.Colors.textTertiary : textPrimary.opacity(0.58) }
    var accent: Color {
        switch style {
        case .editorial: SelectionUIThemePalette.editorialMutedClay.color
        case .monochromeInk: textPrimary
        default: DS.Colors.accent
        }
    }
    var surface: Color {
        switch style {
        case .glassDot: DS.Colors.surface
        case .softAccent: SelectionUIThemePalette.editorialPaper.color
        case .monochromeInk: SelectionUIThemePalette.monochromeCompactBackground.color
        case .editorial: SelectionUIThemePalette.editorialQuietHover.color
        }
    }
    var surfaceHover: Color { selection.toolbarButtonHoverColor }
    var border: Color { style == .monochromeInk ? textPrimary.opacity(0.38) : selection.toolbarStrokeColor }
    var borderWidth: CGFloat { style == .monochromeInk ? 1 : 0.5 }
    var cardRadius: CGFloat { style == .editorial ? DS.Radius.button : DS.Radius.card }
    var buttonRadius: CGFloat { style == .softAccent ? DS.Radius.card : DS.Radius.button }
    var codeBackground: Color { style == .glassDot ? DS.Colors.codeBlockBackground : surface }
    var codeInlineBackground: Color { style == .glassDot ? DS.Colors.codeInlineBackground : surfaceHover }
    var primaryForeground: Color {
        switch style {
        case .monochromeInk: DS.Colors.background
        case .softAccent, .editorial: textPrimary
        case .glassDot: .white
        }
    }
    var primaryBackground: Color {
        switch style {
        case .softAccent, .editorial: accent.opacity(0.18)
        default: accent
        }
    }

    // MARK: Content layer

    /// Glass Dot content cards drop their strokes for soft fills and continuous corners.
    var cornerStyle: RoundedCornerStyle { usesNativeGlass ? .continuous : .circular }
    var contentRadius: CGFloat { usesNativeGlass ? 14 : cardRadius }
    var contentSurface: Color { usesNativeGlass ? DS.Colors.surfaceHover : surface }
    var contentBorder: Color { usesNativeGlass ? .clear : border }

    /// Glass Dot controls are capsules; other styles keep their themed radius.
    func controlRadius(height: CGFloat) -> CGFloat {
        usesNativeGlass ? height / 2 : buttonRadius
    }
}

private struct DialogThemeKey: EnvironmentKey {
    static let defaultValue = DialogTheme(style: .glassDot)
}

extension EnvironmentValues {
    var dialogTheme: DialogTheme {
        get { self[DialogThemeKey.self] }
        set { self[DialogThemeKey.self] = newValue }
    }
}

/// Shared Chat/Processing layout. Neither the structure nor the bar geometry depends on the
/// theme, so the editor, attachments and the scroll view's content insets (and with them the
/// scroll position) stay unchanged when the style changes.
///
/// The header is a centered title in the titlebar row for every style, with trailing controls
/// inside the side reserve. Glass Dot keeps it
/// transparent and lets content scroll edge-to-edge beneath it and the floating glass controls,
/// separated by the native scroll edge effect; other styles use opaque bars with dividers.
struct DialogScaffold<Header: View, Accessory: View, Content: View, BottomBar: View>: View {
    @Environment(\.dialogTheme) private var theme
    @State private var titlebarHeight: CGFloat = 0

    @ViewBuilder let header: () -> Header
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content
    @ViewBuilder let bottomBar: () -> BottomBar

    /// Keeps the title legible in hosts without a transparent titlebar.
    private static var minimumHeaderHeight: CGFloat { 32 }
    /// Keeps the centered title clear of the window buttons.
    private static var titlebarButtonsReserve: CGFloat { 80 }

    var body: some View {
        content()
            .safeAreaBar(edge: .top, spacing: 0) {
                HStack(spacing: DS.Spacing.sm) {
                    header()
                }
                .lineLimit(1)
                .padding(.horizontal, Self.titlebarButtonsReserve)
                .frame(maxWidth: .infinity)
                .frame(height: max(titlebarHeight, Self.minimumHeaderHeight))
                .overlay(alignment: .trailing) {
                    HStack(spacing: 0) {
                        accessory()
                    }
                    .padding(.trailing, DS.Spacing.sm)
                }
                .dialogBar(edge: .top)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                GlassEffectContainer {
                    bottomBar()
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.md)
                }
                .dialogBar(edge: .bottom)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .scrollEdgeEffectHidden(!theme.usesNativeGlass, for: .vertical)
            .ignoresSafeArea(.container, edges: .top)
            .background(theme.background)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { titlebarHeight = $0 }
    }
}

/// Only decoration changes; the bar content keeps its identity.
private struct DialogBar: ViewModifier {
    @Environment(\.dialogTheme) private var theme
    let edge: VerticalEdge

    func body(content: Content) -> some View {
        content
            .background(theme.usesNativeGlass ? AnyShapeStyle(Color.clear) : theme.background)
            .overlay(alignment: edge == .top ? .bottom : .top) {
                // The header divider lies inside the titlebar safe area; a style overlay
                // would otherwise flood that whole area and cover the title.
                Divider()
                    .overlay(theme.border, ignoresSafeAreaEdges: [])
                    .opacity(theme.usesNativeGlass ? 0 : 1)
            }
    }
}

/// Liquid Glass for Glass Dot controls, the themed fill and stroke for the other styles.
/// `Glass.identity` keeps one modifier chain, so switching styles never rebuilds the control.
private struct DialogControlSurface<S: Shape>: ViewModifier {
    @Environment(\.dialogTheme) private var theme
    let shape: S
    let fill: Color
    let lineWidth: CGFloat?
    let tint: Color?
    let isInteractive: Bool

    func body(content: Content) -> some View {
        let glass = theme.usesNativeGlass
        let strokeWidth = lineWidth ?? theme.borderWidth
        content
            .background(glass ? Color.clear : fill, in: shape)
            .overlay {
                // A zero-width stroke would still draw a hairline.
                shape.stroke(glass || strokeWidth == 0 ? Color.clear : theme.border, lineWidth: strokeWidth)
            }
            .glassEffect(glass ? Glass.regular.tint(tint).interactive(isInteractive) : .identity, in: shape)
    }
}

extension View {
    func dialogBar(edge: VerticalEdge) -> some View { modifier(DialogBar(edge: edge)) }

    func dialogControlSurface<S: Shape>(
        _ shape: S,
        fill: Color,
        lineWidth: CGFloat? = nil,
        tint: Color? = nil,
        isInteractive: Bool = true
    ) -> some View {
        modifier(DialogControlSurface(
            shape: shape, fill: fill, lineWidth: lineWidth, tint: tint, isInteractive: isInteractive
        ))
    }

    func dialogCardBorder(_ theme: DialogTheme) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: theme.contentRadius, style: theme.cornerStyle)
                .stroke(theme.contentBorder, lineWidth: theme.borderWidth)
        }
    }
}
