// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

// MARK: - Notion-inspired Design System

enum DS {
    // MARK: - Colors
    enum Colors {
        static let background = Color(light: .init(hex: 0xFAFAFA), dark: .init(hex: 0x1E1E1E))
        static let surface = Color(light: .white, dark: .init(hex: 0x2D2D2D))
        static let surfaceHover = Color(light: .init(hex: 0xF0F0F0), dark: .init(hex: 0x383838))
        static let separator = Color(light: .init(hex: 0xE8E8E8), dark: .init(hex: 0x3A3A3A))
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary
        static let textTertiary = Color(light: .init(hex: 0x999999), dark: .init(hex: 0x666666))
        static let accent = Color.accentColor
        static let codeBlockBackground = Color(light: .init(hex: 0xF5F5F5), dark: .init(hex: 0x252525))
        static let codeInlineBackground = Color(light: .init(hex: 0xEFEFEF), dark: .init(hex: 0x333333))
    }

    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 32
    }

    // MARK: - Radius
    enum Radius {
        static let button: CGFloat = 4
        static let card: CGFloat = 6
        static let panel: CGFloat = 8
    }

    // MARK: - Animation
    enum Animation {
        static let quick = SwiftUI.Animation.spring(response: 0.2, dampingFraction: 0.9)
        static let standard = SwiftUI.Animation.spring(response: 0.25, dampingFraction: 0.9)
        static let smooth = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.9)
    }

    // MARK: - Shadow
    enum Shadow {
        static let subtle = ShadowStyle(color: .black.opacity(0.08), radius: 4, y: 2)
        static let medium = ShadowStyle(color: .black.opacity(0.12), radius: 8, y: 4)
        static let elevated = ShadowStyle(color: .black.opacity(0.16), radius: 16, y: 8)
    }
}

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let y: CGFloat
}

// MARK: - Color Helpers

extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

// MARK: - View Modifiers

extension View {
    func dsShadow(_ style: ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, y: style.y)
    }
}
