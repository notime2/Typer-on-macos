// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import Typer_On

private let quickToolbarTimings = FloatingToolbarTransitionTimings(
    compactExpandDelay: 0.01,
    expandedCollapseDelay: 0.01,
    expandDuration: 0.01,
    collapseDuration: 0.01,
    expandHeightRange: 0...0.45,
    expandWidthRange: 0.315...1,
    collapseWidthRange: 0...0.55,
    collapseHeightRange: 0.4...1
)

private let compactTestSize = CGSize(width: 20, height: 20)
private let expandedTestSize = CGSize(width: 240, height: 44)

private func makeExpandTimeline(
    timings: FloatingToolbarTransitionTimings = .runtime
) -> FloatingToolbarMorphTimeline {
    FloatingToolbarMorphTimeline(
        from: compactTestSize,
        to: expandedTestSize,
        duration: timings.expandDuration,
        widthRange: timings.expandWidthRange,
        heightRange: timings.expandHeightRange,
        widthCurve: FloatingToolbarAnimationCurves.openSecondaryBezier,
        heightCurve: FloatingToolbarAnimationCurves.openPrimaryBezier
    )
}

private func controlPoints(for function: CAMediaTimingFunction) -> [Float] {
    (1...2).flatMap { index in
        var values: [Float] = [0, 0]
        function.getControlPoint(at: index, values: &values)
        return values.map { value in
            (value * 100).rounded() / 100
        }
    }
}

/// Manual morph ticker: tests emit elapsed times explicitly instead of depending on a real
/// display link, which would make the continuous morph non-deterministic under test.
@MainActor
private final class ManualMorphTicker: FloatingToolbarMorphTicker {
    private var tick: (@MainActor (TimeInterval) -> Void)?

    var isTicking: Bool { tick != nil }

    @discardableResult
    func start(_ tick: @escaping @MainActor (TimeInterval) -> Void) -> Bool {
        self.tick = tick
        return true
    }

    func stop() {
        tick = nil
    }

    /// Delivers one tick at `elapsed` seconds into the running morph.
    func emit(_ elapsed: TimeInterval) {
        tick?(elapsed)
    }

    /// Runs the current morph to completion.
    func finish() {
        tick?(.greatestFiniteMagnitude)
    }
}

@MainActor
private final class ManualFloatingToolbarAlphaAnimator: FloatingToolbarAlphaAnimator {
    private var hideCompletions: [@MainActor () -> Void] = []
    private(set) var showCount = 0

    func animate(
        panel: NSPanel,
        to alpha: CGFloat,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction,
        completion: @escaping @MainActor () -> Void
    ) {
        panel.alphaValue = alpha
        if alpha == 0 {
            hideCompletions.append(completion)
        } else {
            showCount += 1
            completion()
        }
    }

    func completeNextHide() {
        hideCompletions.removeFirst()()
    }
}

/// Virtual clock for the hover intent delays: tests advance it explicitly instead of
/// waiting on wall-clock time, so transition phases are observed deterministically.
@MainActor
private final class ManualFloatingToolbarTransitionScheduler: FloatingToolbarTransitionScheduler {
    private struct Entry {
        let id: UUID
        let fireTime: TimeInterval
        let work: @MainActor () -> Void
    }

    private var entries: [Entry] = []
    private var now: TimeInterval = 0

    func schedule(
        after delay: TimeInterval,
        perform work: @escaping @MainActor () -> Void
    ) -> FloatingToolbarScheduledWork {
        let id = UUID()
        entries.append(Entry(id: id, fireTime: now + delay, work: work))

        return FloatingToolbarScheduledWork { [weak self] in
            self?.entries.removeAll { $0.id == id }
        }
    }

    /// Runs every step that comes due within `interval`, including steps the
    /// running steps schedule themselves.
    func advance(by interval: TimeInterval) {
        let target = now + interval

        while let next = entries
            .filter({ $0.fireTime <= target })
            .min(by: { $0.fireTime < $1.fireTime }) {
            entries.removeAll { $0.id == next.id }
            now = next.fireTime
            next.work()
        }

        now = target
    }
}

@MainActor
private func makeToolbarViewModel(
    scheduler: ManualFloatingToolbarTransitionScheduler,
    timings: FloatingToolbarTransitionTimings = quickToolbarTimings,
    ticker: ManualMorphTicker = ManualMorphTicker()
) -> FloatingToolbarViewModel {
    FloatingToolbarViewModel(
        environment: AppEnvironment(),
        keyboardMonitoringEnabled: false,
        transitionTimings: timings,
        transitionScheduler: scheduler,
        morphTicker: ticker
    )
}

