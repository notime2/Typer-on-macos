// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import CoreGraphics
import Testing
@testable import Typer_On

@Test
func testAutoDetectCompactPlacementAnchorsToCursorInsteadOfSelectionBounds() {
    let metrics = FloatingToolbarLayoutMetrics()
    let resolver = FloatingToolbarFrameResolver(metrics: metrics)
    let cursorPosition = CGPoint(x: 120, y: 160)
    let placement = resolver.resolve(
        source: .autoDetect,
        mode: .compact,
        selectionBounds: CGRect(x: 600, y: 300, width: 120, height: 40),
        cursorPosition: cursorPosition,
        moduleCount: 4,
        screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
    )

    #expect(placement.contentRect.midX == 106)
    #expect(placement.contentRect.midY == 150)
    #expect(placement.contentRect.midX < 200)
    #expect(placement.contentRect.contains(cursorPosition) == false)
}

@Test
func testProcessingIndicatorUsesDedicatedPillSizeAndSourceAnchor() {
    let metrics = FloatingToolbarLayoutMetrics()
    let resolver = FloatingToolbarFrameResolver(metrics: metrics)
    let placement = resolver.resolveProcessingIndicator(
        source: .autoDetect,
        selectionBounds: CGRect(x: 600, y: 300, width: 120, height: 40),
        cursorPosition: CGPoint(x: 120, y: 160),
        screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
    )

    #expect(placement.contentRect.size == metrics.processingIndicatorSize)
    #expect(placement.contentRect.minX == 120 - 14 - (metrics.compactInteractiveSize / 2))
    #expect(abs(placement.contentRect.midY - (160 - 10)) < 0.01)
}

@Test
func testAutoDetectExpandedPlacementKeepsCompactLeadingAnchor() {
    let metrics = FloatingToolbarLayoutMetrics()
    let resolver = FloatingToolbarFrameResolver(metrics: metrics)
    let compactPlacement = resolver.resolve(
        source: .autoDetect,
        mode: .compact,
        selectionBounds: CGRect(x: 640, y: 320, width: 140, height: 40),
        cursorPosition: CGPoint(x: 200, y: 220),
        moduleCount: 5,
        screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 900)
    )
    let expandedPlacement = resolver.resolve(
        source: .autoDetect,
        mode: .expanded,
        selectionBounds: CGRect(x: 640, y: 320, width: 140, height: 40),
        cursorPosition: CGPoint(x: 200, y: 220),
        moduleCount: 5,
        screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 900)
    )

    #expect(expandedPlacement.contentRect.minX == compactPlacement.contentRect.minX)
    #expect(expandedPlacement.contentRect.midY == compactPlacement.contentRect.midY)
}

@Test
func testExplicitExpandedPlacementStillUsesSelectionBounds() {
    let metrics = FloatingToolbarLayoutMetrics()
    let resolver = FloatingToolbarFrameResolver(metrics: metrics)
    let placement = resolver.resolve(
        source: .explicit,
        mode: .expanded,
        selectionBounds: CGRect(x: 300, y: 420, width: 120, height: 36),
        cursorPosition: CGPoint(x: 80, y: 120),
        moduleCount: 4,
        screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 900)
    )

    let expectedWidth = metrics.expandedWidth(moduleCount: 4)
    #expect(placement.contentRect.width == expectedWidth)
    #expect(placement.contentRect.minY == 372)
    #expect(placement.contentRect.midX == 360)
}

@Test
func testAutoDetectExpandedPlacementClampsToRightEdgeWithoutOverflow() {
    let metrics = FloatingToolbarLayoutMetrics()
    let resolver = FloatingToolbarFrameResolver(metrics: metrics)
    let screenFrame = CGRect(x: 0, y: 0, width: 220, height: 160)
    let placement = resolver.resolve(
        source: .autoDetect,
        mode: .expanded,
        selectionBounds: CGRect(x: 100, y: 60, width: 80, height: 24),
        cursorPosition: CGPoint(x: 210, y: 70),
        moduleCount: 3,
        screenFrame: screenFrame
    )

    #expect(placement.contentRect.maxX <= screenFrame.maxX - metrics.screenMargin)
    #expect(placement.contentRect.minX >= screenFrame.minX + metrics.screenMargin)
}

@Test
func testAutoDetectCompactPlacementMirrorsRightWhenNearLeftEdge() {
    let metrics = FloatingToolbarLayoutMetrics()
    let resolver = FloatingToolbarFrameResolver(metrics: metrics)
    let cursorPosition = CGPoint(x: 8, y: 160)
    let placement = resolver.resolve(
        source: .autoDetect,
        mode: .compact,
        selectionBounds: CGRect(x: 400, y: 200, width: 80, height: 24),
        cursorPosition: cursorPosition,
        moduleCount: 4,
        screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
    )

    #expect(placement.contentRect.midX == 22)
    #expect(placement.contentRect.midX > cursorPosition.x)
}

