// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

enum FloatingToolbarPresentationSource: Equatable {
    case autoDetect
    case explicit
}

enum FloatingToolbarPresentationMode: Equatable {
    case compact
    case expanded
}

enum FloatingToolbarProcessingStatus: Equatable {
    case processing(canCancel: Bool)
    case success
}

enum FloatingToolbarTransitionPhase: Equatable {
    case idle
    case expanding
    case collapsing
}

/// Opacity math for the seed <-> toolbar crossfade and the module-button cascade.
///
/// Everything is derived from the live container width, so the cascade rides the width ramp the
/// morph is already running: it costs no extra time and reverses by itself during a collapse.
enum FloatingToolbarContentReveal {
    /// Share of the reveal the cascade occupies, leaving a settled tail at the end.
    static let cascadeSpread: Double = 0.55
    /// Share of the reveal a single button takes to fade in.
    static let cascadeWindow: Double = 0.3
    private static let seedFadeSpan: Double = 0.35
    private static let toolbarFadeStart: Double = 0.12
    private static let toolbarFadeSpan: Double = 0.35

    static func revealProgress(
        containerWidth: CGFloat,
        compactWidth: CGFloat,
        expandedWidth: CGFloat
    ) -> Double {
        let span = Double(expandedWidth - compactWidth)
        guard span > 0 else { return containerWidth >= expandedWidth ? 1 : 0 }
        return clamp(Double(containerWidth - compactWidth) / span)
    }

    static func seedOpacity(revealProgress: Double) -> Double {
        clamp(1 - (revealProgress / seedFadeSpan))
    }

    static func toolbarOpacity(revealProgress: Double) -> Double {
        clamp((revealProgress - toolbarFadeStart) / toolbarFadeSpan)
    }

    /// The toolbar row costs a full-width layout pass, so it is only mounted once the reveal has
    /// actually begun. Processing status replaces the regular content entirely.
    static func mountsToolbarContent(
        revealProgress: Double,
        isSettledExpanded: Bool,
        processingStatus: FloatingToolbarProcessingStatus?
    ) -> Bool {
        guard processingStatus == nil else { return false }
        return revealProgress > 0 || isSettledExpanded
    }

