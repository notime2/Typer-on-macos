// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import CoreGraphics
import Testing
@testable import Typer_On

private struct AXBoundsLayoutCase: Sendable, CustomTestStringConvertible {
    let name: String
    let primary: CGRect
    let additionalScreens: [CGRect]
    let axRect: CGRect
    let expected: CGRect

    var testDescription: String { name }

    static let cases: [Self] = [
        .init(name: "single display", primary: CGRect(x: 0, y: 0, width: 1920, height: 1200),
              additionalScreens: [], axRect: CGRect(x: 120, y: 100, width: 80, height: 30),
              expected: CGRect(x: 120, y: 1070, width: 80, height: 30)),
        .init(name: "built-in primary, external above, built-in selection",
              primary: CGRect(x: 0, y: 0, width: 1440, height: 900),
              additionalScreens: [CGRect(x: 0, y: 900, width: 2560, height: 1440)],
              axRect: CGRect(x: 100, y: 150, width: 200, height: 30),
              expected: CGRect(x: 100, y: 720, width: 200, height: 30)),
        .init(name: "built-in primary, external above, external selection",
              primary: CGRect(x: 0, y: 0, width: 1440, height: 900),
              additionalScreens: [CGRect(x: 0, y: 900, width: 2560, height: 1440)],
              axRect: CGRect(x: 100, y: -1130, width: 200, height: 30),
              expected: CGRect(x: 100, y: 2000, width: 200, height: 30)),
        .init(name: "external primary, built-in below with negative Y",
              primary: CGRect(x: 0, y: 0, width: 2560, height: 1440),
              additionalScreens: [CGRect(x: 300, y: -900, width: 1440, height: 900)],
              axRect: CGRect(x: 400, y: 1590, width: 200, height: 30),
              expected: CGRect(x: 400, y: -180, width: 200, height: 30)),
        .init(name: "external below and horizontally offset",
              primary: CGRect(x: 0, y: 0, width: 1440, height: 900),
              additionalScreens: [CGRect(x: -320, y: -1440, width: 2560, height: 1440)],
              axRect: CGRect(x: -100, y: 1100, width: 80, height: 30),
              expected: CGRect(x: -100, y: -230, width: 80, height: 30)),
        .init(name: "external left with negative X and vertical offset",
              primary: CGRect(x: 0, y: 0, width: 1440, height: 900),
              additionalScreens: [CGRect(x: -1920, y: -200, width: 1920, height: 1080)],
              axRect: CGRect(x: -1700, y: 150, width: 80, height: 30),
              expected: CGRect(x: -1700, y: 720, width: 80, height: 30)),
        .init(name: "external right and vertically higher",
              primary: CGRect(x: 0, y: 0, width: 1440, height: 900),
              additionalScreens: [CGRect(x: 1440, y: 200, width: 1920, height: 1080)],
              axRect: CGRect(x: 1600, y: -230, width: 80, height: 30),
              expected: CGRect(x: 1600, y: 1100, width: 80, height: 30)),
        .init(name: "mixed three-display layout, primary selection",
              primary: CGRect(x: 0, y: 0, width: 1440, height: 900),
              additionalScreens: [CGRect(x: -1920, y: 300, width: 1920, height: 1080),
                                  CGRect(x: -400, y: 1380, width: 2560, height: 1440)],
              axRect: CGRect(x: 100, y: 150, width: 200, height: 30),
              expected: CGRect(x: 100, y: 720, width: 200, height: 30)),
        .init(name: "mixed three-display layout, upper selection at negative X",
              primary: CGRect(x: 0, y: 0, width: 1440, height: 900),
              additionalScreens: [CGRect(x: -1920, y: 300, width: 1920, height: 1080),
                                  CGRect(x: -400, y: 1380, width: 2560, height: 1440)],
              axRect: CGRect(x: -300, y: -1130, width: 200, height: 30),
              expected: CGRect(x: -300, y: 2000, width: 200, height: 30)),
    ]
}

@Test(arguments: AXBoundsLayoutCase.cases, [false, true])
@MainActor
private func testAXBoundsResolverUsesExplicitPrimaryAcrossLayouts(
    _ scenario: AXBoundsLayoutCase,
    reverseScreenOrder: Bool
) {
    let originalFrames = [scenario.primary] + scenario.additionalScreens
    let screenFrames = reverseScreenOrder ? Array(originalFrames.reversed()) : originalFrames

    let converted = AccessibilityManager.resolveSelectionBounds(
        axRect: scenario.axRect,
        screenFrames: screenFrames,
        primaryScreenFrame: scenario.primary,
        mode: .topLeftNeedsConversion
    )
    #expect(converted == scenario.expected)

    let alreadyAppKit = AccessibilityManager.resolveSelectionBounds(
        axRect: scenario.expected,
        screenFrames: screenFrames,
        primaryScreenFrame: scenario.primary,
        mode: .alreadyAppKit
    )
    #expect(alreadyAppKit == scenario.expected)
}

