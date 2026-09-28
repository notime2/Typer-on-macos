// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import CoreGraphics
import Foundation
import Testing
@testable import Typer_On

@Test
func testSettingsSidebarListsEveryTabInDeclaredOrder() {
    let items = SettingsSidebarItem.all

    #expect(items.map(\.tab) == [.general, .api, .modules, .customPrompts, .chatHistory])
}

@Test
func testSettingsSidebarRowsCarryTabTitleAndSymbol() {
    let items = SettingsSidebarItem.all

    #expect(items.map(\.title) == ["General", "API", "Modules", "Custom Modules", "Chat History"])
    #expect(items.map(\.systemImage) == ["gear", "key", "square.stack.3d.up", "text.bubble", "clock.arrow.circlepath"])
}

@Test
func testSettingsSidebarBadgeTintsAreStableAndDistinct() {
    let tints = SettingsSidebarItem.all.map(\.badgeTint)

    #expect(tints == [.gray, .blue, .purple, .orange, .green])
    #expect(Set(tints.map(\.rawValue)).count == tints.count)
}

@Test
func testSettingsSidebarKeepsIdealColumnWidth() {
    #expect(SettingsWindowSizingPolicy.sidebarIdealWidth == 180)
    #expect(SettingsWindowSizingPolicy.sidebarIdealWidth < SettingsWindowSizingPolicy.defaultMinimumContentSize.width)
}

@Test(arguments: [0.0, 12.0, 31.9])
func testSettingsDetailHeaderFallsBackToMinimumTitlebarHeight(inset: CGFloat) {
    #expect(SettingsDetailLayout.headerHeight(titlebarInset: inset) == SettingsDetailLayout.minimumTitlebarHeight)
}

@Test(arguments: [38.0, 52.0])
func testSettingsDetailHeaderMatchesHostTitlebarInset(inset: CGFloat) {
    #expect(SettingsDetailLayout.headerHeight(titlebarInset: inset) == inset)
}
