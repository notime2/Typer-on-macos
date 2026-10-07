// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import CoreGraphics
import Foundation

struct SelectedScreenRegion: Sendable, Equatable {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let selectionRect: CGRect
}

struct ScreenshotPixelDimensions: Sendable, Equatable {
    let width: Int
    let height: Int
}

enum ScreenRegionGeometry {
    static let minimumDimension: CGFloat = 4

    static func normalizedSelection(
        from startPoint: CGPoint,
        to endPoint: CGPoint,
        in screenFrame: CGRect
    ) -> CGRect? {
        guard isFinite(screenFrame), screenFrame.width > 0, screenFrame.height > 0 else {
            return nil
        }

        let start = clamped(startPoint, to: screenFrame)
        let end = clamped(endPoint, to: screenFrame)
        let selection = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )

        guard selection.width >= minimumDimension,
              selection.height >= minimumDimension else {
            return nil
        }
        return selection
    }

    static func sourceRect(
        for selectionRect: CGRect,
        in screenFrame: CGRect
    ) -> CGRect? {
        guard isFinite(selectionRect), isFinite(screenFrame) else { return nil }

        let clippedSelection = selectionRect.standardized.intersection(screenFrame)
        guard !clippedSelection.isNull,
              clippedSelection.width > 0,
              clippedSelection.height > 0 else {
            return nil
        }

        return CGRect(
            x: clippedSelection.minX - screenFrame.minX,
            y: screenFrame.maxY - clippedSelection.maxY,
            width: clippedSelection.width,
            height: clippedSelection.height
        )
    }

    static func pixelDimensions(
        for rect: CGRect,
        pointPixelScale: CGFloat
    ) -> ScreenshotPixelDimensions? {
        guard isFinite(rect),
              pointPixelScale.isFinite,
              rect.width > 0,
              rect.height > 0,
              pointPixelScale > 0 else {
            return nil
        }

        let pixelWidth = (rect.width * pointPixelScale).rounded(.up)
        let pixelHeight = (rect.height * pointPixelScale).rounded(.up)
        guard pixelWidth.isFinite,
              pixelHeight.isFinite,
              pixelWidth > 0,
              pixelHeight > 0,
              pixelWidth <= CGFloat(Int.max),
              pixelHeight <= CGFloat(Int.max) else {
            return nil
        }

        return ScreenshotPixelDimensions(
            width: Int(pixelWidth),
            height: Int(pixelHeight)
        )
    }

    private static func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
    }
}

@MainActor
protocol ScreenRegionSelecting: AnyObject {
    func selectRegion() async throws -> SelectedScreenRegion?
}

enum ScreenRegionSelectionError: LocalizedError, Sendable, Equatable {
    case displayUnavailable

    var errorDescription: String? {
        "Could not prepare the available displays for area selection."
    }
}

struct ScreenRegionOverlayScreen: Sendable, Equatable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
}

@MainActor
protocol ScreenRegionOverlayPanel: AnyObject {
    var frame: CGRect { get }

    func present()
    func focus()
    func dismissSelection()
}

@MainActor
protocol ScreenRegionOverlayEnvironment: AnyObject {
    var mouseLocation: CGPoint { get }

    func availableScreens() throws -> [ScreenRegionOverlayScreen]
    func makePanel(
        for screen: ScreenRegionOverlayScreen,
        onComplete: @escaping (SelectedScreenRegion?) -> Void
    ) -> any ScreenRegionOverlayPanel
    func activateApplication()
    func startObservingCancellation(_ handler: @escaping () -> Void)
    func stopObservingCancellation()
}

@MainActor
protocol ScreenRegionSelectionOverlayCoordinating: AnyObject {
    func beginSelection(
        onComplete: @escaping (SelectedScreenRegion?) -> Void
    ) throws
    func endSelection()
}

@MainActor
final class ScreenRegionSelectionController: ScreenRegionSelecting {
    private let overlayCoordinator: any ScreenRegionSelectionOverlayCoordinating
    private var activeSelectionID: UUID?
    private var continuation: CheckedContinuation<SelectedScreenRegion?, Error>?

    init(
        overlayCoordinator: (any ScreenRegionSelectionOverlayCoordinating)? = nil
    ) {
        self.overlayCoordinator = overlayCoordinator ?? ScreenRegionSelectionOverlayCoordinator()
    }

