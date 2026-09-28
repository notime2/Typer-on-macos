// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import Testing
import UniformTypeIdentifiers
@testable import Typer_On

@Test
func testScreenshotEncoderProducesValidInMemoryPNG() throws {
    let sourceImage = try makeTestImage(width: 2, height: 1)

    let screenshot = try ScreenshotCaptureService.encodePNG(sourceImage)

    #expect(screenshot.pixelWidth == 2)
    #expect(screenshot.pixelHeight == 1)
    #expect(ScreenshotCaptureService.isValidPNGData(screenshot.pngData))
    #expect(screenshot.pngData.starts(with: [0x89, 0x50, 0x4E, 0x47]))
}

@Test
func testScreenshotPNGValidationRejectsEmptyAndUndecodableBytes() {
    #expect(!ScreenshotCaptureService.isValidPNGData(Data()))
    #expect(!ScreenshotCaptureService.isValidPNGData(Data([0x89, 0x50, 0x4E, 0x47])))
}

@Test
func testRegionDragNormalizesInEveryDirection() throws {
    let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let expected = CGRect(x: 100, y: 200, width: 300, height: 250)
    let corners = [
        (CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 450)),
        (CGPoint(x: 400, y: 200), CGPoint(x: 100, y: 450)),
        (CGPoint(x: 100, y: 450), CGPoint(x: 400, y: 200)),
        (CGPoint(x: 400, y: 450), CGPoint(x: 100, y: 200))
    ]

    for (start, end) in corners {
        let region = try #require(
            ScreenRegionGeometry.normalizedSelection(from: start, to: end, in: screen)
        )
        #expect(region == expected)
    }
}

@Test
func testRegionDragClampsToStartDisplayAndEnforcesMinimumSize() {
    let screen = CGRect(x: -1_440, y: -200, width: 1_440, height: 900)

    #expect(
        ScreenRegionGeometry.normalizedSelection(
            from: CGPoint(x: -100, y: 600),
            to: CGPoint(x: 800, y: 1_200),
            in: screen
        ) == CGRect(x: -100, y: 600, width: 100, height: 100)
    )
    #expect(
        ScreenRegionGeometry.normalizedSelection(
            from: CGPoint(x: -1_444, y: -204),
            to: CGPoint(x: -1_440, y: -200),
            in: screen
        ) == nil
    )
    #expect(
        ScreenRegionGeometry.normalizedSelection(
            from: CGPoint(x: -1_440, y: -200),
            to: CGPoint(x: -1_436, y: -196),
            in: screen
        ) == CGRect(x: -1_440, y: -200, width: 4, height: 4)
    )
    #expect(
        ScreenRegionGeometry.normalizedSelection(
            from: CGPoint(x: -1_440, y: -200),
            to: CGPoint(x: -1_436.01, y: -196),
            in: screen
        ) == nil
    )
}

@Test
func testRegionSourceRectUsesDisplayLocalTopLeftCoordinates() throws {
    let screen = CGRect(x: -1_920, y: -180, width: 1_920, height: 1_080)
    let selection = CGRect(x: -1_800, y: 400, width: 320, height: 200)

    let sourceRect = try #require(
        ScreenRegionGeometry.sourceRect(for: selection, in: screen)
    )

    #expect(sourceRect == CGRect(x: 120, y: 300, width: 320, height: 200))
}

@Test
func testRegionPixelDimensionsSupportStandardAndRetinaScale() throws {
    let sourceRect = CGRect(x: 10, y: 20, width: 300.25, height: 150.25)

    #expect(
        try #require(ScreenRegionGeometry.pixelDimensions(for: sourceRect, pointPixelScale: 1))
            == ScreenshotPixelDimensions(width: 301, height: 151)
    )
    #expect(
        try #require(ScreenRegionGeometry.pixelDimensions(for: sourceRect, pointPixelScale: 2))
            == ScreenshotPixelDimensions(width: 601, height: 301)
    )
    #expect(ScreenRegionGeometry.pixelDimensions(for: sourceRect, pointPixelScale: 0) == nil)
}