    static func buttonOpacity(index: Int, count: Int, revealProgress: Double) -> Double {
        guard count > 0, index >= 0 else { return 0 }
        let step = cascadeSpread / Double(max(count - 1, 1))
        return clamp((revealProgress - (Double(index) * step)) / cascadeWindow)
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

struct FloatingToolbarTransitionTimings: Equatable {
    static let runtime = Self(
        compactExpandDelay: 0.05,
        expandedCollapseDelay: 0.18,
        expandDuration: 0.21,
        collapseDuration: 0.185,
        expandHeightRange: 0...0.45,
        expandWidthRange: 0.315...1,
        collapseWidthRange: 0...0.55,
        collapseHeightRange: 0.4...1
    )

    let compactExpandDelay: TimeInterval
    let expandedCollapseDelay: TimeInterval
    let expandDuration: TimeInterval
    let collapseDuration: TimeInterval
    /// Normalized sub-ranges of the shared morph timeline. Height and width overlap on purpose:
    /// that overlap is what keeps the panel from coming to a stop mid-gesture.
    let expandHeightRange: ClosedRange<Double>
    let expandWidthRange: ClosedRange<Double>
    let collapseWidthRange: ClosedRange<Double>
    let collapseHeightRange: ClosedRange<Double>
}

enum FloatingToolbarAnimationCurves {
    typealias ControlPoints = (x1: Double, y1: Double, x2: Double, y2: Double)

    /// Shipped tactile control points, the single source of truth for both representations:
    /// `CAMediaTimingFunction` drives the panel alpha fades, `UnitBezier` drives the morph.
    static let openPrimaryControlPoints: ControlPoints = (0.12, 0.92, 0.22, 1.0)
    static let openSecondaryControlPoints: ControlPoints = (0.16, 0.90, 0.24, 1.0)
    static let closePrimaryControlPoints: ControlPoints = (0.18, 0.84, 0.28, 1.0)

    // `CAMediaTimingFunction` is not Sendable, so these stay computed rather than stored.
    static var openSecondary: CAMediaTimingFunction { timingFunction(openSecondaryControlPoints) }
    static var closePrimary: CAMediaTimingFunction { timingFunction(closePrimaryControlPoints) }

    static let openPrimaryBezier = unitBezier(openPrimaryControlPoints)
    static let openSecondaryBezier = unitBezier(openSecondaryControlPoints)
    static let closePrimaryBezier = unitBezier(closePrimaryControlPoints)

    private static func timingFunction(_ points: ControlPoints) -> CAMediaTimingFunction {
        CAMediaTimingFunction(
            controlPoints: Float(points.x1),
            Float(points.y1),
            Float(points.x2),
            Float(points.y2)
        )
    }

    private static func unitBezier(_ points: ControlPoints) -> UnitBezier {
        UnitBezier(points.x1, points.y1, points.x2, points.y2)
    }
}

@MainActor
@Observable
final class FloatingToolbarViewModel {
    private let environment: AppEnvironment
    private let keyboardMonitoringEnabled: Bool
    private let transitionTimings: FloatingToolbarTransitionTimings
    private let transitionScheduler: any FloatingToolbarTransitionScheduler
    private let layoutMetrics: FloatingToolbarLayoutMetrics
    private let frameResolver: FloatingToolbarFrameResolver
    private let injectedMorphTicker: (any FloatingToolbarMorphTicker)?
    private var morphDriver: FloatingToolbarMorphDriver?
    private var panel: FloatingToolbarPanel?
    private var displayedModules: [any TextModule] = []
    private var hostingView: NSHostingView<FloatingToolbarPanelContentView>?
    private var keyboardEventTap: CFMachPort?
    private var keyboardEventTapSource: CFRunLoopSource?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var pendingExpandWork: FloatingToolbarScheduledWork?
    private var pendingCollapseWork: FloatingToolbarScheduledWork?
    private var processingSuccessWork: FloatingToolbarScheduledWork?

    static let processingSuccessDismissDelay: TimeInterval = 0.8

    private static let commandDigitMap: [UInt16: Int] = [
        UInt16(kVK_ANSI_1): 1,
        UInt16(kVK_ANSI_2): 2,
        UInt16(kVK_ANSI_3): 3,
        UInt16(kVK_ANSI_4): 4,
        UInt16(kVK_ANSI_5): 5,
        UInt16(kVK_ANSI_6): 6,
        UInt16(kVK_ANSI_7): 7,
        UInt16(kVK_ANSI_8): 8,
        UInt16(kVK_ANSI_9): 9,
    ]

    var onModuleInvoked: ((any TextModule, TextSelection) -> Bool)?
    var onUserDismiss: (() -> Void)?
    var onProcessingCancel: (() -> Void)?
    var onProcessingIndicatorFinished: (() -> Void)?

    private(set) var isVisible = false
    private(set) var currentSelection: TextSelection?
    private(set) var presentationMode: FloatingToolbarPresentationMode?
    private(set) var presentationSource: FloatingToolbarPresentationSource?
    private(set) var processingStatus: FloatingToolbarProcessingStatus?
    private(set) var transitionPhase: FloatingToolbarTransitionPhase = .idle

    enum KeyboardAction: Equatable {
        case dismiss
        case invokeModule(Int)
    }

    init(
        environment: AppEnvironment,
        keyboardMonitoringEnabled: Bool = !AppRuntime.isRunningTests,
        transitionTimings: FloatingToolbarTransitionTimings = .runtime,
        transitionScheduler: any FloatingToolbarTransitionScheduler = MainQueueFloatingToolbarTransitionScheduler(),
        layoutMetrics: FloatingToolbarLayoutMetrics = FloatingToolbarLayoutMetrics(),
        morphTicker: (any FloatingToolbarMorphTicker)? = nil,
        panel: FloatingToolbarPanel? = nil
    ) {
        self.environment = environment
        self.keyboardMonitoringEnabled = keyboardMonitoringEnabled
        self.transitionTimings = transitionTimings
        self.transitionScheduler = transitionScheduler
        self.layoutMetrics = layoutMetrics
        self.injectedMorphTicker = morphTicker
        self.panel = panel
        self.frameResolver = FloatingToolbarFrameResolver(metrics: layoutMetrics)
    }

    func show(for selection: TextSelection, source: FloatingToolbarPresentationSource) {
        processingSuccessWork?.cancel()
        processingSuccessWork = nil
        processingStatus = nil
        currentSelection = selection
        presentationSource = source
        presentationMode = Self.initialPresentationMode(for: source)
        transitionPhase = .idle
        isVisible = true

        cancelPendingTransitionWork()
        syncKeyboardMonitoring()
        renderPanel(showPanelIfNeeded: true)
    }

    func dismiss() {
        cancelPendingTransitionWork()
        morphDriver?.reset()
        processingSuccessWork?.cancel()
        processingSuccessWork = nil
        removeKeyboardMonitoring()
        panel?.dismiss()
        isVisible = false
        currentSelection = nil
        presentationMode = nil
        presentationSource = nil
        processingStatus = nil
        transitionPhase = .idle
    }

    func dismissFromUser() {
        onUserDismiss?()
        dismiss()
    }

    func beginProcessingIndicator(
        for selection: TextSelection,
        source: FloatingToolbarPresentationSource? = nil
    ) {
        cancelPendingTransitionWork()
        processingSuccessWork?.cancel()
        processingSuccessWork = nil
        currentSelection = selection
        presentationSource = source ?? presentationSource ?? .explicit
        presentationMode = nil
        processingStatus = .processing(canCancel: true)
        transitionPhase = .idle
        isVisible = true

        syncKeyboardMonitoring()
        renderPanel(showPanelIfNeeded: true)
    }

    func markProcessingReplacementStarted() {
        guard case .processing = processingStatus else { return }
        processingStatus = .processing(canCancel: false)
        syncKeyboardMonitoring()
        renderPanel(showPanelIfNeeded: false)
    }

    func showProcessingSuccess() {
        guard isVisible else { return }
        processingSuccessWork?.cancel()
        processingStatus = .success
        syncKeyboardMonitoring()
        renderPanel(showPanelIfNeeded: false)

        processingSuccessWork = transitionScheduler.schedule(
            after: Self.processingSuccessDismissDelay
        ) { [weak self] in
            guard let self,
                  self.processingStatus == .success else { return }
            self.dismiss()
            self.onProcessingIndicatorFinished?()
        }
    }

    func dismissProcessingIndicator() {
        guard processingStatus != nil else { return }
        dismiss()
    }

    func dismissForSelectionChange() {
        guard processingStatus == nil else { return }
        dismiss()
    }

    func refreshAppearance() {
        guard isVisible else { return }
        renderPanel(showPanelIfNeeded: false)
    }

    func handleExplicitTriggerIfVisible() -> Bool {
        guard isVisible else { return false }

        if processingStatus != nil {
            return true
        }

        switch presentationMode {
        case .compact:
            expandToolbar()
        case .expanded:
            dismissFromUser()
        case nil:
            return false
        }

        return true
    }

    func invokeModule(_ module: any TextModule) {
        guard let selection = currentSelection else { return }
        let keepPresented = onModuleInvoked?(module, selection) == true
        if !keepPresented {
            dismiss()
        }
    }

    func handleCompactTriggerHoverChanged(_ hovering: Bool) {
        guard isVisible, presentationMode == .compact else { return }

        if hovering {
            scheduleExpand()
        } else {
            pendingExpandWork?.cancel()
            pendingExpandWork = nil
        }
    }

    func handleExpandedHoverChanged(_ hovering: Bool) {
        guard isVisible, presentationMode == .expanded else { return }

        if hovering {
            pendingCollapseWork?.cancel()
            pendingCollapseWork = nil

            // Re-entering while the panel is already collapsing reverses it from where it is.
            if transitionPhase == .collapsing {
                expandToolbar()
            }
            return
        }

        // A hover exit that lands mid-morph must still schedule the collapse; the morph driver
        // reverses from the current interpolated size instead of snapping.
        guard presentationSource == .autoDetect else { return }
        scheduleCollapse()
    }

    func handleCompactTriggerActivation() {
        expandToolbar()
    }

    // MARK: - Keyboard Navigation

    private static let keyboardEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let viewModel = Unmanaged<FloatingToolbarViewModel>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated {
                viewModel.reenableKeyboardEventTap()
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCodeValue = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCodeValue >= 0, keyCodeValue <= Int64(UInt16.max) else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(keyCodeValue)
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        guard Thread.isMainThread else {
            return Unmanaged.passUnretained(event)
        }

        let consumed = MainActor.assumeIsolated {
            viewModel.handleKeyValues(keyCode: keyCode, modifiers: modifiers)
        }
        return consumed ? nil : Unmanaged.passUnretained(event)
    }

    func handleKeyValues(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard isVisible else { return false }

        if let processingStatus {
            guard case .processing(canCancel: true) = processingStatus,
                  keyCode == UInt16(kVK_Escape) else {
                return false
            }
            onProcessingCancel?()
            return true
        }

        guard presentationMode == .expanded else { return false }
        let modules = environment.moduleRegistry.activeModules

        guard let action = Self.keyboardAction(
            keyCode: keyCode,
            modifiers: modifiers,
            moduleCount: modules.count
        ) else {
            return false
        }

        switch action {
        case .dismiss:
            dismissFromUser()
            return true
        case .invokeModule(let moduleIndex):
            invokeModule(modules[moduleIndex])
            return true
        }
    }

    static func initialPresentationMode(for source: FloatingToolbarPresentationSource) -> FloatingToolbarPresentationMode {
        switch source {
        case .autoDetect:
            .compact
        case .explicit:
            .expanded
        }
    }

    static func keyboardAction(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        moduleCount: Int
    ) -> KeyboardAction? {
        if keyCode == UInt16(kVK_Escape) {
            return .dismiss
        }

        guard let moduleIndex = moduleIndexForShortcut(
            keyCode: keyCode,
            modifiers: modifiers
        ), moduleIndex < moduleCount else {
            return nil
        }

        return .invokeModule(moduleIndex)
    }

    static func moduleIndexForShortcut(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Int? {
        let normalized = modifiers.intersection(.deviceIndependentFlagsMask)
        guard normalized == [.command],
              let digit = commandDigitMap[keyCode] else {
            return nil
        }
        return digit - 1
    }

    // MARK: - Private

    private func ensurePanel() {
        if panel == nil {
            panel = FloatingToolbarPanel()
        }

        panel?.onEscape = { [weak self] in self?.handleEscape() }
        panel?.onKeyEvent = { [weak self] keyCode, modifiers in
            self?.handleKeyValues(keyCode: keyCode, modifiers: modifiers) ?? false
        }

        if hostingView == nil {
            let view = NSHostingView(rootView: makeRootView())
            // The morph resizes the window every tick; autoresizing makes the hosted SwiftUI
            // content follow in lockstep, which is what keeps the rounded right cap on screen.
            view.autoresizingMask = [.width, .height]
            hostingView = view
            panel?.contentView = view
        }

        if morphDriver == nil {
            let ticker = injectedMorphTicker
                ?? DisplayLinkMorphTicker(viewProvider: { [weak self] in self?.hostingView })
            morphDriver = FloatingToolbarMorphDriver(ticker: ticker)
        }
    }

    private func makeRootView() -> FloatingToolbarPanelContentView {
        FloatingToolbarPanelContentView(
            theme: currentTheme(),
            layout: layoutMetrics,
            mode: presentationMode ?? .expanded,
            transitionPhase: transitionPhase,
            processingStatus: processingStatus,
            modules: displayedModules,
            onCompactHoverChanged: { [weak self] hovering in
                self?.handleCompactTriggerHoverChanged(hovering)
            },
            onCompactActivate: { [weak self] in
                self?.handleCompactTriggerActivation()
            },
            onExpandedHoverChanged: { [weak self] hovering in
                self?.handleExpandedHoverChanged(hovering)
            },
            onModuleSelected: { [weak self] module in
                self?.invokeModule(module)
            },
            onProcessingCancel: { [weak self] in
                self?.onProcessingCancel?()
            },
            onDismiss: { [weak self] in
                self?.dismissFromUser()
            }
        )
    }

    private func renderPanel(showPanelIfNeeded: Bool) {
        displayedModules = environment.moduleRegistry.activeModules
        ensurePanel()
        guard let panel, let hostingView else { return }

        hostingView.rootView = makeRootView()

        // A running morph owns the geometry; only the hosted content is refreshed under it.
        guard morphDriver?.isRunning != true,
              let placement = currentPlacement() else {
            return
        }

        morphDriver?.reset(to: placement.contentRect.size)

        if showPanelIfNeeded {
            panel.show(contentRect: placement.contentRect)
            return
        }

        panel.update(contentRect: placement.contentRect)
    }

    private func resolvedScreen(for selection: TextSelection) -> NSScreen? {
        let screens = NSScreen.screens
        if let index = NSScreen.toolbarScreenIndex(
            selectionBounds: selection.selectionBounds,
            cursorPosition: selection.cursorPosition,
            screenFrames: screens.map(\.frame)
        ) {
            return screens[index]
        }

        // Recover only when neither captured input belongs to an available screen.
        let liveCursorPosition = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(liveCursorPosition) }
            ?? NSScreen.main
            ?? screens.first
    }

    private func currentPlacement() -> FloatingToolbarPlacement? {
        guard let selection = currentSelection,
              let presentationSource,
              let screen = resolvedScreen(for: selection) else {
            return nil
        }

        if processingStatus != nil {
            return frameResolver.resolveProcessingIndicator(
                source: presentationSource,
                selectionBounds: selection.selectionBounds,
                cursorPosition: selection.cursorPosition,
                screenFrame: screen.visibleFrame
            )
        }

        guard let presentationMode else { return nil }
        return frameResolver.resolve(
            source: presentationSource,
            mode: presentationMode,
            selectionBounds: selection.selectionBounds,
            cursorPosition: selection.cursorPosition,
            moduleCount: displayedModules.count,
            screenFrame: screen.visibleFrame
        )
    }

    private func currentTheme() -> SelectionUITheme {
        SelectionUITheme(style: UserDefaults.standard.selectionTriggerStyle)
    }

    private func expandToolbar() {
        guard isVisible else { return }
        // A collapse already in flight can be reversed straight back into an expansion.
        guard presentationMode != .expanded || transitionPhase == .collapsing else { return }

        pendingExpandWork?.cancel()
        pendingExpandWork = nil
        pendingCollapseWork?.cancel()
        pendingCollapseWork = nil

        presentationMode = .expanded
        transitionPhase = .expanding
        syncKeyboardMonitoring()
        displayedModules = environment.moduleRegistry.activeModules
        hostingView?.rootView = makeRootView()

        runMorph(
            fallbackStart: layoutMetrics.compactSizeValue,
            target: expandedTargetSize,
            duration: transitionTimings.expandDuration,
            widthRange: transitionTimings.expandWidthRange,
            heightRange: transitionTimings.expandHeightRange,
            widthCurve: FloatingToolbarAnimationCurves.openSecondaryBezier,
            heightCurve: FloatingToolbarAnimationCurves.openPrimaryBezier
        ) { [weak self] in
            guard let self,
                  self.isVisible,
                  self.presentationMode == .expanded,
                  self.transitionPhase == .expanding else {
                return
            }
            self.transitionPhase = .idle
            self.hostingView?.rootView = self.makeRootView()
            self.panel?.settleShadow()
        }
    }

    private func collapseToolbar() {
        guard isVisible,
              presentationMode == .expanded,
              presentationSource == .autoDetect else { return }

        pendingCollapseWork?.cancel()
        pendingCollapseWork = nil

        transitionPhase = .collapsing
        displayedModules = environment.moduleRegistry.activeModules
        hostingView?.rootView = makeRootView()

        runMorph(
            fallbackStart: expandedTargetSize,
            target: layoutMetrics.compactSizeValue,
            duration: transitionTimings.collapseDuration,
            widthRange: transitionTimings.collapseWidthRange,
            heightRange: transitionTimings.collapseHeightRange,
            widthCurve: FloatingToolbarAnimationCurves.closePrimaryBezier,
            heightCurve: FloatingToolbarAnimationCurves.closePrimaryBezier
        ) { [weak self] in
            guard let self,
                  self.isVisible,
                  self.presentationSource == .autoDetect,
                  self.transitionPhase == .collapsing else {
                return
            }
            self.presentationMode = .compact
            self.transitionPhase = .idle
            self.syncKeyboardMonitoring()
            self.hostingView?.rootView = self.makeRootView()
            self.panel?.settleShadow()
        }
    }

    private var expandedTargetSize: CGSize {
        layoutMetrics.expandedSize(
            moduleCount: displayedModules.count
        )
    }

    private func runMorph(
        fallbackStart: CGSize,
        target: CGSize,
        duration: TimeInterval,
        widthRange: ClosedRange<Double>,
        heightRange: ClosedRange<Double>,
        widthCurve: UnitBezier,
        heightCurve: UnitBezier,
        onFinish: @escaping @MainActor () -> Void
    ) {
        guard let morphDriver else { return }

        morphDriver.morph(
            fallbackStart: fallbackStart,
            target: target,
            duration: duration,
            widthRange: widthRange,
            heightRange: heightRange,
            widthCurve: widthCurve,
            heightCurve: heightCurve,
            onTick: { [weak self] size in
                self?.applyMorphSize(size)
            },
            onFinish: onFinish
        )
    }

    /// Places one interpolated size. Resolving through the frame resolver on every tick keeps
    /// screen-edge clamping and mirroring correct while the panel is still in motion.
    private func applyMorphSize(_ size: CGSize) {
        guard let panel,
              let selection = currentSelection,
              let presentationSource,
              let screen = resolvedScreen(for: selection) else {
            return
        }

        let placement = frameResolver.resolve(
            source: presentationSource,
            size: size,
            selectionBounds: selection.selectionBounds,
            cursorPosition: selection.cursorPosition,
            screenFrame: screen.visibleFrame
        )

        panel.setContentFrameImmediately(placement.contentRect)
    }

    private func scheduleExpand() {
        pendingCollapseWork?.cancel()
        pendingCollapseWork = nil
        pendingExpandWork?.cancel()

        pendingExpandWork = transitionScheduler.schedule(
            after: transitionTimings.compactExpandDelay
        ) { [weak self] in
            self?.pendingExpandWork = nil
            self?.expandToolbar()
        }
    }

    private func scheduleCollapse() {
        pendingExpandWork?.cancel()
        pendingExpandWork = nil
        pendingCollapseWork?.cancel()

        pendingCollapseWork = transitionScheduler.schedule(
            after: transitionTimings.expandedCollapseDelay
        ) { [weak self] in
            self?.pendingCollapseWork = nil
            self?.collapseToolbar()
        }
    }

    private func cancelPendingTransitionWork() {
        pendingExpandWork?.cancel()
        pendingExpandWork = nil
        pendingCollapseWork?.cancel()
        pendingCollapseWork = nil
        morphDriver?.cancel()
    }

    private func syncKeyboardMonitoring() {
        if presentationMode == .expanded
            || (processingStatus == .processing(canCancel: true)) {
            installKeyboardMonitoring()
        } else {
            removeKeyboardMonitoring()
        }
    }

    private func handleEscape() {
        if case .processing(canCancel: true) = processingStatus {
            onProcessingCancel?()
            return
        }

        guard processingStatus == nil else { return }
        dismissFromUser()
    }

    private func installKeyboardMonitoring() {
        guard keyboardMonitoringEnabled else { return }
        guard keyboardEventTap == nil,
              globalKeyMonitor == nil,
              localKeyMonitor == nil else { return }

        if installKeyboardEventTap() {
            return
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in
                _ = self?.handleKeyValues(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags
                )
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated {
                self.handleKeyValues(
                    keyCode: event.keyCode,
                    modifiers: event.modifierFlags
                )
            }
            return consumed ? nil : event
        }
    }

    private func installKeyboardEventTap() -> Bool {
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.keyboardEventTapCallback,
            userInfo: userInfo
        ) else {
            Log.hotkeys.warning("Floating toolbar keyboard event tap unavailable, using NSEvent monitors")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            Log.hotkeys.warning("Floating toolbar keyboard event tap source unavailable, using NSEvent monitors")
            return false
        }

        keyboardEventTap = eventTap
        keyboardEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private func reenableKeyboardEventTap() {
        guard let keyboardEventTap else { return }
        CGEvent.tapEnable(tap: keyboardEventTap, enable: true)
    }

    private func removeKeyboardMonitoring() {
        if let keyboardEventTap {
            CGEvent.tapEnable(tap: keyboardEventTap, enable: false)
            CFMachPortInvalidate(keyboardEventTap)
            self.keyboardEventTap = nil
        }

        if let keyboardEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), keyboardEventTapSource, .commonModes)
            self.keyboardEventTapSource = nil
        }

        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }

        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }
}

