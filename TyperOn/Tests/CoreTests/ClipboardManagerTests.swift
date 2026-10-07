// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Testing
@testable import Typer_On

@Test
@MainActor
func testClipboardManagerRestoresStringContent() {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)

    pasteboard.clearContents()
    pasteboard.setString("Original text", forType: .string)

    manager.backup()
    manager.write("New text")
    manager.restore()

    #expect(pasteboard.string(forType: .string) == "Original text")
}

@Test
@MainActor
func testClipboardManagerRestoresEmptyClipboardState() {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)

    pasteboard.clearContents()

    manager.backup()
    manager.write("Temporary text")
    manager.restore()

    #expect((pasteboard.pasteboardItems ?? []).isEmpty)
    #expect(pasteboard.string(forType: .string) == nil)
}

@Test
@MainActor
func testClipboardManagerRestoresNonTextPasteboardItem() {
    let pasteboard = NSPasteboard.withUniqueName()
    let manager = ClipboardManager(pasteboard: pasteboard)

    let item = NSPasteboardItem()
    let customType = NSPasteboard.PasteboardType("public.file-url")
    let originalData = Data("file:///tmp/example.txt".utf8)
    item.setData(originalData, forType: customType)
    pasteboard.clearContents()
    pasteboard.writeObjects([item])

    manager.backup()
    manager.write("Temporary text")
    manager.restore()

    let restoredData = pasteboard.pasteboardItems?.first?.data(forType: customType)
    #expect(restoredData == originalData)
}