@Test
func testRegionDisplayMatchingRequiresExactlyOneDisplay() {
    #expect(ScreenshotCaptureService.uniqueDisplayIndex(for: 42, in: [11, 42, 77]) == 1)
    #expect(ScreenshotCaptureService.uniqueDisplayIndex(for: 42, in: [11, 77]) == nil)
    #expect(ScreenshotCaptureService.uniqueDisplayIndex(for: 42, in: [42, 42]) == nil)
}

@Test
func testScreenshotWindowRestorePolicyPreservesFocusOwnership() {
    #expect(
        ScreenshotCaptureService.windowRestoreAction(
            wasVisible: true,
            wasKey: true,
            applicationIsActive: true
        ) == .makeKeyAndOrderFront
    )
    #expect(
        ScreenshotCaptureService.windowRestoreAction(
            wasVisible: true,
            wasKey: true,
            applicationIsActive: false
        ) == .orderFront
    )
    #expect(
        ScreenshotCaptureService.windowRestoreAction(
            wasVisible: false,
            wasKey: true,
            applicationIsActive: true
        ) == .none
    )
}

@Test
@MainActor
func testScreenshotServiceHidesAndRestoresWindowForBothCaptureModes() async throws {
    for mode in [ScreenshotCaptureMode.area, .windowOrDisplay] {
        let window = FakeScreenshotCaptureWindow(isVisible: true, isKey: true)
        let environment = FakeScreenshotCaptureWindowEnvironment(window: window)
        var receivedMode: ScreenshotCaptureMode?
        var receivedWindowNumber: Int?
        let service = ScreenshotCaptureService(
            windowEnvironment: environment,
            captureImageOverride: { mode, windowNumber in
                receivedMode = mode
                receivedWindowNumber = windowNumber
                return try makeTestImage(width: 2, height: 1)
            }
        )

        let screenshot = try #require(await service.captureScreenshot(mode: mode))

        #expect(receivedMode == mode)
        #expect(receivedWindowNumber == window.screenshotWindowNumber)
        #expect(screenshot.pixelWidth == 2)
        #expect(screenshot.pixelHeight == 1)
        #expect(window.hideCount == 1)
        #expect(window.makeKeyAndOrderFrontCount == 1)
        #expect(window.orderFrontCount == 0)
        #expect(environment.activateCount == 1)
    }
}

@Test
@MainActor
func testScreenshotServiceRestoresWindowAfterCancelAndError() async {
    let cancelWindow = FakeScreenshotCaptureWindow(isVisible: true, isKey: true)
    let cancelEnvironment = FakeScreenshotCaptureWindowEnvironment(window: cancelWindow)
    let cancelService = ScreenshotCaptureService(
        windowEnvironment: cancelEnvironment,
        captureImageOverride: { _, _ in nil }
    )

    do {
        let screenshot = try await cancelService.captureScreenshot(mode: .area)
        #expect(screenshot == nil)
    } catch {
        Issue.record("User cancellation should not throw: \(error)")
    }
    #expect(cancelWindow.hideCount == 1)
    #expect(cancelWindow.makeKeyAndOrderFrontCount == 1)

    let errorWindow = FakeScreenshotCaptureWindow(isVisible: true, isKey: true)
    let errorEnvironment = FakeScreenshotCaptureWindowEnvironment(window: errorWindow)
    let errorService = ScreenshotCaptureService(
        windowEnvironment: errorEnvironment,
        captureImageOverride: { _, _ in
            throw ScreenshotCaptureError.captureFailed("Expected failure")
        }
    )

    do {
        _ = try await errorService.captureScreenshot(mode: .windowOrDisplay)
        Issue.record("Expected capture error")
    } catch let error as ScreenshotCaptureError {
        #expect(error == .captureFailed("Expected failure"))
    } catch {
        Issue.record("Unexpected capture error: \(error)")
    }
    #expect(errorWindow.hideCount == 1)
    #expect(errorWindow.makeKeyAndOrderFrontCount == 1)
}