@MainActor
/// Live geometry of the panel surface, derived from the size the window currently has.
///
/// Deriving both the reveal progress and the corner radius from one live size is what removes the
/// single-frame radius jump the staged morph had at the vertical -> horizontal boundary.
struct FloatingToolbarSurfaceGeometry {
    let revealProgress: Double
    let cornerRadius: CGFloat

    init(
        containerSize: CGSize,
        theme: SelectionUITheme,
        layout: FloatingToolbarLayoutMetrics,
        moduleCount: Int
    ) {
        revealProgress = FloatingToolbarContentReveal.revealProgress(
            containerWidth: containerSize.width,
            compactWidth: layout.compactInteractiveSize,
            expandedWidth: layout.expandedWidth(moduleCount: moduleCount)
        )

        let capsuleRadius = min(containerSize.width, containerSize.height) / 2
        cornerRadius = capsuleRadius
            + ((theme.expandedCornerRadius - capsuleRadius) * CGFloat(revealProgress))
    }

    var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

private struct FloatingToolbarPanelContentView: View {
    let theme: SelectionUITheme
    let layout: FloatingToolbarLayoutMetrics
    let mode: FloatingToolbarPresentationMode
    let transitionPhase: FloatingToolbarTransitionPhase
    let processingStatus: FloatingToolbarProcessingStatus?
    let modules: [any TextModule]
    let onCompactHoverChanged: (Bool) -> Void
    let onCompactActivate: () -> Void
    let onExpandedHoverChanged: (Bool) -> Void
    let onModuleSelected: (any TextModule) -> Void
    let onProcessingCancel: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    private var usesCompactInteraction: Bool {
        processingStatus == nil && mode == .compact && transitionPhase == .idle
    }