@Test
func testRuntimeTransitionTimingsUseTactileDurations() {
    #expect(FloatingToolbarTransitionTimings.runtime.compactExpandDelay == 0.05)
    #expect(FloatingToolbarTransitionTimings.runtime.expandedCollapseDelay == 0.18)
    #expect(FloatingToolbarTransitionTimings.runtime.expandDuration == 0.21)
    #expect(FloatingToolbarTransitionTimings.runtime.collapseDuration == 0.185)
    #expect(FloatingToolbarTransitionTimings.runtime.expandHeightRange == 0...0.45)
    #expect(FloatingToolbarTransitionTimings.runtime.expandWidthRange == 0.315...1)
    #expect(FloatingToolbarTransitionTimings.runtime.collapseWidthRange == 0...0.55)
    #expect(FloatingToolbarTransitionTimings.runtime.collapseHeightRange == 0.4...1)
}

@Test
func testFloatingToolbarAnimationCurvesUseCustomControlPoints() {
    #expect(controlPoints(for: FloatingToolbarAnimationCurves.openSecondary) == [0.16, 0.90, 0.24, 1.0])
    #expect(controlPoints(for: FloatingToolbarAnimationCurves.closePrimary) == [0.18, 0.84, 0.28, 1.0])
}

@Test
@MainActor
func testAutoDetectShowStartsInCompactMode() {
    let viewModel = makeToolbarViewModel(scheduler: ManualFloatingToolbarTransitionScheduler())
    defer { viewModel.dismiss() }

    viewModel.show(
        for: TextSelection(text: "Hello", cursorPosition: NSPoint(x: 20, y: 20)),
        source: .autoDetect
    )

    #expect(viewModel.isVisible)
    #expect(viewModel.presentationMode == .compact)
    #expect(viewModel.presentationSource == .autoDetect)
}

@Test(arguments: [FloatingToolbarPresentationSource.autoDetect, .explicit])
@MainActor
func testNewPresentationSurvivesPreviousHideCompletion(source: FloatingToolbarPresentationSource) {
    let animator = ManualFloatingToolbarAlphaAnimator()
    let panel = FloatingToolbarPanel(alphaAnimator: animator)
    let viewModel = FloatingToolbarViewModel(
        environment: AppEnvironment(),
        keyboardMonitoringEnabled: false,
        panel: panel
    )
    defer { panel.orderOut(nil) }

    viewModel.show(
        for: TextSelection(text: "First selection", cursorPosition: NSPoint(x: 200, y: 200)),
        source: .autoDetect
    )
    viewModel.dismiss()
    #expect(panel.isVisible)

    viewModel.show(
        for: TextSelection(text: "New selection", cursorPosition: NSPoint(x: 220, y: 200)),
        source: source
    )
    animator.completeNextHide()

    #expect(panel.isVisible)
    #expect(panel.alphaValue == 1)
    #expect(viewModel.isVisible)
    #expect(viewModel.currentSelection?.text == "New selection")
    #expect(viewModel.presentationMode == FloatingToolbarViewModel.initialPresentationMode(for: source))

    viewModel.dismiss()
    animator.completeNextHide()
    #expect(!panel.isVisible)
}

@Test
@MainActor
func testProcessingIndicatorSurvivesPreviousHideCompletion() {
    let animator = ManualFloatingToolbarAlphaAnimator()
    let panel = FloatingToolbarPanel(alphaAnimator: animator)
    let viewModel = FloatingToolbarViewModel(
        environment: AppEnvironment(),
        keyboardMonitoringEnabled: false,
        panel: panel
    )
    defer { panel.orderOut(nil) }
    let selection = TextSelection(text: "Process this", cursorPosition: NSPoint(x: 200, y: 200))
    viewModel.show(for: selection, source: .explicit)
    viewModel.dismiss()
    viewModel.beginProcessingIndicator(for: selection)
    animator.completeNextHide()

    #expect(panel.isVisible)
    #expect(panel.alphaValue == 1)
    #expect(viewModel.isVisible)
    #expect(viewModel.processingStatus == .processing(canCancel: true))

    viewModel.dismiss()
    animator.completeNextHide()
    #expect(!panel.isVisible)
}

