// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

@MainActor
struct FloatingToolbarView: View {
    let theme: SelectionUITheme
    let modules: [any TextModule]
    /// Drives the left-to-right cascade. Because it comes from the live container width, the
    /// cascade rides the morph's existing width ramp and adds no time to the transition.
    var revealProgress: Double = 1
    let onModuleSelected: (any TextModule) -> Void
    let onDismiss: () -> Void

    var body: some View {
        let itemCount = modules.count + 1

        HStack(spacing: DS.Spacing.xs) {
            ForEach(Array(modules.enumerated()), id: \.offset) { index, module in
                let shortcutLabel = index < 9 ? "⌘\(index + 1)" : nil

                ToolbarIconButton(
                    theme: theme,
                    icon: module.icon,
                    helpText: tooltipText(moduleName: module.name, shortcutLabel: shortcutLabel),
                    action: { onModuleSelected(module) }
                )
                .opacity(revealOpacity(at: index, of: itemCount))
            }

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 2)
                .opacity(revealOpacity(at: modules.count, of: itemCount))

            ToolbarIconButton(
                theme: theme,
                icon: "xmark",
                isDestructive: true,
                helpText: "Dismiss (Esc)",
                action: { onDismiss() }
            )
            .opacity(revealOpacity(at: modules.count, of: itemCount))
        }
    }

    private func revealOpacity(at index: Int, of count: Int) -> Double {
        FloatingToolbarContentReveal.buttonOpacity(
            index: index,
            count: count,
            revealProgress: revealProgress
        )
    }

    private func tooltipText(moduleName: String, shortcutLabel: String?) -> String {
        guard let shortcutLabel else { return moduleName }
        return "\(moduleName) (\(shortcutLabel))"
    }
}

@MainActor
private struct ToolbarIconButton: View {
    let theme: SelectionUITheme
    let icon: String
    var isDestructive: Bool = false
    let helpText: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ModuleIconView(icon: icon, size: 14)
                .frame(width: 32, height: 32)
                .background(
                    isHovered ? theme.toolbarButtonHoverColor : .clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.button)
                )
                .foregroundStyle(isDestructive ? .secondary : theme.toolbarGlyphColor)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
