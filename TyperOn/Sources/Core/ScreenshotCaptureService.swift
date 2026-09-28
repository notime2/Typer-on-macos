// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CapturedScreenshot: Sendable, Equatable {
    let pngData: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ScreenshotCaptureMode: Sendable, Equatable {
    case area
    case windowOrDisplay
}

enum ScreenshotWindowRestoreAction: Sendable, Equatable {
    case none
    case orderFront
    case makeKeyAndOrderFront
}

@MainActor
protocol ScreenshotCapturing {
    func captureScreenshot(mode: ScreenshotCaptureMode) async throws -> CapturedScreenshot?
}

enum ScreenshotCaptureError: LocalizedError, Sendable, Equatable {
    case captureAlreadyInProgress
    case pickerFailed(String)
    case permissionDenied
    case displayUnavailable
    case currentApplicationUnavailable
    case invalidCaptureDimensions
    case captureFailed(String)
    case pngEncodingFailed
    case invalidPNGData

    var errorDescription: String? {
        switch self {
        case .captureAlreadyInProgress:
            return "A screenshot capture is already in progress."
        case .pickerFailed(let description):
            return "Could not open the screenshot picker: \(description)"
        case .permissionDenied:
            return "Screen Recording permission is required to take a screenshot."
        case .displayUnavailable:
            return "The selected display is no longer available."
        case .currentApplicationUnavailable:
            return "Could not exclude Typer On from the screenshot."
        case .invalidCaptureDimensions:
            return "The selected content has an invalid size."
        case .captureFailed(let description):
            return "Could not capture the screenshot: \(description)"
        case .pngEncodingFailed:
            return "Could not encode the screenshot as PNG."
        case .invalidPNGData:
            return "The captured screenshot contains invalid PNG data."
        }
    }
}

private final class SendableContentFilter: @unchecked Sendable {
    let value: SCContentFilter

    init(_ value: SCContentFilter) {
        self.value = value
    }
}

@MainActor
protocol ScreenshotContentSharingPicker: AnyObject {
    var defaultConfiguration: SCContentSharingPickerConfiguration { get set }
    var isActive: Bool { get set }

    func add(_ observer: any SCContentSharingPickerObserver)
    func remove(_ observer: any SCContentSharingPickerObserver)
    func present()
}

extension SCContentSharingPicker: ScreenshotContentSharingPicker {}

@MainActor
protocol ScreenshotCaptureWindow: AnyObject {
    var screenshotIsVisible: Bool { get }
    var screenshotIsKeyWindow: Bool { get }
    var screenshotWindowNumber: Int { get }

    func hideForScreenshot()
    func orderFrontAfterScreenshot()
    func makeKeyAndOrderFrontAfterScreenshot()
}

extension NSWindow: ScreenshotCaptureWindow {
    var screenshotIsVisible: Bool { isVisible }
    var screenshotIsKeyWindow: Bool { isKeyWindow }
    var screenshotWindowNumber: Int { windowNumber }

    func hideForScreenshot() {
        orderOut(nil)
    }

    func orderFrontAfterScreenshot() {
        orderFront(nil)
    }

    func makeKeyAndOrderFrontAfterScreenshot() {
        makeKeyAndOrderFront(nil)
    }
}

@MainActor
protocol ScreenshotCaptureWindowEnvironment: AnyObject {
    var initiatingWindow: (any ScreenshotCaptureWindow)? { get }
    var isApplicationActive: Bool { get }

    func activateApplication()
}