@Test
@MainActor
func testVisiblePanelRefreshDoesNotRestartAlphaAnimation() {
    let animator = ManualFloatingToolbarAlphaAnimator()
    let panel = FloatingToolbarPanel(alphaAnimator: animator)
    defer { panel.orderOut(nil) }
    let rect = NSRect(x: 200, y: 200, width: 20, height: 20)

    panel.show(contentRect: rect)
    panel.show(contentRect: rect.offsetBy(dx: 30, dy: 0))

    #expect(animator.showCount == 1)
    #expect(panel.alphaValue == 1)
}

@Test
@MainActor
func testOnlyLatestHideCompletionCanOrderOutPanel() {
    let animator = ManualFloatingToolbarAlphaAnimator()
    let panel = FloatingToolbarPanel(alphaAnimator: animator)
    defer { panel.orderOut(nil) }
    let rect = NSRect(x: 200, y: 200, width: 20, height: 20)
    panel.show(contentRect: rect)
    panel.dismiss()
    panel.show(contentRect: rect)
    panel.dismiss()

    animator.completeNextHide()
    #expect(panel.isVisible)
    animator.completeNextHide()
    #expect(!panel.isVisible)
}

@Test
@MainActor
func testCompactHoverExpandsToolbar() {
    let scheduler = ManualFloatingToolbarTransitionScheduler()
    let ticker = ManualMorphTicker()
    let viewModel = makeToolbarViewModel(scheduler: scheduler, ticker: ticker)
    defer { viewModel.dismiss() }

    viewModel.show(
        for: TextSelection(text: "Hello", cursorPosition: NSPoint(x: 20, y: 20)),
        source: .autoDetect
    )
    viewModel.handleCompactTriggerHoverChanged(true)
    scheduler.advance(by: 1)
    ticker.finish()

    #expect(viewModel.presentationMode == .expanded)
    #expect(viewModel.transitionPhase == .idle)
}

@Test
@MainActor
func testExpandedHoverExitCollapsesBackToCompactForAutoDetect() {
    let scheduler = ManualFloatingToolbarTransitionScheduler()
    let ticker = ManualMorphTicker()
    let viewModel = makeToolbarViewModel(scheduler: scheduler, ticker: ticker)
    defer { viewModel.dismiss() }

    viewModel.show(
        for: TextSelection(text: "Hello", cursorPosition: NSPoint(x: 20, y: 20)),
        source: .autoDetect
    )
    viewModel.handleCompactTriggerActivation()
    ticker.finish()
    #expect(viewModel.presentationMode == .expanded)
    #expect(viewModel.transitionPhase == .idle)

    viewModel.handleExpandedHoverChanged(false)
    scheduler.advance(by: 1)
    ticker.finish()

    #expect(viewModel.presentationMode == .compact)
    #expect(viewModel.transitionPhase == .idle)
}

@Test
@MainActor
func testExplicitTriggerWhileCompactExpandsToolbar() {
    let viewModel = makeToolbarViewModel(scheduler: ManualFloatingToolbarTransitionScheduler())
    defer { viewModel.dismiss() }

    viewModel.show(
        for: TextSelection(text: "Hello", cursorPosition: NSPoint(x: 20, y: 20)),
        source: .autoDetect
    )

    let handled = viewModel.handleExplicitTriggerIfVisible()

    #expect(handled)
    #expect(viewModel.presentationMode == .expanded)
    #expect(viewModel.transitionPhase == .expanding)
}

@Test
@MainActor
func testExplicitTriggerWhileExpandedDismissesToolbar() {
    let viewModel = makeToolbarViewModel(scheduler: ManualFloatingToolbarTransitionScheduler())

    viewModel.show(
        for: TextSelection(text: "Hello", cursorPosition: NSPoint(x: 20, y: 20)),
        source: .explicit
    )

    let handled = viewModel.handleExplicitTriggerIfVisible()

    #expect(handled)
    #expect(viewModel.isVisible == false)
    #expect(viewModel.presentationMode == nil)
}

@Test
func testMorphTimelineLandsExactlyOnItsEndpoints() {
    let timeline = makeExpandTimeline()

    #expect(timeline.size(atElapsed: 0) == compactTestSize)
    #expect(timeline.size(atElapsed: timeline.duration) == expandedTestSize)
    // Overshooting the timeline must not overshoot the geometry.
    #expect(timeline.size(atElapsed: timeline.duration * 2) == expandedTestSize)
    #expect(timeline.isFinished(atElapsed: timeline.duration))
    #expect(!timeline.isFinished(atElapsed: timeline.duration / 2))
}