@Test
@MainActor
func testAreaCaptureMapsOverlaySetupFailureAndRestoresWindow() async {
    let window = FakeScreenshotCaptureWindow(isVisible: true, isKey: true)
    let environment = FakeScreenshotCaptureWindowEnvironment(window: window)
    let selector = FakeScreenRegionSelector(
        result: .failure(ScreenRegionSelectionError.displayUnavailable)
    )
    let service = ScreenshotCaptureService(
        regionSelector: selector,
        windowEnvironment: environment
    )

    do {
        _ = try await service.captureScreenshot(mode: .area)
        Issue.record("Expected display setup failure")
    } catch let error as ScreenshotCaptureError {
        #expect(error == .displayUnavailable)
        #expect(error.localizedDescription.contains("display"))
    } catch {
        Issue.record("Unexpected display setup error: \(error)")
    }

    #expect(selector.selectionCount == 1)
    #expect(window.hideCount == 1)
    #expect(window.makeKeyAndOrderFrontCount == 1)
}

@Test
@MainActor
func testScreenshotServiceDoesNotStealFocusAfterApplicationSwitch() async {
    let window = FakeScreenshotCaptureWindow(isVisible: true, isKey: true)
    let environment = FakeScreenshotCaptureWindowEnvironment(window: window)
    let service = ScreenshotCaptureService(
        windowEnvironment: environment,
        captureImageOverride: { _, _ in
            environment.isApplicationActive = false
            return nil
        }
    )

    do {
        _ = try await service.captureScreenshot(mode: .area)
    } catch {
        Issue.record("Application-switch cancellation should not throw: \(error)")
    }

    #expect(window.hideCount == 1)
    #expect(window.orderFrontCount == 1)
    #expect(window.makeKeyAndOrderFrontCount == 0)
    #expect(environment.activateCount == 0)
}

@Test
@MainActor
func testScreenshotServiceTaskCancellationDoesNotRestoreHiddenWindow() async {
    let window = FakeScreenshotCaptureWindow(isVisible: true, isKey: true)
    let environment = FakeScreenshotCaptureWindowEnvironment(window: window)
    let service = ScreenshotCaptureService(
        windowEnvironment: environment,
        captureImageOverride: { _, _ in
            try await Task.sleep(for: .seconds(5))
            return nil
        }
    )
    let captureTask = Task { @MainActor in
        try await service.captureScreenshot(mode: .area)
    }

    for _ in 0..<20 where window.hideCount == 0 {
        await Task.yield()
    }
    #expect(window.hideCount == 1)

    captureTask.cancel()
    _ = await captureTask.result

    #expect(window.orderFrontCount == 0)
    #expect(window.makeKeyAndOrderFrontCount == 0)
    #expect(environment.activateCount == 0)
}

@Test
@MainActor
func testNativePickerIgnoresStaleCallbacksAfterNextPickerStarts() async {
    for staleCallback in StalePickerCallback.allCases {
        let window = FakeScreenshotCaptureWindow(isVisible: true, isKey: true)
        let environment = FakeScreenshotCaptureWindowEnvironment(window: window)
        let picker = FakeScreenshotContentSharingPicker()
        let service = ScreenshotCaptureService(
            windowEnvironment: environment,
            picker: picker
        )

        let firstCapture = Task { @MainActor in
            try await service.captureScreenshot(mode: .windowOrDisplay)
        }
        await waitForPickerObservers(1, in: picker)
        picker.cancel(observerAt: 0)

        switch await firstCapture.result {
        case .success(let screenshot):
            #expect(screenshot == nil)
        case .failure(let error):
            Issue.record("First picker cancellation threw an error: \(error)")
        }

        let secondCapture = Task { @MainActor in
            try await service.captureScreenshot(mode: .windowOrDisplay)
        }
        await waitForPickerObservers(2, in: picker)
        let removeCountBeforeStaleCallback = picker.removeCount

        picker.deliver(staleCallback, observerAt: 0)

        #expect(picker.removeCount == removeCountBeforeStaleCallback)
        #expect(picker.isActive)

        picker.fail(observerAt: 1, description: "current picker failure")
        switch await secondCapture.result {
        case .success:
            Issue.record("Stale \(staleCallback) callback completed the current picker")
        case .failure(let error as ScreenshotCaptureError):
            #expect(error == .pickerFailed("current picker failure"))
        case .failure(let error):
            Issue.record("Unexpected picker error: \(error)")
        }
    }
}

