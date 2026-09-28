// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

enum SelectionTriggerStyle: String, CaseIterable, Codable, Identifiable {
    case glassDot
    case softAccent
    case monochromeInk
    case editorial

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .glassDot:
            "Glass Dot"
        case .softAccent:
            "Soft Accent"
        case .monochromeInk:
            "Monochrome Ink"
        case .editorial:
            "Editorial"
        }
    }

    var shortDescription: String {
        switch self {
        case .glassDot:
            "Light glass trigger with native material."
        case .softAccent:
            "Accent-led trigger with restrained toolbar chrome."
        case .monochromeInk:
            "Matte monochrome look with firmer borders."
        case .editorial:
            "Warm paper surfaces with quiet editorial accents."
        }
    }
}

enum FloatingToolbarSurfaceTreatment: Equatable {
    case nativeLiquidGlass
    case fallbackChrome

    static func resolve(
        style: SelectionTriggerStyle,
        nativeLiquidGlassAvailable: Bool
    ) -> FloatingToolbarSurfaceTreatment {
        if style == .glassDot && nativeLiquidGlassAvailable {
            return .nativeLiquidGlass
        }
        return .fallbackChrome
    }

    static func resolve(style: SelectionTriggerStyle) -> FloatingToolbarSurfaceTreatment {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return resolve(style: style, nativeLiquidGlassAvailable: true)
        }
        #endif

        return .fallbackChrome
    }
}

enum SelectionUIThemePalette {
    struct AdaptiveHexColor: Equatable, Sendable {
        let lightHex: UInt
        let darkHex: UInt

        var color: Color {
            Color(
                light: Color(hex: lightHex),
                dark: Color(hex: darkHex)
            )
        }
    }

    static let monochromeCompactBackground = AdaptiveHexColor(
        lightHex: 0xF4F2EE,
        darkHex: 0x282725
    )
    static let editorialPaper = AdaptiveHexColor(
        lightHex: 0xFBFAF7,
        darkHex: 0x312D28
    )
    static let editorialInk = AdaptiveHexColor(
        lightHex: 0x302C28,
        darkHex: 0xEEE9E2
    )
    static let editorialHairline = AdaptiveHexColor(
        lightHex: 0xE3DED6,
        darkHex: 0x49443E
    )
    static let editorialQuietHover = AdaptiveHexColor(
        lightHex: 0xF1ECE6,
        darkHex: 0x39342F
    )
    static let editorialMutedClay = AdaptiveHexColor(
        lightHex: 0xC77C65,
        darkHex: 0xD89A86
    )
}

struct FloatingToolbarLayoutMetrics {
    static let defaultCompactVisibleSize: CGFloat = 16
    static let defaultCompactInteractiveSize: CGFloat = 20
    static let defaultProcessingIndicatorWidth: CGFloat = 44
    static let defaultProcessingIndicatorHeight: CGFloat = 24
    static let defaultExpandedHeight: CGFloat = 44
    static let defaultCursorAnchorOffset = CGPoint(x: -14, y: -10)
    static let defaultScreenMargin: CGFloat = 4
    static let defaultSelectionGap: CGFloat = 4
    static let defaultCursorFallbackGap: CGFloat = 8

    let compactVisibleSize: CGFloat
    let compactInteractiveSize: CGFloat
    let processingIndicatorWidth: CGFloat
    let processingIndicatorHeight: CGFloat
    let expandedHeight: CGFloat
    let toolbarButtonSize: CGFloat
    let toolbarHorizontalPadding: CGFloat
    let toolbarVerticalPadding: CGFloat
    let itemSpacing: CGFloat
    let dividerLineWidth: CGFloat
    let dividerHorizontalPadding: CGFloat
    let cursorAnchorOffset: CGPoint
    let screenMargin: CGFloat
    let selectionGap: CGFloat
    let cursorFallbackGap: CGFloat

    init(
        compactVisibleSize: CGFloat = Self.defaultCompactVisibleSize,
        compactInteractiveSize: CGFloat = Self.defaultCompactInteractiveSize,
        processingIndicatorWidth: CGFloat = Self.defaultProcessingIndicatorWidth,
        processingIndicatorHeight: CGFloat = Self.defaultProcessingIndicatorHeight,
        expandedHeight: CGFloat = Self.defaultExpandedHeight,
        toolbarButtonSize: CGFloat = 32,
        toolbarHorizontalPadding: CGFloat = DS.Spacing.sm,
        toolbarVerticalPadding: CGFloat = DS.Spacing.sm - 2,
        itemSpacing: CGFloat = DS.Spacing.xs,
        dividerLineWidth: CGFloat = 1,
        dividerHorizontalPadding: CGFloat = 2,
        cursorAnchorOffset: CGPoint = Self.defaultCursorAnchorOffset,
        screenMargin: CGFloat = Self.defaultScreenMargin,
        selectionGap: CGFloat = Self.defaultSelectionGap,
        cursorFallbackGap: CGFloat = Self.defaultCursorFallbackGap
    ) {
        self.compactVisibleSize = compactVisibleSize
        self.compactInteractiveSize = compactInteractiveSize
        self.processingIndicatorWidth = processingIndicatorWidth
        self.processingIndicatorHeight = processingIndicatorHeight
        self.expandedHeight = expandedHeight
        self.toolbarButtonSize = toolbarButtonSize
        self.toolbarHorizontalPadding = toolbarHorizontalPadding
        self.toolbarVerticalPadding = toolbarVerticalPadding
        self.itemSpacing = itemSpacing
        self.dividerLineWidth = dividerLineWidth
        self.dividerHorizontalPadding = dividerHorizontalPadding
        self.cursorAnchorOffset = cursorAnchorOffset
        self.screenMargin = screenMargin
        self.selectionGap = selectionGap
        self.cursorFallbackGap = cursorFallbackGap
    }