@Test
func testMorphTimelineGrowsBothDimensionsMonotonically() {
    let timeline = makeExpandTimeline()
    let steps = 200

    let samples = (0...steps).map { step in
        timeline.size(atElapsed: timeline.duration * Double(step) / Double(steps))
    }

    for (previous, current) in zip(samples, samples.dropFirst()) {
        #expect(current.width >= previous.width)
        #expect(current.height >= previous.height)
    }
}

@Test
func testMorphTimelineOverlapsWidthAndHeightRamps() {
    let timings = FloatingToolbarTransitionTimings.runtime

    // The width ramp has to begin before the height ramp is done, in both directions.
    #expect(timings.expandWidthRange.lowerBound < timings.expandHeightRange.upperBound)
    #expect(timings.collapseHeightRange.lowerBound < timings.collapseWidthRange.upperBound)

    let timeline = makeExpandTimeline()
    let overlapStart = timings.expandWidthRange.lowerBound * timeline.duration
    let overlapEnd = timings.expandHeightRange.upperBound * timeline.duration

    let atStart = timeline.size(atElapsed: overlapStart)
    let atEnd = timeline.size(atElapsed: overlapEnd)

    // Inside the overlap both dimensions are still travelling. The staged morph used to come to
    // a full stop here, which is what read as a hitch between "grows tall" and "grows wide".
    #expect(atEnd.width > atStart.width)
    #expect(atEnd.height > atStart.height)
    #expect(atEnd.height < expandedTestSize.height || atStart.height > compactTestSize.height)
}

@Test
@MainActor
func testMorphDriverReversesFromTheCurrentInterpolatedSize() {
    let ticker = ManualMorphTicker()
    let driver = FloatingToolbarMorphDriver(ticker: ticker)
    let timings = FloatingToolbarTransitionTimings.runtime
    var sizes: [CGSize] = []

    driver.morph(
        fallbackStart: compactTestSize,
        target: expandedTestSize,
        duration: timings.expandDuration,
        widthRange: timings.expandWidthRange,
        heightRange: timings.expandHeightRange,
        widthCurve: FloatingToolbarAnimationCurves.openSecondaryBezier,
        heightCurve: FloatingToolbarAnimationCurves.openPrimaryBezier,
        onTick: { sizes.append($0) },
        onFinish: {}
    )

    // Sampled inside the height ramp, before the width ramp starts, so the size is genuinely
    // mid-flight in both dimensions rather than already settled in one of them.
    ticker.emit(timings.expandDuration * 0.2)
    let midway = sizes.last ?? .zero
    #expect(midway.height > compactTestSize.height)
    #expect(midway.height < expandedTestSize.height)
    #expect(midway.width == compactTestSize.width)

    sizes.removeAll()
    driver.morph(
        fallbackStart: expandedTestSize,
        target: compactTestSize,
        duration: timings.collapseDuration,
        widthRange: timings.collapseWidthRange,
        heightRange: timings.collapseHeightRange,
        widthCurve: FloatingToolbarAnimationCurves.closePrimaryBezier,
        heightCurve: FloatingToolbarAnimationCurves.closePrimaryBezier,
        onTick: { sizes.append($0) },
        onFinish: {}
    )
    ticker.emit(0)

    // The reversal starts from where the panel actually is, not from the nominal expanded size.
    #expect(sizes.first == midway)

    ticker.finish()
    #expect(sizes.last == compactTestSize)
    #expect(!ticker.isTicking)
}

@Test
@MainActor
func testHoverExitDuringExpansionStillCollapses() {
    let timings = FloatingToolbarTransitionTimings(
        compactExpandDelay: 0.01,
        expandedCollapseDelay: 0.01,
        expandDuration: 0.2,
        collapseDuration: 0.2,
        expandHeightRange: 0...0.45,
        expandWidthRange: 0.315...1,
        collapseWidthRange: 0...0.55,
        collapseHeightRange: 0.4...1
    )
    let scheduler = ManualFloatingToolbarTransitionScheduler()
    let ticker = ManualMorphTicker()
    let viewModel = makeToolbarViewModel(scheduler: scheduler, timings: timings, ticker: ticker)
    defer { viewModel.dismiss() }

    viewModel.show(
        for: TextSelection(text: "Hello", cursorPosition: NSPoint(x: 20, y: 20)),
        source: .autoDetect
    )
    viewModel.handleCompactTriggerActivation()
    #expect(viewModel.transitionPhase == .expanding)

    // The pointer leaves while the morph is still running. The staged implementation dropped
    // this event behind a `transitionPhase == .idle` guard and stayed expanded.
    ticker.emit(timings.expandDuration / 4)
    viewModel.handleExpandedHoverChanged(false)
    scheduler.advance(by: 1)
    #expect(viewModel.transitionPhase == .collapsing)

    ticker.finish()
    #expect(viewModel.presentationMode == .compact)
    #expect(viewModel.transitionPhase == .idle)
}