    private var isSettledExpanded: Bool {
        processingStatus == nil && mode == .expanded && transitionPhase == .idle
    }

    var body: some View {
        // The window drives the size; the content reads it back rather than being told up front.
        GeometryReader { proxy in
            let geometry = FloatingToolbarSurfaceGeometry(
                containerSize: proxy.size,
                theme: theme,
                layout: layout,
                moduleCount: modules.count
            )

            FloatingToolbarSurfaceView(
                theme: theme,
                layout: layout,
                containerSize: proxy.size,
                geometry: geometry,
                isHovered: isHovered,
                usesCompactInteraction: usesCompactInteraction,
                isSettledExpanded: isSettledExpanded,
                processingStatus: processingStatus,
                modules: modules,
                onModuleSelected: onModuleSelected,
                onProcessingCancel: onProcessingCancel,
                onDismiss: onDismiss
            )
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .contentShape(geometry.shape)
            .onHover { hovering in
                isHovered = hovering
                if processingStatus != nil {
                    return
                }

                if usesCompactInteraction {
                    onCompactHoverChanged(hovering)
                } else {
                    onExpandedHoverChanged(hovering)
                }
            }
            .onTapGesture {
                guard processingStatus == nil,
                      usesCompactInteraction else { return }
                onCompactActivate()
            }
        }
    }
}

private struct FloatingToolbarSurfaceView: View {
    private static let toolbarGlassEffectID = "floating-toolbar-surface"