    func selectRegion() async throws -> SelectedScreenRegion? {
        guard continuation == nil, !Task.isCancelled else { return nil }
        let selectionID = UUID()

        do {
            let selection = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    beginSelection(id: selectionID, continuation: continuation)
                    if Task.isCancelled {
                        finish(id: selectionID, with: .success(nil))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.finish(id: selectionID, with: .success(nil))
                }
            }

            return Task.isCancelled ? nil : selection
        } catch {
            if Task.isCancelled { return nil }
            throw error
        }
    }

    private func beginSelection(
        id: UUID,
        continuation: CheckedContinuation<SelectedScreenRegion?, Error>
    ) {
        activeSelectionID = id
        self.continuation = continuation
        do {
            try overlayCoordinator.beginSelection { [weak self] selection in
                self?.finish(id: id, with: .success(selection))
            }
        } catch {
            finish(id: id, with: .failure(error))
        }
    }

    private func finish(
        id: UUID,
        with result: Result<SelectedScreenRegion?, Error>
    ) {
        guard activeSelectionID == id, let continuation else { return }
        activeSelectionID = nil
        self.continuation = nil
        overlayCoordinator.endSelection()
        continuation.resume(with: result)
    }
}

@MainActor
final class ScreenRegionSelectionOverlayCoordinator: ScreenRegionSelectionOverlayCoordinating {
    private let environment: any ScreenRegionOverlayEnvironment
    private var panels: [any ScreenRegionOverlayPanel] = []
    private var activeSelectionID: UUID?
    private var onComplete: ((SelectedScreenRegion?) -> Void)?

    init(environment: (any ScreenRegionOverlayEnvironment)? = nil) {
        self.environment = environment ?? AppKitScreenRegionOverlayEnvironment()
    }

    func beginSelection(
        onComplete: @escaping (SelectedScreenRegion?) -> Void
    ) throws {
        guard self.onComplete == nil, panels.isEmpty else {
            throw ScreenRegionSelectionError.displayUnavailable
        }

        let screens = try environment.availableScreens()
        guard !screens.isEmpty else { throw ScreenRegionSelectionError.displayUnavailable }

        let selectionID = UUID()
        activeSelectionID = selectionID
        self.onComplete = onComplete
        environment.startObservingCancellation { [weak self] in
            self?.complete(id: selectionID, with: nil)
        }
        panels = screens.map { screen in
            environment.makePanel(for: screen) { [weak self] selection in
                self?.complete(id: selectionID, with: selection)
            }
        }

        environment.activateApplication()
        panels.forEach { $0.present() }

        let mouseLocation = environment.mouseLocation
        let targetPanel = panels.first {
            $0.frame.contains(mouseLocation)
        } ?? panels.first
        targetPanel?.focus()
    }

    func endSelection() {
        guard onComplete != nil || !panels.isEmpty else { return }
        activeSelectionID = nil
        onComplete = nil
        environment.stopObservingCancellation()
        let activePanels = panels
        panels.removeAll()
        activePanels.forEach { $0.dismissSelection() }
    }

    private func complete(id: UUID, with selection: SelectedScreenRegion?) {
        guard activeSelectionID == id else { return }
        onComplete?(selection)
    }
}