@Test
@MainActor
func testRegionCaptureConfigurationUsesSourceRectScaleAndHidesCursor() throws {
    let contentRect = CGRect(x: -1_440, y: 0, width: 1_440, height: 900)
    let sourceRect = CGRect(x: 100, y: 200, width: 300.25, height: 150.25)

    let configuration = try ScreenshotCaptureService.makeCaptureConfiguration(
        contentRect: contentRect,
        pointPixelScale: 2,
        sourceRect: sourceRect
    )

    #expect(configuration.sourceRect == sourceRect)
    #expect(configuration.width == 601)
    #expect(configuration.height == 301)
    #expect(configuration.captureResolution == .best)
    #expect(!configuration.scalesToFit)
    #expect(!configuration.showsCursor)
    #expect(ScreenshotCaptureService.isValidSourceRect(sourceRect, contentRect: contentRect))
    #expect(
        !ScreenshotCaptureService.isValidSourceRect(
            CGRect(x: 1_300, y: 200, width: 300, height: 150),
            contentRect: contentRect
        )
    )
}

@Test
@MainActor
func testRegionSelectionTaskCancellationCleansOverlayExactlyOnce() async {
    let overlayCoordinator = FakeRegionOverlayCoordinator()
    let controller = ScreenRegionSelectionController(
        overlayCoordinator: overlayCoordinator
    )
    let selectionTask = Task { @MainActor in
        try await controller.selectRegion()
    }

    await Task.yield()
    #expect(overlayCoordinator.beginCount == 1)

    selectionTask.cancel()
    let result = await selectionTask.result

    switch result {
    case .success(let selection):
        #expect(selection == nil)
    case .failure(let error):
        Issue.record("Selection cancellation threw an error: \(error)")
    }
    #expect(overlayCoordinator.endCount == 1)

    overlayCoordinator.complete(with: nil)
    #expect(overlayCoordinator.endCount == 1)
}

@Test
@MainActor
func testRegionSelectionCancellationWinsQueuedMouseUpCompletion() async {
    let overlayCoordinator = FakeRegionOverlayCoordinator()
    let controller = ScreenRegionSelectionController(
        overlayCoordinator: overlayCoordinator
    )
    let selectedRegion = SelectedScreenRegion(
        displayID: 42,
        screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
        selectionRect: CGRect(x: 100, y: 100, width: 300, height: 180)
    )
    let selectionTask = Task { @MainActor in
        try await controller.selectRegion()
    }

    await Task.yield()
    selectionTask.cancel()
    overlayCoordinator.complete(with: selectedRegion)

    let result = await selectionTask.result
    switch result {
    case .success(let selection):
        #expect(selection == nil)
    case .failure(let error):
        Issue.record("Selection cancellation threw an error: \(error)")
    }
    #expect(overlayCoordinator.endCount == 1)
}

@Test
@MainActor
func testRegionSelectionIgnoresStaleCompletionAfterNextSelectionStarts() async throws {
    let overlayCoordinator = FakeRegionOverlayCoordinator()
    let controller = ScreenRegionSelectionController(
        overlayCoordinator: overlayCoordinator
    )
    let staleRegion = SelectedScreenRegion(
        displayID: 11,
        screenFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
        selectionRect: CGRect(x: 40, y: 40, width: 100, height: 80)
    )
    let expectedRegion = SelectedScreenRegion(
        displayID: 22,
        screenFrame: CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
        selectionRect: CGRect(x: -1_200, y: 200, width: 300, height: 180)
    )

    let firstSelection = Task { @MainActor in
        try await controller.selectRegion()
    }
    await waitForRegionBegins(1, in: overlayCoordinator)
    firstSelection.cancel()
    #expect(try await firstSelection.value == nil)

    let secondSelection = Task { @MainActor in
        try await controller.selectRegion()
    }
    await waitForRegionBegins(2, in: overlayCoordinator)
    overlayCoordinator.complete(at: 0, with: staleRegion)
    overlayCoordinator.complete(at: 1, with: expectedRegion)

    #expect(try await secondSelection.value == expectedRegion)
    #expect(overlayCoordinator.endCount == 2)
}

