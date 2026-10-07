// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Testing
@testable import Typer_On

@Test
@MainActor
func testStreamingCursorLayerStartsOnceAndStopsOnDetachAndDismantle() throws {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    window.contentView = container
    let cursor = StreamingCursorLayer.CursorView(frame: NSRect(x: 0, y: 0, width: 2, height: 16))
    cursor.color = .red
    #expect(cursor.layer?.animationKeys()?.isEmpty != false)
    container.addSubview(cursor)
    let layer = try #require(cursor.layer)
    let animation = try #require(layer.animation(forKey: StreamingCursorLayer.CursorView.animationKey) as? CABasicAnimation)
    #expect(animation.keyPath == "opacity")
    #expect(animation.autoreverses)
    #expect(animation.duration == 0.5)
    cursor.viewDidMoveToWindow()
    #expect(layer.animationKeys()?.count == 1)

    cursor.removeFromSuperview()
    #expect(layer.animationKeys()?.isEmpty != false)
    container.addSubview(cursor)
    #expect(layer.animationKeys()?.count == 1)
    StreamingCursorLayer.dismantleNSView(cursor, coordinator: ())
    #expect(layer.animationKeys()?.isEmpty != false)
}

@Test
@MainActor
func testStreamingCursorThemeUpdatesPreserveGeometryAndResolveAppearance() throws {
    let cursor = StreamingCursorLayer.CursorView(frame: NSRect(x: 0, y: 0, width: 2, height: 16))
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
        cursor.appearance = try #require(NSAppearance(named: appearanceName))
        for style in SelectionTriggerStyle.allCases {
            let color = NSColor(DialogTheme(style: style).accent)
            cursor.color = color
            cursor.effectiveAppearance.performAsCurrentDrawingAppearance {
                #expect(cursor.layer?.backgroundColor == color.cgColor)
            }
            #expect(cursor.frame.size == NSSize(width: 2, height: 16))
        }
    }
}