    func expandedWidth(moduleCount: Int) -> CGFloat {
        let toolbarButtonCount = CGFloat(max(moduleCount, 0) + 1)
        let buttonWidth = toolbarButtonCount * toolbarButtonSize
        let spacingWidth = CGFloat(max(moduleCount, 0) + 1) * itemSpacing
        let dividerWidth = dividerLineWidth + (dividerHorizontalPadding * 2)
        return (toolbarHorizontalPadding * 2) + buttonWidth + spacingWidth + dividerWidth
    }

    func expandedSize(moduleCount: Int) -> CGSize {
        CGSize(width: expandedWidth(moduleCount: moduleCount), height: expandedHeight)
    }

    var processingIndicatorSize: CGSize {
        CGSize(width: processingIndicatorWidth, height: processingIndicatorHeight)
    }

    var compactSizeValue: CGSize {
        CGSize(width: compactInteractiveSize, height: compactInteractiveSize)
    }

    /// Resting size for a presentation mode. Intermediate sizes come from the morph timeline.
    func targetSize(
        for mode: FloatingToolbarPresentationMode,
        moduleCount: Int
    ) -> CGSize {
        switch mode {
        case .compact:
            compactSizeValue
        case .expanded:
            expandedSize(moduleCount: moduleCount)
        }
    }

    func toolbarContentWidth(for containerWidth: CGFloat) -> CGFloat {
        max(0, containerWidth - (toolbarHorizontalPadding * 2))
    }
}

struct SelectionUITheme {
    let style: SelectionTriggerStyle
    var expandedCornerRadius: CGFloat {
        style == .editorial ? DS.Radius.card : DS.Radius.panel
    }
    let compactCornerRadius: CGFloat = 8
    let toolbarStrokeColor: Color
    let toolbarButtonHoverColor: Color
    let compactStrokeColor: Color
    let compactGlyphColor: Color
    let toolbarGlyphColor: Color
    let compactLabelColor: Color
    let compactBackground: AnyShapeStyle
    let expandedBackground: AnyShapeStyle
    let expandedShadow: ShadowStyle
    let compactShadow: ShadowStyle

    init(style: SelectionTriggerStyle) {
        self.style = style
        let neutralSoftInk = Color(
            light: Color(hex: 0x2F2822),
            dark: Color(hex: 0xEEE7DF)
        )

        switch style {
        case .glassDot:
            toolbarStrokeColor = DS.Colors.separator.opacity(0.9)
            toolbarButtonHoverColor = DS.Colors.surfaceHover.opacity(0.9)
            compactStrokeColor = DS.Colors.separator.opacity(0.85)
            compactGlyphColor = DS.Colors.textPrimary
            toolbarGlyphColor = DS.Colors.textPrimary
            compactLabelColor = DS.Colors.textSecondary
            compactBackground = AnyShapeStyle(.ultraThinMaterial)
            expandedBackground = AnyShapeStyle(.ultraThinMaterial)
            expandedShadow = DS.Shadow.medium
            compactShadow = DS.Shadow.subtle
        case .softAccent:
            toolbarStrokeColor = DS.Colors.accent.opacity(0.18)
            toolbarButtonHoverColor = DS.Colors.accent.opacity(0.12)
            compactStrokeColor = DS.Colors.accent.opacity(0.32)
            compactGlyphColor = neutralSoftInk
            toolbarGlyphColor = neutralSoftInk
            compactLabelColor = DS.Colors.textSecondary
            compactBackground = AnyShapeStyle(DS.Colors.accent)
            expandedBackground = AnyShapeStyle(
                Color(
                    light: Color(hex: 0xFFFDFC),
                    dark: Color(hex: 0x2F2B28)
                )
            )
            expandedShadow = DS.Shadow.medium
            compactShadow = DS.Shadow.medium
        case .monochromeInk:
            toolbarStrokeColor = DS.Colors.separator.opacity(0.95)
            toolbarButtonHoverColor = Color(
                light: Color(hex: 0xECEBE8),
                dark: Color(hex: 0x343331)
            )
            compactStrokeColor = DS.Colors.separator.opacity(0.95)
            compactGlyphColor = DS.Colors.textPrimary
            toolbarGlyphColor = DS.Colors.textPrimary
            compactLabelColor = DS.Colors.textSecondary
            compactBackground = AnyShapeStyle(
                SelectionUIThemePalette.monochromeCompactBackground.color
            )
            expandedBackground = AnyShapeStyle(
                Color(
                    light: Color(hex: 0xF7F5F1),
                    dark: Color(hex: 0x232220)
                )
            )
            expandedShadow = DS.Shadow.subtle
            compactShadow = DS.Shadow.subtle
        case .editorial:
            let paper = SelectionUIThemePalette.editorialPaper.color
            let ink = SelectionUIThemePalette.editorialInk.color
            let hairline = SelectionUIThemePalette.editorialHairline.color
            let quietHover = SelectionUIThemePalette.editorialQuietHover.color
            let mutedClay = SelectionUIThemePalette.editorialMutedClay.color
            let previewShadow = ShadowStyle(
                color: Color.black.opacity(0.04),
                radius: 4,
                y: 2
            )

            toolbarStrokeColor = hairline
            toolbarButtonHoverColor = quietHover
            compactStrokeColor = hairline
            compactGlyphColor = ink
            toolbarGlyphColor = ink
            compactLabelColor = mutedClay
            compactBackground = AnyShapeStyle(paper)
            expandedBackground = AnyShapeStyle(paper)
            expandedShadow = previewShadow
            compactShadow = previewShadow
        }
    }
}
