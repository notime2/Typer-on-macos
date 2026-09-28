// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit

extension NSScreen {
    static var screenContainingCursor: NSScreen? {
        let cursorLocation = NSEvent.mouseLocation
        return screenContaining(point: cursorLocation)
    }

    static var cursorPosition: NSPoint {
        NSEvent.mouseLocation
    }

    static func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.contains(point)
        }
    }

    static func screenBestMatching(selectionBounds: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        let screenFrames = screens.map(\.frame)
        guard let screenIndex = bestMatchingScreenIndex(
            for: selectionBounds,
            screenFrames: screenFrames
        ), screens.indices.contains(screenIndex) else {
            return nil
        }
        return screens[screenIndex]
    }

    static func toolbarScreenIndex(
        selectionBounds: CGRect?,
        cursorPosition: CGPoint,
        screenFrames: [CGRect]
    ) -> Int? {
        if let selectionBounds,
           let selectionIndex = bestMatchingScreenIndex(
               for: selectionBounds,
               screenFrames: screenFrames
           ) {
            return selectionIndex
        }

        return screenIndexContaining(point: cursorPosition, screenFrames: screenFrames)
    }

    static func bestMatchingScreenIndex(for selectionBounds: CGRect, screenFrames: [CGRect]) -> Int? {
        if let centerScreenIndex = screenIndexContaining(
            point: CGPoint(x: selectionBounds.midX, y: selectionBounds.midY),
            screenFrames: screenFrames
        ) {
            return centerScreenIndex
        }

        var bestScreenIndex: Int?
        var bestIntersectionArea: CGFloat = 0

        for (index, screenFrame) in screenFrames.enumerated() {
            let area = intersectionArea(of: screenFrame, with: selectionBounds)
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestScreenIndex = index
            }
        }

        guard bestIntersectionArea > 0 else {
            return nil
        }

        return bestScreenIndex
    }

    static func screenIndexContaining(point: CGPoint, screenFrames: [CGRect]) -> Int? {
        for (index, screenFrame) in screenFrames.enumerated() where screenFrame.contains(point) {
            return index
        }
        return nil
    }

    private static func intersectionArea(of first: CGRect, with second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else {
            return 0
        }
        return intersection.width * intersection.height
    }
}