@MainActor
private final class AppKitScreenshotCaptureWindowEnvironment:
    ScreenshotCaptureWindowEnvironment
{
    var initiatingWindow: (any ScreenshotCaptureWindow)? {
        NSApp.keyWindow ?? NSApp.mainWindow
    }

    var isApplicationActive: Bool { NSApp.isActive }

    func activateApplication() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class ScreenshotCaptureWindowSnapshot: @unchecked Sendable {
    weak var window: (any ScreenshotCaptureWindow)?
    let wasVisible: Bool
    let wasKey: Bool
    let windowNumber: Int?

    init(window: (any ScreenshotCaptureWindow)?) {
        self.window = window
        self.wasVisible = window?.screenshotIsVisible == true
        self.wasKey = window?.screenshotIsKeyWindow == true
        self.windowNumber = window?.screenshotWindowNumber
    }
}

enum ScreenshotCaptureContext {
    @TaskLocal static var initiatingWindow: ScreenshotCaptureWindowSnapshot?
}

typealias ScreenshotCaptureImageOverride =
    @MainActor (ScreenshotCaptureMode, Int?) async throws -> CGImage?

@MainActor
final class ScreenshotCaptureService: NSObject, ScreenshotCapturing {
    private let picker: any ScreenshotContentSharingPicker
    private let regionSelector: any ScreenRegionSelecting
    private let windowEnvironment: any ScreenshotCaptureWindowEnvironment
    private let captureImageOverride: ScreenshotCaptureImageOverride?
    private var isCaptureInProgress = false
    private var activePickerID: UUID?
    private var pickerObserver: ScreenshotContentSharingPickerObserverProxy?
    private var pickerContinuation: CheckedContinuation<SendableContentFilter?, Error>?
    private var previousPickerConfiguration: SCContentSharingPickerConfiguration?
    private var wasPickerActive = false

    init(
        regionSelector: (any ScreenRegionSelecting)? = nil,
        windowEnvironment: (any ScreenshotCaptureWindowEnvironment)? = nil,
        picker: (any ScreenshotContentSharingPicker)? = nil,
        captureImageOverride: ScreenshotCaptureImageOverride? = nil
    ) {
        self.picker = picker ?? SCContentSharingPicker.shared
        self.regionSelector = regionSelector ?? ScreenRegionSelectionController()
        self.windowEnvironment = windowEnvironment ?? AppKitScreenshotCaptureWindowEnvironment()
        self.captureImageOverride = captureImageOverride
        super.init()
    }

    func captureScreenshot(mode: ScreenshotCaptureMode) async throws -> CapturedScreenshot? {
        guard !isCaptureInProgress else {
            throw ScreenshotCaptureError.captureAlreadyInProgress
        }

        isCaptureInProgress = true
        let windowSnapshot = ScreenshotCaptureContext.initiatingWindow
            ?? ScreenshotCaptureWindowSnapshot(window: windowEnvironment.initiatingWindow)
        let initiatingWindow = windowSnapshot.window
        let shouldRestoreWindow = windowSnapshot.wasVisible
        let shouldRestoreKeyStatus = windowSnapshot.wasKey

        if shouldRestoreWindow {
            initiatingWindow?.hideForScreenshot()
        }

        defer {
            isCaptureInProgress = false
            restore(
                window: initiatingWindow,
                wasVisible: shouldRestoreWindow && !Task.isCancelled,
                wasKey: shouldRestoreKeyStatus
            )
        }

        try Task.checkCancellation()
        let image: CGImage?
        if let captureImageOverride {
            image = try await captureImageOverride(
                mode,
                windowSnapshot.windowNumber
            )
        } else {
            switch mode {
            case .area:
                image = try await captureSelectedArea()
            case .windowOrDisplay:
                image = try await captureSelectedWindowOrDisplay(
                    excludingWindowNumber: windowSnapshot.windowNumber
                )
            }
        }
        guard let image else { return nil }

        try Task.checkCancellation()
        let screenshot = try await Self.encodePNGOffMain(image)
        try Task.checkCancellation()
        return screenshot
    }

    private func captureSelectedArea() async throws -> CGImage? {
        let selectedRegion: SelectedScreenRegion?
        do {
            selectedRegion = try await regionSelector.selectRegion()
        } catch is ScreenRegionSelectionError {
            throw ScreenshotCaptureError.displayUnavailable
        }
        guard let selectedRegion else {
            return nil
        }
        try Task.checkCancellation()

        let shareableContent: SCShareableContent
        do {
            shareableContent = try await SCShareableContent.current
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.captureError(from: error)
        }

        try Task.checkCancellation()
        let displayIDs = shareableContent.displays.map(\.displayID)
        guard let displayIndex = Self.uniqueDisplayIndex(
            for: selectedRegion.displayID,
            in: displayIDs
        ) else {
            throw ScreenshotCaptureError.displayUnavailable
        }
        let display = shareableContent.displays[displayIndex]

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let currentApplications = shareableContent.applications.filter {
            $0.processID == currentProcessID
        }
        guard !currentApplications.isEmpty else {
            throw ScreenshotCaptureError.currentApplicationUnavailable
        }
        let contentFilter = SCContentFilter(
            display: display,
            excludingApplications: currentApplications,
            exceptingWindows: []
        )
        guard let sourceRect = ScreenRegionGeometry.sourceRect(
            for: selectedRegion.selectionRect,
            in: selectedRegion.screenFrame
        ), Self.isValidSourceRect(sourceRect, contentRect: contentFilter.contentRect) else {
            throw ScreenshotCaptureError.invalidCaptureDimensions
        }
        let configuration = try captureConfiguration(
            for: contentFilter,
            sourceRect: sourceRect
        )
        return try await captureImage(
            contentFilter: contentFilter,
            configuration: configuration
        )
    }

    private func captureSelectedWindowOrDisplay(
        excludingWindowNumber: Int?
    ) async throws -> CGImage? {
        let selectedContent = try await selectContent(
            excludingWindowNumber: excludingWindowNumber
        )
        guard let contentFilter = selectedContent?.value else {
            return nil
        }

        try Task.checkCancellation()
        let configuration = try captureConfiguration(for: contentFilter)
        return try await captureImage(
            contentFilter: contentFilter,
            configuration: configuration
        )
    }

    private func captureImage(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: contentFilter,
                configuration: configuration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.captureError(from: error)
        }
    }

    private func selectContent(excludingWindowNumber: Int?) async throws -> SendableContentFilter? {
        let pickerID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

            return try await withCheckedThrowingContinuation { continuation in
                let observer = ScreenshotContentSharingPickerObserverProxy(
                    pickerID: pickerID,
                    owner: self
                )
                activePickerID = pickerID
                pickerObserver = observer
                pickerContinuation = continuation
                previousPickerConfiguration = picker.defaultConfiguration
                wasPickerActive = picker.isActive

                var configuration = SCContentSharingPickerConfiguration()
                configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
                configuration.allowsChangingSelectedContent = false
                if let excludingWindowNumber, excludingWindowNumber > 0 {
                    configuration.excludedWindowIDs = [excludingWindowNumber]
                }

                picker.add(observer)
                picker.defaultConfiguration = configuration
                picker.isActive = true
                picker.present()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishPicking(
                    id: pickerID,
                    with: .failure(CancellationError())
                )
            }
        }
    }

    fileprivate func finishPicking(
        id: UUID,
        with result: Result<SendableContentFilter?, Error>
    ) {
        guard activePickerID == id, let continuation = pickerContinuation else { return }

        activePickerID = nil
        pickerContinuation = nil
        if let pickerObserver {
            picker.remove(pickerObserver)
        }
        pickerObserver = nil
        if let previousPickerConfiguration {
            picker.defaultConfiguration = previousPickerConfiguration
        }
        previousPickerConfiguration = nil
        picker.isActive = wasPickerActive

        continuation.resume(with: result)
    }

    private func captureConfiguration(
        for filter: SCContentFilter,
        sourceRect: CGRect? = nil
    ) throws -> SCStreamConfiguration {
        try Self.makeCaptureConfiguration(
            contentRect: filter.contentRect,
            pointPixelScale: CGFloat(filter.pointPixelScale),
            sourceRect: sourceRect
        )
    }

    static func makeCaptureConfiguration(
        contentRect: CGRect,
        pointPixelScale: CGFloat,
        sourceRect: CGRect? = nil
    ) throws -> SCStreamConfiguration {
        let captureRect = sourceRect ?? contentRect
        guard let dimensions = ScreenRegionGeometry.pixelDimensions(
            for: captureRect,
            pointPixelScale: pointPixelScale
        ) else {
            throw ScreenshotCaptureError.invalidCaptureDimensions
        }

        let configuration = SCStreamConfiguration()
        if let sourceRect {
            configuration.sourceRect = sourceRect
        }
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.showsCursor = false
        return configuration
    }

    nonisolated static func uniqueDisplayIndex(
        for displayID: CGDirectDisplayID,
        in displayIDs: [CGDirectDisplayID]
    ) -> Int? {
        let matches = displayIDs.indices.filter { displayIDs[$0] == displayID }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    nonisolated static func isValidSourceRect(
        _ sourceRect: CGRect,
        contentRect: CGRect
    ) -> Bool {
        guard sourceRect.minX >= 0,
              sourceRect.minY >= 0,
              sourceRect.width > 0,
              sourceRect.height > 0,
              contentRect.width > 0,
              contentRect.height > 0 else {
            return false
        }

        return sourceRect.maxX <= contentRect.width
            && sourceRect.maxY <= contentRect.height
    }

    nonisolated static func windowRestoreAction(
        wasVisible: Bool,
        wasKey: Bool,
        applicationIsActive: Bool
    ) -> ScreenshotWindowRestoreAction {
        guard wasVisible else { return .none }
        return wasKey && applicationIsActive ? .makeKeyAndOrderFront : .orderFront
    }

    private func restore(
        window: (any ScreenshotCaptureWindow)?,
        wasVisible: Bool,
        wasKey: Bool
    ) {
        guard let window else { return }

        switch Self.windowRestoreAction(
            wasVisible: wasVisible,
            wasKey: wasKey,
            applicationIsActive: windowEnvironment.isApplicationActive
        ) {
        case .none:
            break
        case .makeKeyAndOrderFront:
            windowEnvironment.activateApplication()
            window.makeKeyAndOrderFrontAfterScreenshot()
        case .orderFront:
            window.orderFrontAfterScreenshot()
        }
    }

    private nonisolated static func captureError(from error: Error) -> ScreenshotCaptureError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == SCStreamError.userDeclined.rawValue {
            return .permissionDenied
        }
        return .captureFailed(nsError.localizedDescription)
    }

    fileprivate nonisolated static func pickerError(from error: Error) -> ScreenshotCaptureError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == SCStreamError.userDeclined.rawValue {
            return .permissionDenied
        }
        return .pickerFailed(nsError.localizedDescription)
    }

    private nonisolated static func encodePNGOffMain(_ image: CGImage) async throws -> CapturedScreenshot {
        try Task.checkCancellation()
        return try encodePNG(image)
    }

    nonisolated static func encodePNG(_ image: CGImage) throws -> CapturedScreenshot {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0 else {
            throw ScreenshotCaptureError.invalidCaptureDimensions
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotCaptureError.pngEncodingFailed
        }

        CGImageDestinationAddImage(destination, image, nil)
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination), mutableData.length > 0 else {
            throw ScreenshotCaptureError.pngEncodingFailed
        }

        try Task.checkCancellation()
        let pngData = mutableData as Data
        guard isValidPNGData(pngData) else {
            throw ScreenshotCaptureError.invalidPNGData
        }

        return CapturedScreenshot(
            pngData: pngData,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    nonisolated static func isValidPNGData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            return false
        }
        return true
    }
}

