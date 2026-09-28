// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI

struct FloatingToolbarPlacement: Equatable {
    let contentRect: NSRect
    let screenFrame: NSRect
}

struct FloatingToolbarFrameResolver {
    let metrics: FloatingToolbarLayoutMetrics

    func resolve(
        source: FloatingToolbarPresentationSource,
        mode: FloatingToolbarPresentationMode,
        selectionBounds: CGRect?,
        cursorPosition: CGPoint,
        moduleCount: Int,
        screenFrame: CGRect
    ) -> FloatingToolbarPlacement {
        resolve(
            source: source,
            size: metrics.targetSize(for: mode, moduleCount: moduleCount),
            selectionBounds: selectionBounds,
            cursorPosition: cursorPosition,
            screenFrame: screenFrame
        )
    }

    /// Placement for an arbitrary size.
    ///
    /// The continuous morph resolves a placement from its interpolated size on every tick, so
    /// screen-edge clamping and mirroring keep applying while the panel is still growing.
    func resolve(
        source: FloatingToolbarPresentationSource,
        size: CGSize,
        selectionBounds: CGRect?,
        cursorPosition: CGPoint,
        screenFrame: CGRect
    ) -> FloatingToolbarPlacement {
        let contentRect = switch source {
        case .autoDetect:
            autoDetectContentRect(
                size: size,
                cursorPosition: cursorPosition,
                screenFrame: screenFrame
            )
        case .explicit:
            explicitContentRect(
                size: size,
                selectionBounds: selectionBounds,
                cursorPosition: cursorPosition,
                screenFrame: screenFrame
            )
        }

        return FloatingToolbarPlacement(
            contentRect: contentRect,
            screenFrame: screenFrame
        )
    }

    func resolveProcessingIndicator(
        source: FloatingToolbarPresentationSource,
        selectionBounds: CGRect?,
        cursorPosition: CGPoint,
        screenFrame: CGRect
    ) -> FloatingToolbarPlacement {
        resolve(
            source: source,
            size: metrics.processingIndicatorSize,
            selectionBounds: selectionBounds,
            cursorPosition: cursorPosition,
            screenFrame: screenFrame
        )
    }

    private func autoDetectContentRect(
        size: CGSize,
        cursorPosition: CGPoint,
        screenFrame: CGRect
    ) -> CGRect {
        let compactRect = compactAutoDetectContentRect(
            cursorPosition: cursorPosition,
            screenFrame: screenFrame
        )

        let rect = CGRect(
            x: compactRect.minX,
            y: compactRect.midY - (size.height / 2),
            width: size.width,
            height: size.height
        )

        return clamped(rect, inside: screenFrame)
    }

    private func compactAutoDetectContentRect(
        cursorPosition: CGPoint,
        screenFrame: CGRect
    ) -> CGRect {
        let size = CGSize(
            width: metrics.compactInteractiveSize,
            height: metrics.compactInteractiveSize
        )

        var center = CGPoint(
            x: cursorPosition.x + metrics.cursorAnchorOffset.x,
            y: cursorPosition.y + metrics.cursorAnchorOffset.y
        )

        let defaultRect = centeredRect(at: center, size: size)
        let mirroredHorizontalRect = centeredRect(
            at: CGPoint(
                x: cursorPosition.x - metrics.cursorAnchorOffset.x,
                y: center.y
            ),
            size: size
        )
        if horizontalOverflow(of: mirroredHorizontalRect, inside: screenFrame) <
            horizontalOverflow(of: defaultRect, inside: screenFrame) {
            center.x = cursorPosition.x - metrics.cursorAnchorOffset.x
        }

        let currentRect = centeredRect(at: center, size: size)
        let mirroredVerticalRect = centeredRect(
            at: CGPoint(
                x: center.x,
                y: cursorPosition.y - metrics.cursorAnchorOffset.y
            ),
            size: size
        )
        if verticalOverflow(of: mirroredVerticalRect, inside: screenFrame) <
            verticalOverflow(of: currentRect, inside: screenFrame) {
            center.y = cursorPosition.y - metrics.cursorAnchorOffset.y
        }

        return clamped(
            centeredRect(at: center, size: size),
            inside: screenFrame
        )
    }

    private func explicitContentRect(
        size: CGSize,
        selectionBounds: CGRect?,
        cursorPosition: CGPoint,
        screenFrame: CGRect
    ) -> CGRect {
        let margin = metrics.screenMargin

        if let selectionBounds {
            var origin = CGPoint(
                x: selectionBounds.midX - (size.width / 2),
                y: selectionBounds.minY - size.height - metrics.selectionGap
            )

            origin.x = max(
                screenFrame.minX + margin,
                min(origin.x, screenFrame.maxX - size.width - margin)
            )

            if origin.y < screenFrame.minY + margin {
                origin.y = selectionBounds.maxY + metrics.selectionGap
            }

            origin.y = max(
                screenFrame.minY + margin,
                min(origin.y, screenFrame.maxY - size.height - margin)
            )

            return CGRect(origin: origin, size: size)
        }

        var origin = CGPoint(
            x: cursorPosition.x - (size.width / 2),
            y: cursorPosition.y - size.height - metrics.cursorFallbackGap
        )

        origin.x = max(
            screenFrame.minX + margin,
            min(origin.x, screenFrame.maxX - size.width - margin)
        )
        origin.y = max(
            screenFrame.minY + margin,
            min(origin.y, screenFrame.maxY - size.height - margin)
        )

        if origin.y < screenFrame.minY + margin {
            origin.y = cursorPosition.y + metrics.cursorFallbackGap
        }

        return CGRect(origin: origin, size: size)
    }