    let theme: SelectionUITheme
    let layout: FloatingToolbarLayoutMetrics
    let containerSize: CGSize
    let geometry: FloatingToolbarSurfaceGeometry
    let isHovered: Bool
    let usesCompactInteraction: Bool
    let isSettledExpanded: Bool
    let processingStatus: FloatingToolbarProcessingStatus?
    let modules: [any TextModule]
    let onModuleSelected: (any TextModule) -> Void
    let onProcessingCancel: () -> Void
    let onDismiss: () -> Void

    @Namespace private var toolbarGlassNamespace

    private var revealProgress: Double { geometry.revealProgress }

    private var containerShape: RoundedRectangle { geometry.shape }

    private var usesCompactChrome: Bool { usesCompactInteraction }

    /// Buttons only take clicks once the row has fully arrived, so a click landing mid-morph
    /// cannot hit a half-faded control.
    private var toolbarButtonsEnabled: Bool {
        isSettledExpanded && revealProgress > 0.99
    }

    private var mountsToolbarContent: Bool {
        FloatingToolbarContentReveal.mountsToolbarContent(
            revealProgress: revealProgress,
            isSettledExpanded: isSettledExpanded,
            processingStatus: processingStatus
        )
    }

    private var surfaceTreatment: FloatingToolbarSurfaceTreatment {
        FloatingToolbarSurfaceTreatment.resolve(style: theme.style)
    }