@Test
@MainActor
func testHoverReturnDuringCollapseReversesBackToExpanded() {
    let timings = FloatingToolbarTransitionTimings(
        compactExpandDelay: 0.01,
        expandedCollapseDelay: 0.01,
        expandDuration: 0.2,
        collapseDuration: 0.2,
        expandHeightRange: 0...0.45,
        expandWidthRange: 0.315...1,
        collapseWidthRange: 0...0.55,
        collapseHeightRange: 0.4...1
    )
    let scheduler = ManualFloatingToolbarTransitionScheduler()
    let ticker = ManualMorphTicker()
    let viewModel = makeToolbarViewModel(scheduler: scheduler, timings: timings, ticker: ticker)
    defer { viewModel.dismiss() }

    viewModel.show(
        for: TextSelection(text: "Hello", cursorPosition: NSPoint(x: 20, y: 20)),
        source: .autoDetect
    )
    viewModel.handleCompactTriggerActivation()
    ticker.finish()

    viewModel.handleExpandedHoverChanged(false)
    scheduler.advance(by: 1)
    #expect(viewModel.transitionPhase == .collapsing)

    ticker.emit(timings.collapseDuration / 4)
    viewModel.handleExpandedHoverChanged(true)
    #expect(viewModel.transitionPhase == .expanding)

    ticker.finish()
    #expect(viewModel.presentationMode == .expanded)
    #expect(viewModel.transitionPhase == .idle)
}

@Test
func testSelectionTriggerStyleDefaultsToGlassDot() {
    let suiteName = "FloatingToolbarPresentationTests.default.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    #expect(defaults.selectionTriggerStyle == .glassDot)
}

@Test
func testSelectionTriggerStylesHaveStableFourItemOrder() {
    #expect(
        SelectionTriggerStyle.allCases == [
            .glassDot,
            .softAccent,
            .monochromeInk,
            .editorial,
        ]
    )
    #expect(SelectionTriggerStyle.editorial.rawValue == "editorial")
    #expect(SelectionTriggerStyle.editorial.displayName == "Editorial")
    #expect(!SelectionTriggerStyle.editorial.shortDescription.isEmpty)
}

@Test(arguments: SelectionTriggerStyle.allCases)
func testSelectionTriggerStylePersistsSavedValue(style: SelectionTriggerStyle) {
    let suiteName = "FloatingToolbarPresentationTests.persist.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.setSelectionTriggerStyle(style)

    #expect(defaults.selectionTriggerStyle == style)
}

@Test
func testUnknownSelectionTriggerStyleFallsBackToGlassDot() {
    let suiteName = "FloatingToolbarPresentationTests.unknown.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    defaults.set("future-style", for: .selectionTriggerStyle)

    #expect(defaults.selectionTriggerStyle == .glassDot)
}

@Test
func testFloatingToolbarSurfaceTreatmentUsesNativeLiquidGlassWhenGlassDotAndAvailable() {
    let treatment = FloatingToolbarSurfaceTreatment.resolve(
        style: .glassDot,
        nativeLiquidGlassAvailable: true
    )

    #expect(treatment == .nativeLiquidGlass)
}

@Test
func testFloatingToolbarSurfaceTreatmentFallsBackWhenGlassDotAndNativeUnavailable() {
    let treatment = FloatingToolbarSurfaceTreatment.resolve(
        style: .glassDot,
        nativeLiquidGlassAvailable: false
    )

    #expect(treatment == .fallbackChrome)
}

@Test
func testFloatingToolbarSurfaceTreatmentFallsBackForNonGlassDotStyles() {
    for style in [SelectionTriggerStyle.softAccent, .monochromeInk, .editorial] {
        let treatment = FloatingToolbarSurfaceTreatment.resolve(
            style: style,
            nativeLiquidGlassAvailable: true
        )

        #expect(treatment == .fallbackChrome)
    }
}