@Test
@MainActor
func testRegionSelectionCompletionReturnsRegionAndCleansOverlayExactlyOnce() async throws {
    let overlayCoordinator = FakeRegionOverlayCoordinator()
    let controller = ScreenRegionSelectionController(
        overlayCoordinator: overlayCoordinator
    )
    let expected = SelectedScreenRegion(
        displayID: 42,
        screenFrame: CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
        selectionRect: CGRect(x: -1_200, y: 200, width: 300, height: 180)
    )
    let selectionTask = Task { @MainActor in
        try await controller.selectRegion()
    }

    await Task.yield()
    overlayCoordinator.complete(with: expected)
    let result = try #require(try await selectionTask.value)

    #expect(result == expected)
    #expect(overlayCoordinator.endCount == 1)

    overlayCoordinator.complete(with: nil)
    #expect(overlayCoordinator.endCount == 1)
}

@Test
@MainActor
func testRealOverlayCoordinatorCleansPanelsAndObserversExactlyOnce() throws {
    let screens = [
        ScreenRegionOverlayScreen(
            displayID: 11,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        ),
        ScreenRegionOverlayScreen(
            displayID: 22,
            frame: CGRect(x: -1_440, y: -200, width: 1_440, height: 900)
        )
    ]
    let environment = FakeRegionOverlayEnvironment(
        screens: screens,
        mouseLocation: CGPoint(x: -700, y: 300)
    )
    let coordinator = ScreenRegionSelectionOverlayCoordinator(environment: environment)
    var completionCount = 0

    try coordinator.beginSelection { _ in
        completionCount += 1
        coordinator.endSelection()
    }

    #expect(environment.activateCount == 1)
    #expect(environment.startObservingCount == 1)
    #expect(environment.panels.count == 2)
    #expect(environment.panels.allSatisfy { $0.presentCount == 1 })
    #expect(environment.panels[0].focusCount == 0)
    #expect(environment.panels[1].focusCount == 1)

    environment.triggerCancellation()

    #expect(completionCount == 1)
    #expect(environment.stopObservingCount == 1)
    #expect(environment.panels.allSatisfy { $0.dismissCount == 1 })

    environment.triggerCancellation()
    coordinator.endSelection()
    #expect(completionCount == 1)
    #expect(environment.stopObservingCount == 1)
    #expect(environment.panels.allSatisfy { $0.dismissCount == 1 })
}

@Test
@MainActor
func testOverlayCoordinatorIgnoresStalePanelAfterNextSelectionStarts() throws {
    let screen = ScreenRegionOverlayScreen(
        displayID: 42,
        frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
    )
    let environment = FakeRegionOverlayEnvironment(
        screens: [screen],
        mouseLocation: CGPoint(x: 500, y: 400)
    )
    let coordinator = ScreenRegionSelectionOverlayCoordinator(environment: environment)
    let staleRegion = SelectedScreenRegion(
        displayID: 42,
        screenFrame: screen.frame,
        selectionRect: CGRect(x: 10, y: 10, width: 100, height: 80)
    )
    let expectedRegion = SelectedScreenRegion(
        displayID: 42,
        screenFrame: screen.frame,
        selectionRect: CGRect(x: 200, y: 200, width: 300, height: 180)
    )
    var receivedRegion: SelectedScreenRegion?

    try coordinator.beginSelection { _ in }
    let stalePanel = environment.panels[0]
    coordinator.endSelection()

    try coordinator.beginSelection { selection in
        receivedRegion = selection
        coordinator.endSelection()
    }
    let currentPanel = environment.panels[1]

    stalePanel.complete(with: staleRegion)
    #expect(receivedRegion == nil)

    currentPanel.complete(with: expectedRegion)
    #expect(receivedRegion == expectedRegion)
    #expect(environment.stopObservingCount == 2)
    #expect(stalePanel.dismissCount == 1)
    #expect(currentPanel.dismissCount == 1)
}

@Test
@MainActor
func testOverlayDisplaySetupFailureIsNotTreatedAsCancellation() async {
    let environment = FakeRegionOverlayEnvironment(screens: [], mouseLocation: .zero)
    let coordinator = ScreenRegionSelectionOverlayCoordinator(environment: environment)
    let controller = ScreenRegionSelectionController(overlayCoordinator: coordinator)

    do {
        _ = try await controller.selectRegion()
        Issue.record("Expected display setup to fail")
    } catch let error as ScreenRegionSelectionError {
        #expect(error == .displayUnavailable)
    } catch {
        Issue.record("Unexpected display setup error: \(error)")
    }

    #expect(environment.activateCount == 0)
    #expect(environment.startObservingCount == 0)
    #expect(environment.stopObservingCount == 0)
    #expect(environment.panels.isEmpty)
}

