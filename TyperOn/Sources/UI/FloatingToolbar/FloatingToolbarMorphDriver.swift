// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import QuartzCore

/// Cubic Bezier easing evaluated on the CPU.
///
/// The staged morph handed `CAMediaTimingFunction` values to CoreAnimation. The continuous morph
/// interpolates sizes itself, so the same shipped control points are evaluated here instead.
struct UnitBezier {
    private let ax: Double
    private let bx: Double
    private let cx: Double
    private let ay: Double
    private let by: Double
    private let cy: Double

    init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        cx = 3 * p1x
        bx = 3 * (p2x - p1x) - cx
        ax = 1 - cx - bx
        cy = 3 * p1y
        by = 3 * (p2y - p1y) - cy
        ay = 1 - cy - by
    }

    func value(for x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return sampleY(solve(for: x))
    }

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }

    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }

    private func sampleDerivativeX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    private func solve(for x: Double) -> Double {
        var t = x

        // Newton-Raphson converges in a couple of iterations for well-formed easing curves.
        for _ in 0..<8 {
            let error = sampleX(t) - x
            if abs(error) < 1e-7 { return t }
            let derivative = sampleDerivativeX(t)
            if abs(derivative) < 1e-7 { break }
            t -= error / derivative
        }

        // Bisection fallback for the rare case where the derivative vanishes.
        var low = 0.0
        var high = 1.0
        t = x
        for _ in 0..<32 {
            let value = sampleX(t)
            if abs(value - x) < 1e-7 { return t }
            if x > value {
                low = t
            } else {
                high = t
            }
            t = (low + high) / 2
        }

        return t
    }
}

/// Pure motion math for one compact <-> expanded morph.
///
/// Width and height ride the same normalized elapsed time on overlapping sub-ranges, so the panel
/// never comes to a stop between the "grows tall" and "grows wide" halves of the gesture. Keeping
/// this free of AppKit is what lets the motion contract be tested without a clock or a window.
struct FloatingToolbarMorphTimeline: Equatable {
    let from: CGSize
    let to: CGSize
    let duration: TimeInterval
    let widthRange: ClosedRange<Double>
    let heightRange: ClosedRange<Double>
    let widthCurve: UnitBezier
    let heightCurve: UnitBezier

    func size(atElapsed elapsed: TimeInterval) -> CGSize {
        guard duration > 0, elapsed < duration else { return to }

        let t = max(elapsed / duration, 0)
        return CGSize(
            width: interpolate(from.width, to.width, progress(t, in: widthRange, curve: widthCurve)),
            height: interpolate(from.height, to.height, progress(t, in: heightRange, curve: heightCurve))
        )
    }

    func isFinished(atElapsed elapsed: TimeInterval) -> Bool {
        duration <= 0 || elapsed >= duration
    }

    private func progress(
        _ t: Double,
        in range: ClosedRange<Double>,
        curve: UnitBezier
    ) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return t >= range.lowerBound ? 1 : 0 }
        return curve.value(for: (t - range.lowerBound) / span)
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: Double) -> CGFloat {
        start + ((end - start) * CGFloat(progress))
    }
}

extension UnitBezier: Equatable {}

/// Emits elapsed-time ticks for a running morph.
///
/// Production ticks on the display refresh; tests advance a manual implementation explicitly.
@MainActor
protocol FloatingToolbarMorphTicker: AnyObject {
    /// Begins delivering ticks measured in seconds since this call.
    ///
    /// Returns `false` when ticking cannot start, so the caller can settle on the target directly.
    @discardableResult
    func start(_ tick: @escaping @MainActor (TimeInterval) -> Void) -> Bool

    func stop()
}

@MainActor
final class DisplayLinkMorphTicker: FloatingToolbarMorphTicker {
    private let viewProvider: @MainActor () -> NSView?
    private var displayLink: CADisplayLink?
    private var tick: (@MainActor (TimeInterval) -> Void)?
    private var startTimestamp: CFTimeInterval?

    init(viewProvider: @escaping @MainActor () -> NSView?) {
        self.viewProvider = viewProvider
    }