@Test
func testEditorialThemeUsesCrispPanelRadiusWithoutChangingExistingStyles() {
    #expect(SelectionUITheme(style: .editorial).expandedCornerRadius == DS.Radius.card)
    #expect(SelectionUITheme(style: .glassDot).expandedCornerRadius == DS.Radius.panel)
    #expect(SelectionUITheme(style: .softAccent).expandedCornerRadius == DS.Radius.panel)
    #expect(SelectionUITheme(style: .monochromeInk).expandedCornerRadius == DS.Radius.panel)
}

@Test
func testEditorialCompactBackgroundStaysDistinctFromMonochromeInkInBothAppearances() {
    let editorial = SelectionUIThemePalette.editorialPaper
    let monochrome = SelectionUIThemePalette.monochromeCompactBackground

    #expect(editorial.darkHex == 0x312D28)
    #expect(squaredSRGBDistance(editorial.lightHex, monochrome.lightHex) >= 100)
    #expect(squaredSRGBDistance(editorial.darkHex, monochrome.darkHex) >= 100)

    let editorialDark = rgbComponents(editorial.darkHex)
    let monochromeDark = rgbComponents(monochrome.darkHex)
    #expect(editorialDark.red > monochromeDark.red)
    #expect(editorialDark.green > monochromeDark.green)
    #expect(editorialDark.blue > monochromeDark.blue)
}

@Test
@MainActor
func testFourStylePreviewRendersAsTwoRowsAtMinimumSettingsDetailWidth() {
    let renderer = ImageRenderer(
        content: SelectionStylePreviewStrip(selectedStyle: .constant(.editorial))
            .frame(width: 360)
    )
    renderer.scale = 1
    renderer.proposedSize = ProposedViewSize(width: 360, height: nil)

    let image = renderer.nsImage

    #expect(image != nil)
    #expect(image?.size.width == 360)
    #expect((image?.size.height ?? 0) > 200)
    #expect((image?.size.height ?? .infinity) < 400)
}

private func squaredSRGBDistance(_ lhs: UInt, _ rhs: UInt) -> Int {
    let lhsComponents = rgbComponents(lhs)
    let rhsComponents = rgbComponents(rhs)
    let redDelta = lhsComponents.red - rhsComponents.red
    let greenDelta = lhsComponents.green - rhsComponents.green
    let blueDelta = lhsComponents.blue - rhsComponents.blue

    return (redDelta * redDelta) + (greenDelta * greenDelta) + (blueDelta * blueDelta)
}

private func rgbComponents(_ hex: UInt) -> (red: Int, green: Int, blue: Int) {
    (
        red: Int((hex >> 16) & 0xFF),
        green: Int((hex >> 8) & 0xFF),
        blue: Int(hex & 0xFF)
    )
}

@Test
func testFloatingToolbarLayoutMetricsPreserveRuntimeGeometry() {
    let metrics = FloatingToolbarLayoutMetrics()
    let expandedSize = metrics.expandedSize(moduleCount: 5)

    #expect(metrics.compactVisibleSize == 16)
    #expect(metrics.compactInteractiveSize == 20)
    #expect(metrics.expandedHeight == 44)

    // Only the resting endpoints are geometry now; everything between them comes from the
    // morph timeline instead of a per-phase size table.
    #expect(metrics.compactSizeValue == CGSize(width: 20, height: 20))
    #expect(metrics.targetSize(for: .compact, moduleCount: 5) == CGSize(width: 20, height: 20))
    #expect(metrics.targetSize(for: .expanded, moduleCount: 5) == expandedSize)
}

@Test
func testProcessingStatusSuppressesToolbarContent() {
    let statuses: [FloatingToolbarProcessingStatus] = [
        .processing(canCancel: true),
        .processing(canCancel: false),
        .success,
    ]

    for status in statuses {
        #expect(
            !FloatingToolbarContentReveal.mountsToolbarContent(
                revealProgress: 1,
                isSettledExpanded: true,
                processingStatus: status
            )
        )
    }

    #expect(
        FloatingToolbarContentReveal.mountsToolbarContent(
            revealProgress: 1,
            isSettledExpanded: true,
            processingStatus: nil
        )
    )
    // Nothing to lay out while the panel rests compact, but the row mounts as soon as the
    // reveal begins so the crossfade has something to fade into.
    #expect(
        !FloatingToolbarContentReveal.mountsToolbarContent(
            revealProgress: 0,
            isSettledExpanded: false,
            processingStatus: nil
        )
    )
    #expect(
        FloatingToolbarContentReveal.mountsToolbarContent(
            revealProgress: 0.01,
            isSettledExpanded: false,
            processingStatus: nil
        )
    )
}