    var body: some View {
        surfaceContent
    }

    @ViewBuilder
    private var surfaceContent: some View {
        #if compiler(>=6.2)
        if surfaceTreatment == .nativeLiquidGlass {
            if #available(macOS 26.0, *) {
                nativeLiquidGlassSurface
            } else {
                fallbackChromeSurface
            }
        } else {
            fallbackChromeSurface
        }
        #else
        fallbackChromeSurface
        #endif
    }

    private var fallbackChromeSurface: some View {
        ZStack(alignment: .leading) {
            fallbackChrome
            sharedInnerContent
        }
    }

    private var fallbackChrome: some View {
        ZStack {
            containerShape
                .fill(usesCompactChrome ? theme.compactBackground : theme.expandedBackground)

            containerShape
                .strokeBorder(
                    usesCompactChrome ? theme.compactStrokeColor : theme.toolbarStrokeColor,
                    lineWidth: 1
            )
        }
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private var nativeLiquidGlassSurface: some View {
        GlassEffectContainer {
            sharedInnerContent
                .frame(width: containerSize.width, height: containerSize.height, alignment: .leading)
                .glassEffect(.regular.interactive(), in: containerShape)
                .glassEffectID(Self.toolbarGlassEffectID, in: toolbarGlassNamespace)
        }
    }
    #endif

    @ViewBuilder
    private var sharedInnerContent: some View {
        ZStack(alignment: .leading) {
            if let processingStatus {
                FloatingToolbarProcessingStatusView(
                    theme: theme,
                    status: processingStatus,
                    onCancel: onProcessingCancel
                )
                .frame(width: containerSize.width, height: containerSize.height)
            } else {
                // Seed and toolbar row are mounted together so the morph can crossfade them;
                // mutually exclusive branches made a crossfade structurally impossible.
                SelectionTriggerSeedView(
                    theme: theme,
                    isHovered: isHovered && usesCompactInteraction,
                    showsBadge: usesCompactInteraction,
                    drawsSurfaceChrome: surfaceTreatment == .fallbackChrome
                )
                .frame(
                    width: layout.compactInteractiveSize,
                    height: containerSize.height,
                    alignment: .center
                )
                .opacity(FloatingToolbarContentReveal.seedOpacity(revealProgress: revealProgress))
                .allowsHitTesting(false)

                if mountsToolbarContent {
                    FloatingToolbarView(
                        theme: theme,
                        modules: modules,
                        revealProgress: revealProgress,
                        onModuleSelected: onModuleSelected,
                        onDismiss: onDismiss
                    )
                    .padding(.horizontal, layout.toolbarHorizontalPadding)
                    .padding(.vertical, layout.toolbarVerticalPadding)
                    .frame(
                        width: containerSize.width,
                        height: containerSize.height,
                        alignment: .leading
                    )
                    .opacity(
                        FloatingToolbarContentReveal.toolbarOpacity(revealProgress: revealProgress)
                    )
                    .clipped()
                    .allowsHitTesting(toolbarButtonsEnabled)
                }
            }
        }
    }
}

@MainActor
private struct FloatingToolbarProcessingStatusView: View {
    let theme: SelectionUITheme
    let status: FloatingToolbarProcessingStatus
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            switch status {
            case .processing(let canCancel):
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.toolbarGlyphColor)

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .foregroundStyle(theme.toolbarGlyphColor)
                }
                .buttonStyle(.plain)
                .disabled(!canCancel)
                .opacity(canCancel ? 1 : 0.35)
                .help(canCancel ? "Cancel automatic replacement (Esc)" : "Replacement in progress")
            case .success:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.toolbarGlyphColor)
                    .frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, DS.Spacing.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}