    @discardableResult
    func start(_ tick: @escaping @MainActor (TimeInterval) -> Void) -> Bool {
        stop()

        // `displayLink(target:selector:)` never fires while the view is hidden or off-display.
        guard let view = viewProvider(), view.window != nil else { return false }

        self.tick = tick
        startTimestamp = nil

        let link = view.displayLink(target: self, selector: #selector(handleTick(_:)))
        // `.common` keeps ticks flowing while AppKit runs a tracking loop.
        link.add(to: .main, forMode: .common)
        displayLink = link
        return true
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        tick = nil
        startTimestamp = nil
    }

    @objc
    private func handleTick(_ link: CADisplayLink) {
        let start = startTimestamp ?? link.timestamp
        startTimestamp = start
        tick?(link.timestamp - start)
    }
}

/// Runs one continuous compact <-> expanded morph at a time.
///
/// The driver owns the live interpolated size, so a morph that is interrupted mid-flight resumes
/// from where the panel actually is instead of snapping back to a nominal start.
@MainActor
final class FloatingToolbarMorphDriver {
    /// A reversal with little distance left should not take the full nominal duration.
    static let minimumReversalDurationFactor: Double = 0.45

    private let ticker: any FloatingToolbarMorphTicker
    private var timeline: FloatingToolbarMorphTimeline?
    private var onTick: (@MainActor (CGSize) -> Void)?
    private var onFinish: (@MainActor () -> Void)?

    private(set) var interpolatedSize: CGSize?

    var isRunning: Bool { timeline != nil }

    init(ticker: any FloatingToolbarMorphTicker) {
        self.ticker = ticker
    }

    func morph(
        fallbackStart: CGSize,
        target: CGSize,
        duration: TimeInterval,
        widthRange: ClosedRange<Double>,
        heightRange: ClosedRange<Double>,
        widthCurve: UnitBezier,
        heightCurve: UnitBezier,
        onTick: @escaping @MainActor (CGSize) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) {
        let start = interpolatedSize ?? fallbackStart

        self.onTick = onTick
        self.onFinish = onFinish

        guard start != target else {
            settle(at: target)
            return
        }

        timeline = FloatingToolbarMorphTimeline(
            from: start,
            to: target,
            duration: duration * durationFactor(from: start, fallbackStart: fallbackStart, target: target),
            widthRange: widthRange,
            heightRange: heightRange,
            widthCurve: widthCurve,
            heightCurve: heightCurve
        )

        let started = ticker.start { [weak self] elapsed in
            self?.handleTick(elapsed)
        }

        if !started {
            settle(at: target)
        }
    }

    /// Stops any running morph but keeps the live size, so a follow-up morph resumes from it.
    func cancel() {
        ticker.stop()
        timeline = nil
        onTick = nil
        onFinish = nil
    }

    /// Drops all morph state, including the live size. Used when the panel is shown or dismissed.
    func reset(to size: CGSize? = nil) {
        cancel()
        interpolatedSize = size
    }

    private func durationFactor(
        from start: CGSize,
        fallbackStart: CGSize,
        target: CGSize
    ) -> Double {
        let fullDistance = distance(fallbackStart, target)
        guard fullDistance > 0 else { return 1 }

        let remaining = distance(start, target)
        return min(max(remaining / fullDistance, Self.minimumReversalDurationFactor), 1)
    }

    private func distance(_ lhs: CGSize, _ rhs: CGSize) -> Double {
        max(abs(Double(lhs.width - rhs.width)), abs(Double(lhs.height - rhs.height)))
    }

    private func handleTick(_ elapsed: TimeInterval) {
        guard let timeline else { return }

        guard !timeline.isFinished(atElapsed: elapsed) else {
            settle(at: timeline.to)
            return
        }

        let size = timeline.size(atElapsed: elapsed)
        interpolatedSize = size
        onTick?(size)
    }

    /// Emits the target exactly once and releases the callbacks.
    private func settle(at size: CGSize) {
        let tick = onTick
        let completion = onFinish

        ticker.stop()
        timeline = nil
        onTick = nil
        onFinish = nil
        interpolatedSize = size

        tick?(size)
        completion?()
    }
}
