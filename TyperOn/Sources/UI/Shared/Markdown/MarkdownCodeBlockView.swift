// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI
import AppKit

struct MarkdownCodeBlockView: View {
    @Environment(\.dialogTheme) private var theme
    let language: String?
    let code: String

    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            codeContent
        }
        .background(theme.codeBackground, in: RoundedRectangle(cornerRadius: theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cardRadius)
                .stroke(theme.border, lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack {
            if let language {
                Text(language)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button {
                copyCode()
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                    Text(isCopied ? "Copied" : "Copy")
                        .font(.system(size: 11))
                }
                .foregroundStyle(isCopied ? theme.accent : theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
    }

    private var codeContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        isCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            isCopied = false
        }
    }
}