final class ScreenshotContentSharingPickerObserverProxy:
    NSObject,
    SCContentSharingPickerObserver,
    @unchecked Sendable
{
    private let pickerID: UUID
    private weak var owner: ScreenshotCaptureService?

    init(pickerID: UUID, owner: ScreenshotCaptureService) {
        self.pickerID = pickerID
        self.owner = owner
    }

    @MainActor
    func receiveCancel() {
        owner?.finishPicking(id: pickerID, with: .success(nil))
    }

    @MainActor
    func receiveUpdate(_ filter: SCContentFilter) {
        receiveUpdate(SendableContentFilter(filter))
    }

    @MainActor
    private func receiveUpdate(_ filter: SendableContentFilter) {
        owner?.finishPicking(
            id: pickerID,
            with: .success(filter)
        )
    }

    @MainActor
    func receiveFailure(_ error: ScreenshotCaptureError) {
        owner?.finishPicking(
            id: pickerID,
            with: .failure(error)
        )
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor [weak self] in
            self?.receiveCancel()
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        let sendableFilter = SendableContentFilter(filter)
        Task { @MainActor [weak self] in
            self?.receiveUpdate(sendableFilter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        let captureError = ScreenshotCaptureService.pickerError(from: error)
        Task { @MainActor [weak self] in
            self?.receiveFailure(captureError)
        }
    }
}