@Test
func testAutoDetectCompactPlacementMirrorsUpWhenNearBottomEdge() {
    let metrics = FloatingToolbarLayoutMetrics()
    let resolver = FloatingToolbarFrameResolver(metrics: metrics)
    let cursorPosition = CGPoint(x: 120, y: 8)
    let placement = resolver.resolve(
        source: .autoDetect,
        mode: .compact,
        selectionBounds: CGRect(x: 400, y: 200, width: 80, height: 24),
        cursorPosition: cursorPosition,
        moduleCount: 4,
        screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
    )

    #expect(placement.contentRect.midY == 18)
    #expect(placement.contentRect.midY > cursorPosition.y)
}

@Test
func testToolbarScreenIndexPrefersSelectionBoundsScreenOverCursorScreen() {
    let screenFrames = [
        CGRect(x: 0, y: 0, width: 1000, height: 800),
        CGRect(x: 1000, y: 0, width: 1000, height: 800),
    ]

    let index = NSScreen.toolbarScreenIndex(
        selectionBounds: CGRect(x: 1200, y: 200, width: 120, height: 40),
        cursorPosition: CGPoint(x: 100, y: 100),
        screenFrames: screenFrames
    )

    #expect(index == 1)
}

@Test
func testCompactTriggerScreenIndexPrefersSelectionBoundsScreenOverCursorScreen() {
    let screenFrames = [
        CGRect(x: 0, y: 0, width: 1000, height: 800),
        CGRect(x: 1000, y: 0, width: 1000, height: 800),
    ]

    let index = NSScreen.toolbarScreenIndex(
        selectionBounds: CGRect(x: 1250, y: 240, width: 60, height: 24),
        cursorPosition: CGPoint(x: 80, y: 120),
        screenFrames: screenFrames
    )

    #expect(index == 1)
}

@Test
func testExpandedToolbarScreenIndexPrefersSelectionBoundsScreenOverCursorScreen() {
    let screenFrames = [
        CGRect(x: 0, y: 0, width: 1000, height: 800),
        CGRect(x: 1000, y: 0, width: 1000, height: 800),
    ]

    let index = NSScreen.toolbarScreenIndex(
        selectionBounds: CGRect(x: 1300, y: 260, width: 140, height: 32),
        cursorPosition: CGPoint(x: 90, y: 140),
        screenFrames: screenFrames
    )

    #expect(index == 1)
}

@Test
func testBestMatchingScreenIndexUsesCenterHitFirst() {
    let screenFrames = [
        CGRect(x: 0, y: 0, width: 500, height: 800),
        CGRect(x: 600, y: 0, width: 500, height: 800),
    ]

    let index = NSScreen.bestMatchingScreenIndex(
        for: CGRect(x: 450, y: 100, width: 300, height: 40),
        screenFrames: screenFrames
    )

    #expect(index == 1)
}

@Test
func testBestMatchingScreenIndexFallsBackToLargestIntersection() {
    let screenFrames = [
        CGRect(x: 0, y: 0, width: 500, height: 800),
        CGRect(x: 600, y: 0, width: 500, height: 800),
    ]

    let index = NSScreen.bestMatchingScreenIndex(
        for: CGRect(x: 480, y: 100, width: 200, height: 40),
        screenFrames: screenFrames
    )

    #expect(index == 1)
}

@Test
func testBestMatchingScreenIndexReturnsNilWhenNoIntersection() {
    let screenFrames = [
        CGRect(x: 0, y: 0, width: 500, height: 800),
        CGRect(x: 600, y: 0, width: 500, height: 800),
    ]

    let index = NSScreen.bestMatchingScreenIndex(
        for: CGRect(x: 1300, y: 100, width: 100, height: 40),
        screenFrames: screenFrames
    )

    #expect(index == nil)
}

private struct ToolbarScreenGeometryCase: Sendable {
    let name: String
    let screenFrames: [CGRect]
    let axBounds: CGRect
    let expectedBounds: CGRect
    let expectedScreenIndex: Int
    var mode: AccessibilityManager.SelectionBoundsCoordinateMode = .topLeftNeedsConversion
}