@Test
@MainActor
func testAXBoundsResolverUsesPrimaryHeightWithDetachedUpperDisplay() {
    let screenFrames = [
        CGRect(x: 0, y: 0, width: 600, height: 400),
        CGRect(x: 1500, y: 1500, width: 500, height: 500),
    ]
    let resolved = AccessibilityManager.resolveSelectionBounds(
        axRect: CGRect(x: 100, y: 100, width: 40, height: 20),
        screenFrames: screenFrames,
        primaryScreenFrame: screenFrames[0],
        mode: .topLeftNeedsConversion
    )
    #expect(resolved == CGRect(x: 100, y: 280, width: 40, height: 20))
}

@Test(arguments: [AccessibilityManager.SelectionBoundsCoordinateMode.topLeftNeedsConversion, .alreadyAppKit])
@MainActor
func testAXBoundsResolverFallsBackWhenPreferredCandidateMissesEveryScreen(
    mode: AccessibilityManager.SelectionBoundsCoordinateMode
) {
    let screenFrames = [
        CGRect(x: 0, y: 0, width: 600, height: 400),
        CGRect(x: 600, y: 500, width: 500, height: 500),
    ]
    let rawRect = mode == .topLeftNeedsConversion
        ? CGRect(x: 700, y: 700, width: 40, height: 20)
        : CGRect(x: 700, y: -320, width: 40, height: 20)

    let resolved = AccessibilityManager.resolveSelectionBounds(
        axRect: rawRect,
        screenFrames: screenFrames,
        primaryScreenFrame: screenFrames[0],
        mode: mode
    )
    #expect(resolved == CGRect(x: 700, y: 700, width: 40, height: 20))
}

@Test(arguments: [AccessibilityManager.SelectionBoundsCoordinateMode.topLeftNeedsConversion, .alreadyAppKit])
@MainActor
func testAXBoundsResolverReturnsNilForMissingOrUnusableTopology(mode: AccessibilityManager.SelectionBoundsCoordinateMode) {
    let primary = CGRect(x: 0, y: 0, width: 500, height: 500)
    let axRect = CGRect(x: 100, y: 100, width: 50, height: 20)
    let invalidTopologies: [(frames: [CGRect], primary: CGRect?)] = [
        ([primary], nil),
        ([], primary),
        ([primary], CGRect(x: 0, y: 0, width: 600, height: 400)),
        ([.zero], .zero),
        ([primary, CGRect(x: CGFloat.infinity, y: 0, width: 500, height: 500)], primary),
        ([CGRect(x: 0, y: 0, width: 500, height: CGFloat.infinity)],
         CGRect(x: 0, y: 0, width: 500, height: CGFloat.infinity)),
    ]
    for topology in invalidTopologies {
        #expect(AccessibilityManager.resolveSelectionBounds(
            axRect: axRect, screenFrames: topology.frames, primaryScreenFrame: topology.primary, mode: mode
        ) == nil)
    }
}

@Test(arguments: [
    CGRect(x: 2000, y: 2000, width: 50, height: 20),
    CGRect(x: 100, y: 100, width: 0, height: 20),
    CGRect(x: 100, y: 100, width: 50, height: -20),
    CGRect(x: CGFloat.nan, y: 100, width: 50, height: 20),
    CGRect(x: 100, y: CGFloat.infinity, width: 50, height: 20),
    CGRect(x: 100, y: 100, width: CGFloat.infinity, height: 20),
])
@MainActor
func testAXBoundsResolverReturnsNilWhenBothCandidatesInvalid(axRect: CGRect) {
    let primary = CGRect(x: 0, y: 0, width: 500, height: 500)
    #expect(AccessibilityManager.resolveSelectionBounds(
        axRect: axRect, screenFrames: [primary], primaryScreenFrame: primary, mode: .topLeftNeedsConversion
    ) == nil)
}

@Test
@MainActor
func testCoordinateModeUsesAppAwareOverrides() {
    #expect(AccessibilityManager.coordinateMode(forBundleIdentifier: nil) == .topLeftNeedsConversion)
    #expect(AccessibilityManager.coordinateMode(forBundleIdentifier: "com.google.Chrome") == .alreadyAppKit)
    #expect(AccessibilityManager.coordinateMode(forBundleIdentifier: "com.microsoft.VSCode") == .alreadyAppKit)
    #expect(AccessibilityManager.coordinateMode(forBundleIdentifier: "com.apple.TextEdit") == .topLeftNeedsConversion)
}