@Test
func testChatImageDecodeAppliesEmbeddedOrientation() async throws {
    let sourceImage = try makeTestImage(width: 2, height: 1)
    let orientedJPEG = try encode(
        sourceImage,
        type: UTType.jpeg,
        properties: [kCGImagePropertyOrientation: 6]
    )

    let decodedImage = try #require(await ChatImageAttachmentView.decodeImage(orientedJPEG))

    #expect(decodedImage.width == 1)
    #expect(decodedImage.height == 2)
}

@Test
func testChatImageDecodeDownsamplesLargeImages() async throws {
    let sourceImage = try makeTestImage(width: 3_000, height: 1_500)
    let pngData = try encode(sourceImage, type: UTType.png)

    let decodedImage = try #require(await ChatImageAttachmentView.decodeImage(pngData))

    #expect(decodedImage.width == 2_048)
    #expect(decodedImage.height == 1_024)
}

private func makeTestImage(width: Int, height: Int) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    let context = try #require(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
    )
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

private func encode(
    _ image: CGImage,
    type: UTType,
    properties: [CFString: Any] = [:]
) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@MainActor
private func waitForPickerObservers(
    _ expectedCount: Int,
    in picker: FakeScreenshotContentSharingPicker
) async {
    let deadline = ContinuousClock.now + .seconds(1)
    while picker.addedObservers.count < expectedCount,
          ContinuousClock.now < deadline {
        await Task.yield()
    }
    #expect(picker.addedObservers.count == expectedCount)
}

@MainActor
private func waitForRegionBegins(
    _ expectedCount: Int,
    in coordinator: FakeRegionOverlayCoordinator
) async {
    let deadline = ContinuousClock.now + .seconds(1)
    while coordinator.beginCount < expectedCount,
          ContinuousClock.now < deadline {
        await Task.yield()
    }
    #expect(coordinator.beginCount == expectedCount)
}

private enum StalePickerCallback: CaseIterable {
    case cancel
    case update
    case failure
}

@MainActor
private final class FakeRegionOverlayCoordinator: ScreenRegionSelectionOverlayCoordinating {
    private var completions: [(SelectedScreenRegion?) -> Void] = []
    private(set) var beginCount = 0
    private(set) var endCount = 0

    func beginSelection(
        onComplete: @escaping (SelectedScreenRegion?) -> Void
    ) throws {
        beginCount += 1
        completions.append(onComplete)
    }

    func endSelection() {
        endCount += 1
    }

    func complete(with selection: SelectedScreenRegion?) {
        completions.last?(selection)
    }

    func complete(at index: Int, with selection: SelectedScreenRegion?) {
        completions[index](selection)
    }
}

@MainActor
private final class FakeScreenshotContentSharingPicker: ScreenshotContentSharingPicker {
    var defaultConfiguration = SCContentSharingPickerConfiguration()
    var isActive = false
    private(set) var addedObservers: [any SCContentSharingPickerObserver] = []
    private(set) var removeCount = 0
    private(set) var presentCount = 0

    func add(_ observer: any SCContentSharingPickerObserver) {
        addedObservers.append(observer)
    }

    func remove(_ observer: any SCContentSharingPickerObserver) {
        removeCount += 1
    }

    func present() {
        presentCount += 1
    }

    func cancel(observerAt index: Int) {
        observer(at: index)?.receiveCancel()
    }

    func update(observerAt index: Int) {
        observer(at: index)?.receiveUpdate(SCContentFilter())
    }

    func fail(observerAt index: Int, description: String) {
        observer(at: index)?.receiveFailure(.pickerFailed(description))
    }

    func deliver(_ callback: StalePickerCallback, observerAt index: Int) {
        switch callback {
        case .cancel:
            cancel(observerAt: index)
        case .update:
            update(observerAt: index)
        case .failure:
            fail(observerAt: index, description: "stale picker failure")
        }
    }