@Test
func testContentRevealCrossfadesSeedIntoToolbar() {
    #expect(
        FloatingToolbarContentReveal.revealProgress(
            containerWidth: 20, compactWidth: 20, expandedWidth: 240
        ) == 0
    )
    #expect(
        FloatingToolbarContentReveal.revealProgress(
            containerWidth: 240, compactWidth: 20, expandedWidth: 240
        ) == 1
    )
    #expect(
        FloatingToolbarContentReveal.revealProgress(
            containerWidth: 130, compactWidth: 20, expandedWidth: 240
        ) == 0.5
    )

    #expect(FloatingToolbarContentReveal.seedOpacity(revealProgress: 0) == 1)
    #expect(FloatingToolbarContentReveal.seedOpacity(revealProgress: 1) == 0)
    #expect(FloatingToolbarContentReveal.toolbarOpacity(revealProgress: 0) == 0)
    #expect(FloatingToolbarContentReveal.toolbarOpacity(revealProgress: 1) == 1)

    // Both are partly visible together: this overlap is the crossfade the staged morph
    // could not express, because seed and toolbar row were mutually exclusive.
    let seed = FloatingToolbarContentReveal.seedOpacity(revealProgress: 0.2)
    let toolbar = FloatingToolbarContentReveal.toolbarOpacity(revealProgress: 0.2)
    #expect(seed > 0 && seed < 1)
    #expect(toolbar > 0 && toolbar < 1)
}

@Test
@MainActor
func testSurfaceGeometryKeepsCornerRadiusContinuous() {
    let theme = SelectionUITheme(style: .glassDot)
    let layout = FloatingToolbarLayoutMetrics()

    func radius(width: CGFloat, height: CGFloat) -> CGFloat {
        FloatingToolbarSurfaceGeometry(
            containerSize: CGSize(width: width, height: height),
            theme: theme,
            layout: layout,
            moduleCount: 5
        ).cornerRadius
    }

    // Resting endpoints stay exact.
    #expect(radius(width: 20, height: 20) == layout.compactInteractiveSize / 2)
    let expandedWidth = layout.expandedWidth(moduleCount: 5)
    #expect(
        abs(radius(width: expandedWidth, height: layout.expandedHeight) - theme.expandedCornerRadius)
            < 0.001
    )

    // The old rule flipped from `width / 2` to a fixed expanded radius the instant width passed
    // height, which snapped the corner in a single frame. Sample tightly across that crossing.
    let below = radius(width: 43.9, height: layout.expandedHeight)
    let above = radius(width: 44.1, height: layout.expandedHeight)
    #expect(abs(above - below) < 0.05)
}

@Test
func testContentRevealCascadesButtonsLeftToRight() {
    let count = 8

    for index in 0..<count {
        #expect(
            FloatingToolbarContentReveal.buttonOpacity(
                index: index, count: count, revealProgress: 0
            ) == 0
        )
        // The cascade completes inside the reveal, so it costs no extra transition time.
        #expect(
            FloatingToolbarContentReveal.buttonOpacity(
                index: index, count: count, revealProgress: 1
            ) == 1
        )
    }

    let midway = (0..<count).map { index in
        FloatingToolbarContentReveal.buttonOpacity(
            index: index, count: count, revealProgress: 0.4
        )
    }

    for (leading, trailing) in zip(midway, midway.dropFirst()) {
        #expect(leading >= trailing)
    }
    #expect((midway.first ?? 0) > (midway.last ?? 1))
}