private let toolbarScreenGeometryCases: [ToolbarScreenGeometryCase] = [
    ToolbarScreenGeometryCase(
        name: "Built-in primary, selection below external",
        screenFrames: [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 0, y: 900, width: 2560, height: 1440),
        ],
        axBounds: CGRect(x: 100, y: 150, width: 200, height: 30),
        expectedBounds: CGRect(x: 100, y: 720, width: 200, height: 30),
        expectedScreenIndex: 0
    ),
    ToolbarScreenGeometryCase(
        name: "Built-in primary, selection on upper external",
        screenFrames: [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 0, y: 900, width: 2560, height: 1440),
        ],
        axBounds: CGRect(x: 100, y: -750, width: 200, height: 30),
        expectedBounds: CGRect(x: 100, y: 1620, width: 200, height: 30),
        expectedScreenIndex: 1
    ),
    ToolbarScreenGeometryCase(
        name: "External primary, selection on lower built-in",
        screenFrames: [
            CGRect(x: 0, y: 0, width: 2560, height: 1440),
            CGRect(x: 400, y: -900, width: 1440, height: 900),
        ],
        axBounds: CGRect(x: 500, y: 1590, width: 200, height: 30),
        expectedBounds: CGRect(x: 500, y: -180, width: 200, height: 30),
        expectedScreenIndex: 1
    ),
    ToolbarScreenGeometryCase(
        name: "External left and vertically offset",
        screenFrames: [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: -1600, y: 150, width: 1600, height: 1000),
        ],
        axBounds: CGRect(x: -1000, y: 200, width: 200, height: 30),
        expectedBounds: CGRect(x: -1000, y: 670, width: 200, height: 30),
        expectedScreenIndex: 1
    ),
    ToolbarScreenGeometryCase(
        name: "External right and vertically offset",
        screenFrames: [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: -250, width: 1920, height: 1080),
        ],
        axBounds: CGRect(x: 1600, y: 400, width: 200, height: 30),
        expectedBounds: CGRect(x: 1600, y: 470, width: 200, height: 30),
        expectedScreenIndex: 1
    ),
    ToolbarScreenGeometryCase(
        name: "External below and horizontally offset",
        screenFrames: [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: -400, y: -1080, width: 1920, height: 1080),
        ],
        axBounds: CGRect(x: 100, y: 1300, width: 200, height: 30),
        expectedBounds: CGRect(x: 100, y: -430, width: 200, height: 30),
        expectedScreenIndex: 1
    ),
    ToolbarScreenGeometryCase(
        name: "Single screen",
        screenFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)],
        axBounds: CGRect(x: 100, y: 150, width: 200, height: 30),
        expectedBounds: CGRect(x: 100, y: 720, width: 200, height: 30),
        expectedScreenIndex: 0
    ),
    ToolbarScreenGeometryCase(
        name: "Already-AppKit bounds below upper external",
        screenFrames: [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 0, y: 900, width: 2560, height: 1440),
        ],
        axBounds: CGRect(x: 100, y: 720, width: 200, height: 30),
        expectedBounds: CGRect(x: 100, y: 720, width: 200, height: 30),
        expectedScreenIndex: 0,
        mode: .alreadyAppKit
    ),
]

/// The conversion, screen helper and placement resolver below are the same route used by
/// FloatingToolbarViewModel for compact/expanded, every morph tick and processing status.
@Test(arguments: toolbarScreenGeometryCases)
private func testAXSelectionBoundsKeepEveryToolbarStageOnSelectedScreen(
    scenario: ToolbarScreenGeometryCase
) throws {
    let bounds = try #require(AccessibilityManager.resolveSelectionBounds(
        axRect: scenario.axBounds,
        screenFrames: scenario.screenFrames,
        primaryScreenFrame: scenario.screenFrames.first,
        mode: scenario.mode
    ))
    #expect(bounds == scenario.expectedBounds, "\(scenario.name)")

    let cursorPosition = CGPoint(x: bounds.midX, y: bounds.midY)
    let screenIndex = try #require(NSScreen.toolbarScreenIndex(
        selectionBounds: bounds,
        cursorPosition: cursorPosition,
        screenFrames: scenario.screenFrames
    ))
    #expect(screenIndex == scenario.expectedScreenIndex, "\(scenario.name)")

    // A distinct visible frame also checks that placement respects usable screen space.
    let visibleFrame = scenario.screenFrames[screenIndex].insetBy(dx: 20, dy: 30)
    let placements = toolbarStagePlacements(
        selectionBounds: bounds,
        cursorPosition: cursorPosition,
        visibleFrame: visibleFrame
    )
    for placement in placements {
        #expect(visibleFrame.contains(placement.contentRect), "\(scenario.name)")
        #expect(placement.screenFrame == visibleFrame)
        #expect(placement.contentRect.minX == placements[0].contentRect.minX)
        #expect(placement.contentRect.midY == placements[0].contentRect.midY)
    }
    #expect(!placements[0].contentRect.contains(cursorPosition))
    #expect(placements[0].contentRect.midX == cursorPosition.x - 14)
    #expect(placements[0].contentRect.midY == cursorPosition.y - 10)

    let explicit = FloatingToolbarFrameResolver(metrics: FloatingToolbarLayoutMetrics()).resolve(
        source: .explicit,
        mode: .expanded,
        selectionBounds: bounds,
        cursorPosition: cursorPosition,
        moduleCount: 4,
        screenFrame: visibleFrame
    )
    #expect(visibleFrame.contains(explicit.contentRect))
    #expect(explicit.contentRect.midX == bounds.midX)
    #expect(explicit.contentRect.maxY == bounds.minY - 4)
}