    private func centeredRect(at center: CGPoint, size: CGSize) -> CGRect {
        CGRect(
            x: center.x - (size.width / 2),
            y: center.y - (size.height / 2),
            width: size.width,
            height: size.height
        )
    }

    private func clamped(_ rect: CGRect, inside screenFrame: CGRect) -> CGRect {
        let origin = CGPoint(
            x: max(
                screenFrame.minX + metrics.screenMargin,
                min(rect.minX, screenFrame.maxX - rect.width - metrics.screenMargin)
            ),
            y: max(
                screenFrame.minY + metrics.screenMargin,
                min(rect.minY, screenFrame.maxY - rect.height - metrics.screenMargin)
            )
        )

        return CGRect(origin: origin, size: rect.size)
    }

    private func horizontalOverflow(of rect: CGRect, inside screenFrame: CGRect) -> CGFloat {
        max(0, (screenFrame.minX + metrics.screenMargin) - rect.minX) +
        max(0, rect.maxX - (screenFrame.maxX - metrics.screenMargin))
    }

    private func verticalOverflow(of rect: CGRect, inside screenFrame: CGRect) -> CGFloat {
        max(0, (screenFrame.minY + metrics.screenMargin) - rect.minY) +
        max(0, rect.maxY - (screenFrame.maxY - metrics.screenMargin))
    }
}

@MainActor
protocol FloatingToolbarAlphaAnimator {
    func animate(
        panel: NSPanel,
        to alpha: CGFloat,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction,
        completion: @escaping @MainActor () -> Void
    )
}

@MainActor
struct NativeFloatingToolbarAlphaAnimator: FloatingToolbarAlphaAnimator {
    func animate(
        panel: NSPanel,
        to alpha: CGFloat,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction,
        completion: @escaping @MainActor () -> Void
    ) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = timingFunction
            panel.animator().alphaValue = alpha
        }, completionHandler: {
            DispatchQueue.main.async { completion() }
        })
    }
}

final class FloatingToolbarPanel: NSPanel {
    private static let showAnimationDuration: TimeInterval = 0.11
    private static let hideAnimationDuration: TimeInterval = 0.09
    private var animationGeneration = 0
    private var isDismissing = false
    private let alphaAnimator: any FloatingToolbarAlphaAnimator

    var onEscape: (() -> Void)?
    var onKeyEvent: ((_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool)?

    // This button-only panel must preserve the source field's keyboard focus.
    // Toolbar shortcuts are handled by the view model's event monitors.
    override var canBecomeKey: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if onKeyEvent?(event.keyCode, event.modifierFlags) == true {
            return
        }
        super.keyDown(with: event)
    }

    init(alphaAnimator: any FloatingToolbarAlphaAnimator = NativeFloatingToolbarAlphaAnimator()) {
        self.alphaAnimator = alphaAnimator
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    func show(contentRect: NSRect) {
        let needsFade = !isVisible || isDismissing
        animationGeneration += 1
        isDismissing = false
        setFrame(frameRect(forContentRect: contentRect), display: true)
        if !isVisible {
            alphaValue = 0
        }
        orderFrontRegardless()

        guard needsFade else { return }
        alphaAnimator.animate(
            panel: self,
            to: 1,
            duration: Self.showAnimationDuration,
            timingFunction: FloatingToolbarAnimationCurves.openSecondary,
            completion: {}
        )
    }

    func dismiss() {
        animationGeneration += 1
        let generation = animationGeneration
        isDismissing = true
        alphaAnimator.animate(
            panel: self,
            to: 0,
            duration: Self.hideAnimationDuration,
            timingFunction: FloatingToolbarAnimationCurves.closePrimary
        ) { [weak self] in
            guard let self,
                  self.animationGeneration == generation,
                  self.isDismissing else {
                return
            }
            self.isDismissing = false
            self.orderOut(nil)
        }
    }

    func update(contentRect: NSRect) {
        setFrame(frameRect(forContentRect: contentRect), display: true)
    }

    /// Applies one tick of a driven morph without any implicit animation.
    ///
    /// `display: true` keeps the hosted content laid out at exactly the size the window has on
    /// this tick. Deferring the draw would let the frame run a frame ahead of the content, which
    /// is what used to leave the capsule's rounded right cap clipped during the expansion.
    func setContentFrameImmediately(_ contentRect: NSRect) {
        setFrame(frameRect(forContentRect: contentRect), display: true)
    }

    /// Recomputes the drop shadow once the panel has come to rest after a morph.
    func settleShadow() {
        invalidateShadow()
    }
}
