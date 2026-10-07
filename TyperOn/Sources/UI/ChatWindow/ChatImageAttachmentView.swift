// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import CoreGraphics
import ImageIO
import SwiftUI

struct ChatImageAttachmentView: View {
    @Environment(\.dialogTheme) private var theme
    let attachment: ChatImageAttachment
    var maxHeight: CGFloat = 240
    var accessibilityLabel = "Image attachment"
    @State private var renderedImage: CGImage?
    @State private var didFinishLoading = false

    var body: some View {
        Group {
            if let renderedImage {
                Image(renderedImage, scale: 1, orientation: .up, label: Text(accessibilityLabel))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if didFinishLoading {
                invalidImagePlaceholder
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .accessibilityLabel("Loading image")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .background(theme.surfaceHover, in: RoundedRectangle(cornerRadius: theme.cardRadius))
        .clipShape(RoundedRectangle(cornerRadius: theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cardRadius)
                .stroke(theme.border, lineWidth: theme.borderWidth)
        )
        .task(id: attachment.id) {
            renderedImage = nil
            didFinishLoading = false
            let image = await Self.decodeImage(attachment.data)
            guard !Task.isCancelled else { return }
            renderedImage = image
            didFinishLoading = true
        }
    }

    private var invalidImagePlaceholder: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "photo.badge.exclamationmark")
            Text("Image unavailable")
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.textSecondary)
        .frame(maxWidth: .infinity, minHeight: 72)
        .accessibilityElement(children: .combine)
    }

    nonisolated static func decodeImage(_ data: Data) async -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_048,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        return Task.isCancelled ? nil : image
    }
}

struct ChatInvalidImageView: View {
    @Environment(\.dialogTheme) private var theme
    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "photo.badge.exclamationmark")
            Text("One image could not be displayed")
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.textSecondary)
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceHover, in: RoundedRectangle(cornerRadius: theme.buttonRadius))
        .accessibilityElement(children: .combine)
    }
}