    private func observer(at index: Int) -> ScreenshotContentSharingPickerObserverProxy? {
        guard let observer = addedObservers[index]
            as? ScreenshotContentSharingPickerObserverProxy else {
            Issue.record("Unexpected picker observer type")
            return nil
        }
        return observer
    }
}

@MainActor
private final class FakeRegionOverlayEnvironment: ScreenRegionOverlayEnvironment {
    let screens: [ScreenRegionOverlayScreen]
    let mouseLocation: CGPoint
    private(set) var panels: [FakeRegionOverlayPanel] = []
    private(set) var activateCount = 0
    private(set) var startObservingCount = 0
    private(set) var stopObservingCount = 0
    private var cancellationHandler: (() -> Void)?

    init(screens: [ScreenRegionOverlayScreen], mouseLocation: CGPoint) {
        self.screens = screens
        self.mouseLocation = mouseLocation
    }

    func availableScreens() throws -> [ScreenRegionOverlayScreen] {
        screens
    }

    func makePanel(
        for screen: ScreenRegionOverlayScreen,
        onComplete: @escaping (SelectedScreenRegion?) -> Void
    ) -> any ScreenRegionOverlayPanel {
        let panel = FakeRegionOverlayPanel(frame: screen.frame, onComplete: onComplete)
        panels.append(panel)
        return panel
    }

    func activateApplication() {
        activateCount += 1
    }

    func startObservingCancellation(_ handler: @escaping () -> Void) {
        startObservingCount += 1
        cancellationHandler = handler
    }

    func stopObservingCancellation() {
        stopObservingCount += 1
        cancellationHandler = nil
    }

    func triggerCancellation() {
        cancellationHandler?()
    }
}

@MainActor
private final class FakeRegionOverlayPanel: ScreenRegionOverlayPanel {
    let frame: CGRect
    private let onComplete: (SelectedScreenRegion?) -> Void
    private(set) var presentCount = 0
    private(set) var focusCount = 0
    private(set) var dismissCount = 0

    init(frame: CGRect, onComplete: @escaping (SelectedScreenRegion?) -> Void) {
        self.frame = frame
        self.onComplete = onComplete
    }

    func present() {
        presentCount += 1
    }

    func focus() {
        focusCount += 1
    }

    func dismissSelection() {
        dismissCount += 1
    }

    func complete(with selection: SelectedScreenRegion?) {
        onComplete(selection)
    }
}

@MainActor
private final class FakeScreenshotCaptureWindow: ScreenshotCaptureWindow {
    private(set) var screenshotIsVisible: Bool
    private(set) var screenshotIsKeyWindow: Bool
    let screenshotWindowNumber = 72
    private(set) var hideCount = 0
    private(set) var orderFrontCount = 0
    private(set) var makeKeyAndOrderFrontCount = 0

    init(isVisible: Bool, isKey: Bool) {
        screenshotIsVisible = isVisible
        screenshotIsKeyWindow = isKey
    }

    func hideForScreenshot() {
        hideCount += 1
        screenshotIsVisible = false
        screenshotIsKeyWindow = false
    }

    func orderFrontAfterScreenshot() {
        orderFrontCount += 1
        screenshotIsVisible = true
    }

    func makeKeyAndOrderFrontAfterScreenshot() {
        makeKeyAndOrderFrontCount += 1
        screenshotIsVisible = true
        screenshotIsKeyWindow = true
    }
}

@MainActor
private final class FakeScreenshotCaptureWindowEnvironment:
    ScreenshotCaptureWindowEnvironment
{
    let initiatingWindow: (any ScreenshotCaptureWindow)?
    var isApplicationActive = true
    private(set) var activateCount = 0

    init(window: any ScreenshotCaptureWindow) {
        initiatingWindow = window
    }

    func activateApplication() {
        activateCount += 1
        isApplicationActive = true
    }
}

@MainActor
private final class FakeScreenRegionSelector: ScreenRegionSelecting {
    let result: Result<SelectedScreenRegion?, Error>
    private(set) var selectionCount = 0

    init(result: Result<SelectedScreenRegion?, Error>) {
        self.result = result
    }

    func selectRegion() async throws -> SelectedScreenRegion? {
        selectionCount += 1
        return try result.get()
    }
}