@Test(arguments: [false, true])
func testToolbarStagesUseCapturedCursorScreenWhenBoundsAreUnavailable(invalidBounds: Bool) throws {
    let screenFrames = [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 0, y: 900, width: 2560, height: 1440),
    ]
    let selection = TextSelection(
        text: "Synthetic selection",
        cursorPosition: CGPoint(x: 250, y: 450),
        selectionBounds: invalidBounds ? CGRect(x: 5000, y: 5000, width: 100, height: 30) : nil
    )
    let movedCursorPosition = CGPoint(x: 250, y: 1500)
    #expect(NSScreen.screenIndexContaining(point: movedCursorPosition, screenFrames: screenFrames) == 1)

    let index = try #require(NSScreen.toolbarScreenIndex(
        selectionBounds: selection.selectionBounds,
        cursorPosition: selection.cursorPosition,
        screenFrames: screenFrames
    ))
    #expect(index == 0)
    let placements = toolbarStagePlacements(
        selectionBounds: selection.selectionBounds,
        cursorPosition: selection.cursorPosition,
        visibleFrame: screenFrames[index]
    )
    for placement in placements {
        #expect(screenFrames[0].contains(placement.contentRect))
        #expect(!screenFrames[1].intersects(placement.contentRect))
        #expect(placement.contentRect.minX == placements[0].contentRect.minX)
        #expect(placement.contentRect.midY == selection.cursorPosition.y - 10)
    }
}

@Test
func testToolbarStagesClampToBoundsScreenWhenCapturedCursorIsOnAnotherScreen() throws {
    let screenFrames = [
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 0, y: 900, width: 2560, height: 1440),
    ]
    let bounds = try #require(AccessibilityManager.resolveSelectionBounds(
        axRect: CGRect(x: 100, y: 150, width: 200, height: 30),
        screenFrames: screenFrames,
        primaryScreenFrame: screenFrames.first,
        mode: .topLeftNeedsConversion
    ))
    let cursorPosition = CGPoint(x: 250, y: 1500)
    let index = try #require(NSScreen.toolbarScreenIndex(
        selectionBounds: bounds,
        cursorPosition: cursorPosition,
        screenFrames: screenFrames
    ))
    #expect(index == 0)
    for placement in toolbarStagePlacements(
        selectionBounds: bounds,
        cursorPosition: cursorPosition,
        visibleFrame: screenFrames[index]
    ) {
        #expect(screenFrames[0].contains(placement.contentRect))
        #expect(placement.contentRect.maxY <= screenFrames[0].maxY - 4)
    }
}

@Test
func testToolbarScreenIndexRequestsRecoveryWhenCapturedInputsMissCurrentScreens() {
    #expect(NSScreen.toolbarScreenIndex(
        selectionBounds: CGRect(x: 100, y: 1500, width: 200, height: 30),
        cursorPosition: CGPoint(x: 250, y: 1500),
        screenFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)]
    ) == nil)
    #expect(NSScreen.toolbarScreenIndex(
        selectionBounds: nil,
        cursorPosition: CGPoint(x: 250, y: 450),
        screenFrames: []
    ) == nil)
}

private func toolbarStagePlacements(
    selectionBounds: CGRect?,
    cursorPosition: CGPoint,
    visibleFrame: CGRect
) -> [FloatingToolbarPlacement] {
    let metrics = FloatingToolbarLayoutMetrics()
    let resolver = FloatingToolbarFrameResolver(metrics: metrics)
    let modes: [FloatingToolbarPresentationMode] = [.compact, .expanded]
    let settledPlacements = modes.map { mode in
        resolver.resolve(
            source: .autoDetect,
            mode: mode,
            selectionBounds: selectionBounds,
            cursorPosition: cursorPosition,
            moduleCount: 4,
            screenFrame: visibleFrame
        )
    }
    let morphPlacement = resolver.resolve(
        source: .autoDetect,
        size: CGSize(width: 120, height: 37),
        selectionBounds: selectionBounds,
        cursorPosition: cursorPosition,
        screenFrame: visibleFrame
    )
    let processingPlacement = resolver.resolveProcessingIndicator(
        source: .autoDetect,
        selectionBounds: selectionBounds,
        cursorPosition: cursorPosition,
        screenFrame: visibleFrame
    )
    return settledPlacements + [morphPlacement, processingPlacement]
}