@MainActor
private final class AppKitScreenRegionOverlayEnvironment:
    NSObject,
    ScreenRegionOverlayEnvironment
{
    private var cancellationHandler: (() -> Void)?
    private var isObservingApplication = false

    var mouseLocation: CGPoint { NSEvent.mouseLocation }

    func availableScreens() throws -> [ScreenRegionOverlayScreen] {
        let screens = NSScreen.screens
        let descriptors = screens.compactMap { screen -> ScreenRegionOverlayScreen? in
            guard let displayID = Self.displayID(for: screen) else { return nil }
            return ScreenRegionOverlayScreen(displayID: displayID, frame: screen.frame)
        }
        let uniqueDisplayIDs = Set(descriptors.map(\.displayID))
        guard !screens.isEmpty,
              descriptors.count == screens.count,
              uniqueDisplayIDs.count == descriptors.count else {
            throw ScreenRegionSelectionError.displayUnavailable
        }
        return descriptors
    }

    func makePanel(
        for screen: ScreenRegionOverlayScreen,
        onComplete: @escaping (SelectedScreenRegion?) -> Void
    ) -> any ScreenRegionOverlayPanel {
        ScreenRegionSelectionPanel(screen: screen, onComplete: onComplete)
    }

    func activateApplication() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func startObservingCancellation(_ handler: @escaping () -> Void) {
        guard !isObservingApplication else { return }
        cancellationHandler = handler
        isObservingApplication = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
    }

    func stopObservingCancellation() {
        guard isObservingApplication else { return }
        isObservingApplication = false
        cancellationHandler = nil
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
    }

    @objc private func applicationDidResignActive() {
        cancellationHandler?()
    }

    @objc private func screenParametersDidChange() {
        cancellationHandler?()
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}

@MainActor
private final class ScreenRegionSelectionPanel: NSPanel, ScreenRegionOverlayPanel {
    private var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    init(
        screen: ScreenRegionOverlayScreen,
        onComplete: @escaping (SelectedScreenRegion?) -> Void
    ) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovable = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        onCancel = { onComplete(nil) }
        contentView = ScreenRegionSelectionView(
            frame: CGRect(origin: .zero, size: screen.frame.size),
            screenFrame: screen.frame,
            displayID: screen.displayID,
            onComplete: onComplete
        )
    }

    func present() {
        orderFrontRegardless()
    }

    func focus() {
        makeKeyAndOrderFront(nil)
        if let contentView {
            makeFirstResponder(contentView)
        }
    }

    func dismissSelection() {
        onCancel = nil
        if let selectionView = contentView as? ScreenRegionSelectionView {
            selectionView.onComplete = nil
        }
        orderOut(nil)
        contentView = nil
        close()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class ScreenRegionSelectionView: NSView {
    private let screenFrame: CGRect
    private let displayID: CGDirectDisplayID
    fileprivate var onComplete: ((SelectedScreenRegion?) -> Void)?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    init(
        frame frameRect: NSRect,
        screenFrame: CGRect,
        displayID: CGDirectDisplayID,
        onComplete: @escaping (SelectedScreenRegion?) -> Void
    ) {
        self.screenFrame = screenFrame
        self.displayID = displayID
        self.onComplete = onComplete
        super.init(frame: frameRect)
        setAccessibilityLabel("Select screenshot area")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = clampedLocalPoint(event.locationInWindow)
        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragCurrent = clampedLocalPoint(event.locationInWindow)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStart else {
            onComplete?(nil)
            return
        }

        let dragEnd = clampedLocalPoint(event.locationInWindow)
        let globalStart = CGPoint(
            x: screenFrame.minX + dragStart.x,
            y: screenFrame.minY + dragStart.y
        )
        let globalEnd = CGPoint(
            x: screenFrame.minX + dragEnd.x,
            y: screenFrame.minY + dragEnd.y
        )
        let selectionRect = ScreenRegionGeometry.normalizedSelection(
            from: globalStart,
            to: globalEnd,
            in: screenFrame
        )

        self.dragStart = nil
        dragCurrent = nil
        needsDisplay = true

        guard let selectionRect else {
            onComplete?(nil)
            return
        }
        onComplete?(
            SelectedScreenRegion(
                displayID: displayID,
                screenFrame: screenFrame,
                selectionRect: selectionRect
            )
        )
    }

    override func rightMouseDown(with event: NSEvent) {
        onComplete?(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let selection = localSelectionRect
        let dimmedArea = NSBezierPath(rect: bounds)
        if !selection.isEmpty {
            dimmedArea.appendRect(selection)
            dimmedArea.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.38).setFill()
        dimmedArea.fill()

        guard !selection.isEmpty else { return }

        let outline = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
        outline.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
    }

    private var localSelectionRect: CGRect {
        guard let dragStart, let dragCurrent else { return .zero }
        let rect = CGRect(
            x: min(dragStart.x, dragCurrent.x),
            y: min(dragStart.y, dragCurrent.y),
            width: abs(dragCurrent.x - dragStart.x),
            height: abs(dragCurrent.y - dragStart.y)
        )
        return rect.intersection(bounds)
    }

    private func clampedLocalPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}