@Test
@MainActor
func testFloatingToolbarPreservesSourceKeyWindowAndSelection() async throws {
    let application = NSApplication.shared
    let previousKeyWindow = application.keyWindow
    let previousPolicy = application.activationPolicy()
    let previousActiveApplication = NSWorkspace.shared.frontmostApplication
    let hostPID = ProcessInfo.processInfo.processIdentifier
    let needsPolicyChange = previousPolicy == .prohibited
    defer {
        if needsPolicyChange, application.activationPolicy() == .regular {
            application.setActivationPolicy(previousPolicy)
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPID,
           let previousActiveApplication,
           previousActiveApplication.processIdentifier != hostPID,
           !previousActiveApplication.isTerminated {
            previousActiveApplication.activate(options: [])
        }
    }
    if needsPolicyChange {
        try #require(application.setActivationPolicy(.regular))
    }
    if !application.isActive {
        let (signals, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: application,
            queue: .main
        ) { _ in
            continuation.yield(true)
            continuation.finish()
        }
        let timeout = DispatchWorkItem {
            continuation.yield(false)
            continuation.finish()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            timeout.cancel()
            continuation.finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        if application.isActive {
            continuation.yield(true)
            continuation.finish()
        } else {
            application.activate(ignoringOtherApps: true)
        }
        var activated = false
        for await signal in signals {
            activated = signal
            break
        }
        try #require(activated, "Host activation timed out: running=\(application.isRunning), active=\(application.isActive), policy=\(application.activationPolicy().rawValue)")
    }
    try #require(application.isActive)

    // No suspension after activation: shared AppKit key state is exercised as
    // one synchronous MainActor operation, without interleaving other UI tests.
    let source = NSPanel(
        contentRect: NSRect(x: 100, y: 100, width: 400, height: 200),
        styleMask: [.titled, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    source.isReleasedWhenClosed = false
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    editor.string = "Synthetic source selection"
    source.contentView = editor
    let panel = FloatingToolbarPanel(alphaAnimator: ManualFloatingToolbarAlphaAnimator())
    defer {
        panel.orderOut(nil)
        panel.close()
        source.orderOut(nil)
        source.close()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPID {
            previousKeyWindow?.makeKey()
        }
    }

    source.makeKeyAndOrderFront(nil)
    try #require(source.makeFirstResponder(editor))
    let selection = NSRange(location: 0, length: 9)
    editor.setSelectedRange(selection)
    try #require(source.isKeyWindow, "Source key setup failed: running=\(application.isRunning), active=\(application.isActive), policy=\(application.activationPolicy().rawValue), canBecomeKey=\(source.canBecomeKey)")
    try #require(source.firstResponder === editor)

    panel.show(contentRect: NSRect(x: 200, y: 320, width: 240, height: 44))
    #expect(source.isKeyWindow)
    #expect(source.firstResponder === editor)
    #expect(editor.selectedRange() == selection)
    #expect(!panel.isKeyWindow)

    panel.makeKey()
    #expect(source.isKeyWindow)
    #expect(source.firstResponder === editor)
    #expect(editor.selectedRange() == selection)
    #expect(!panel.isKeyWindow)

    panel.makeKeyAndOrderFront(nil)
    #expect(source.isKeyWindow)
    #expect(source.firstResponder === editor)
    #expect(editor.selectedRange() == selection)
    #expect(!panel.isKeyWindow)
}

@Test
@MainActor
func testFloatingToolbarPanelKeepsNativeShadowAndTransparentSurface() {
    let panel = FloatingToolbarPanel()

    #expect(panel.hasShadow)
    #expect(panel.isOpaque == false)
}

@Test
@MainActor
func testProcessingIndicatorUsesCancelOnlyUntilReplacementStarts() {
    let scheduler = ManualFloatingToolbarTransitionScheduler()
    let viewModel = makeToolbarViewModel(scheduler: scheduler)
    defer { viewModel.dismiss() }

    var cancelCount = 0
    viewModel.onProcessingCancel = { cancelCount += 1 }
    viewModel.beginProcessingIndicator(
        for: TextSelection(text: "Hello", cursorPosition: NSPoint(x: 20, y: 20)),
        source: .autoDetect
    )

    #expect(viewModel.processingStatus == .processing(canCancel: true))
    #expect(viewModel.handleKeyValues(keyCode: UInt16(kVK_Escape), modifiers: []) == true)
    #expect(cancelCount == 1)
    #expect(viewModel.handleKeyValues(keyCode: UInt16(kVK_ANSI_1), modifiers: [.command]) == false)

    viewModel.markProcessingReplacementStarted()
    #expect(viewModel.processingStatus == .processing(canCancel: false))
    #expect(viewModel.handleKeyValues(keyCode: UInt16(kVK_Escape), modifiers: []) == false)

    viewModel.showProcessingSuccess()
    #expect(viewModel.processingStatus == .success)

    scheduler.advance(by: FloatingToolbarViewModel.processingSuccessDismissDelay)
    #expect(viewModel.isVisible == false)
}
