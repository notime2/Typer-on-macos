// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Testing
@testable import Typer_On

@Test
@MainActor
func testAXNotificationMonitorRebindsWhenFrontmostApplicationChanges() {
    let client = FakeAXNotificationClient()
    client.frontmostPID = 111
    client.applicationElements[111] = FakeAXNotificationElement(stableID: 1)
    client.focusedElements[111] = FakeAXNotificationElement(stableID: 11)
    client.applicationElements[222] = FakeAXNotificationElement(stableID: 2)
    client.focusedElements[222] = FakeAXNotificationElement(stableID: 22)

    let monitor = AXNotificationMonitor(
        client: client,
        notificationCenter: NotificationCenter()
    )

    monitor.start()
    client.frontmostPID = 222
    monitor.rebindToFrontmostApplication()

    #expect(client.attachedPIDs == [111, 222])
    #expect(client.detachedPIDs == [111])
    #expect(client.addCalls.contains("111:AXFocusedUIElementChanged:1"))
    #expect(client.addCalls.contains("222:AXSelectedTextChanged:22"))
}

@Test
@MainActor
func testAXNotificationMonitorRebindsFocusedElementAfterFocusNotification() async {
    let client = FakeAXNotificationClient()
    client.frontmostPID = 111
    client.applicationElements[111] = FakeAXNotificationElement(stableID: 1)
    client.focusedElements[111] = FakeAXNotificationElement(stableID: 11)

    let monitor = AXNotificationMonitor(
        client: client,
        notificationCenter: NotificationCenter()
    )

    monitor.start()
    client.focusedElements[111] = FakeAXNotificationElement(stableID: 44)
    client.trigger(processIdentifier: 111, notification: .focusedUIElementChanged)
    await Task.yield()

    #expect(client.removeCalls.contains("111:AXSelectedTextChanged:11"))
    #expect(client.removeCalls.contains("111:AXValueChanged:11"))
    #expect(client.addCalls.contains("111:AXSelectedTextChanged:44"))
    #expect(client.addCalls.contains("111:AXValueChanged:44"))
}

@Test
@MainActor
func testAXNotificationMonitorFallsBackWhenObserverCannotBeCreated() {
    let client = FakeAXNotificationClient()
    client.frontmostPID = 111
    client.shouldCreateObserver = false

    let monitor = AXNotificationMonitor(
        client: client,
        notificationCenter: NotificationCenter()
    )

    monitor.start()

    #expect(client.attachedPIDs.isEmpty)
    #expect(client.addCalls.isEmpty)
}

@Test
@MainActor
func testAXNotificationMonitorForwardsSelectionChangePID() async {
    let client = FakeAXNotificationClient()
    client.frontmostPID = 111
    client.applicationElements[111] = FakeAXNotificationElement(stableID: 1)
    client.focusedElements[111] = FakeAXNotificationElement(stableID: 11)

    let monitor = AXNotificationMonitor(
        client: client,
        notificationCenter: NotificationCenter()
    )
    var observedPID: pid_t?
    monitor.onPotentialSelectionChange = { pid, _ in observedPID = pid }

    monitor.start()
    client.trigger(processIdentifier: 111, notification: .selectedTextChanged)
    await Task.yield()

    #expect(observedPID == 111)
}

@Test @MainActor
func testDuplicateFocusNotificationDoesNotInvalidateSelection() async {
    let client = FakeAXNotificationClient()
    client.frontmostPID = 111
    client.applicationElements[111] = FakeAXNotificationElement(stableID: 1)
    client.focusedElements[111] = FakeAXNotificationElement(stableID: 11)
    let monitor = AXNotificationMonitor(client: client, notificationCenter: NotificationCenter())
    var changes = 0
    monitor.onFocusedElementChanged = { _, _ in changes += 1 }
    monitor.start()
    monitor.rebindToFrontmostApplication()
    #expect(changes == 0)
    client.focusedElements[111] = FakeAXNotificationElement(stableID: 22)
    monitor.rebindToFrontmostApplication()
    #expect(changes == 1)
}

@Test @MainActor
func testDeferredFocusReadsCoalesceAndDiscardPreviousApplication() {
    let client = FakeAXNotificationClient()
    client.deferFocusRequests = true
    client.frontmostPID = 111
    client.applicationElements[111] = FakeAXNotificationElement(stableID: 1)
    client.applicationElements[222] = FakeAXNotificationElement(stableID: 2)
    let monitor = AXNotificationMonitor(client: client, notificationCenter: NotificationCenter())
    monitor.start()
    for _ in 0..<20 { monitor.rebindToFrontmostApplication() }
    #expect(client.focusRequests == [111])
    client.frontmostPID = 222
    monitor.rebindToFrontmostApplication()
    client.completeFocus(FakeAXNotificationElement(stableID: 11))
    #expect(client.focusRequests == [111, 222])
    #expect(!client.addCalls.contains("111:AXSelectedTextChanged:11"))
    client.completeFocus(FakeAXNotificationElement(stableID: 22))
    #expect(client.addCalls.contains("222:AXSelectedTextChanged:22"))
    monitor.stop()
}

private final class FakeAXNotificationClient: AXNotificationMonitoringClient {
    var frontmostPID: pid_t?
    var deferFocusRequests = false
    var focusRequests: [pid_t] = []
    private var focusCompletion: (@MainActor @Sendable (AXNotificationElementHandle?) -> Void)?

    @MainActor func requestFocusedElement(processIdentifier: pid_t,
        completion: @escaping @MainActor @Sendable (AXNotificationElementHandle?) -> Void) {
        focusRequests.append(processIdentifier)
        if deferFocusRequests { focusCompletion = completion }
        else { completion(focusedElement(processIdentifier: processIdentifier)) }
    }

    @MainActor func completeFocus(_ element: AXNotificationElementHandle?) {
        let completion = focusCompletion
        focusCompletion = nil
        completion?(element)
    }
    var shouldCreateObserver = true
    var applicationElements: [pid_t: FakeAXNotificationElement] = [:]
    var focusedElements: [pid_t: FakeAXNotificationElement] = [:]
    var addCalls: [String] = []
    var removeCalls: [String] = []
    var attachedPIDs: [pid_t] = []
    var detachedPIDs: [pid_t] = []

    private var callbacks: [pid_t: (AXMonitoredNotification, pid_t) -> Void] = [:]

    func frontmostProcessIdentifier() -> pid_t? {
        frontmostPID
    }

    func makeObserver(
        processIdentifier: pid_t,
        callback: @escaping (AXMonitoredNotification, pid_t) -> Void
    ) -> AXNotificationObserverHandle? {
        guard shouldCreateObserver else { return nil }
        callbacks[processIdentifier] = callback
        return FakeAXNotificationObserver(processIdentifier: processIdentifier)
    }

    func applicationElement(processIdentifier: pid_t) -> AXNotificationElementHandle? {
        applicationElements[processIdentifier]
    }

    func focusedElement(processIdentifier: pid_t) -> AXNotificationElementHandle? {
        focusedElements[processIdentifier]
    }

    func add(
        notification: AXMonitoredNotification,
        observer: AXNotificationObserverHandle,
        element: AXNotificationElementHandle
    ) -> Bool {
        addCalls.append(callKey(observer: observer, notification: notification, element: element))
        return true
    }

    func remove(
        notification: AXMonitoredNotification,
        observer: AXNotificationObserverHandle,
        element: AXNotificationElementHandle
    ) {
        removeCalls.append(callKey(observer: observer, notification: notification, element: element))
    }

    func attachToRunLoop(observer: AXNotificationObserverHandle) {
        attachedPIDs.append(observer.processIdentifier)
    }

    func detachFromRunLoop(observer: AXNotificationObserverHandle) {
        detachedPIDs.append(observer.processIdentifier)
    }

    func trigger(processIdentifier: pid_t, notification: AXMonitoredNotification) {
        callbacks[processIdentifier]?(notification, processIdentifier)
    }

    private func callKey(
        observer: AXNotificationObserverHandle,
        notification: AXMonitoredNotification,
        element: AXNotificationElementHandle
    ) -> String {
        "\(observer.processIdentifier):\(notification.rawValue):\(element.stableID)"
    }
}

private final class FakeAXNotificationObserver: AXNotificationObserverHandle {
    let processIdentifier: pid_t

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }
}

private final class FakeAXNotificationElement: AXNotificationElementHandle {
    let stableID: Int

    init(stableID: Int) {
        self.stableID = stableID
    }
}

@MainActor
private func notificationSelectionSnapshot(
    focus: Int = 11, role: String = "AXStaticText", writable: Bool = false, text: String? = nil
) -> AXTextSelectionSnapshot {
    AXTextSelectionSnapshot(
        rawSelectedTextEvidence: text.map { .nonEmpty(text: $0, range: nil) } ?? .unsupported,
        selectedTextRangesEvidence: .unsupported,
        selectedTextRangeEvidence: text == nil ? .empty : .unsupported,
        selectedTextMarkerRangeEvidence: .unsupported, cursorPosition: .zero, selectionBounds: nil,
        sourceAppPID: 123, appBundleIdentifier: "one.ayugram.AyuGramDesktop",
        focusedElementRole: role, focusedElementSubrole: nil, isValueAttributeWritable: writable,
        boundsMode: .topLeftNeedsConversion, focusedElementID: focus
    )
}

@MainActor
private final class NotificationSelectionFixture {
    let client = FakeAXNotificationClient()
    let scheduler = ManualSelectionScheduler()
    let monitor: AXNotificationMonitor
    var snapshot = notificationSelectionSnapshot()
    var outcome: AXSelectionReadOutcome?
    var reader: ((AXSelectionReadContext) async -> AXSelectionReadOutcome)?
    var reads = 0
    var clears = 0
    var shows = 0
    private(set) var observer: TextSelectionObserver!

    init(monitorFocus: Int = 11) {
        client.frontmostPID = 123
        client.applicationElements[123] = FakeAXNotificationElement(stableID: 1)
        client.focusedElements[123] = FakeAXNotificationElement(stableID: monitorFocus)
        monitor = AXNotificationMonitor(client: client, notificationCenter: NotificationCenter())
        observer = TextSelectionObserver(
            accessibilityManager: AccessibilityManager(), clipboardManager: ClipboardManager(),
            selectionSnapshotReader: { [weak self] _ in self?.snapshot },
            clipboardSelectionCapture: { _ in TextSelection(text: "Synthetic held text", cursorPosition: .zero, sourceAppPID: 123) },
            scheduler: scheduler, automaticSnapshotReader: { [weak self] context in
                guard let self else { return .unavailable(focusedElementID: nil) }
                self.reads += 1
                if let reader = self.reader { return await reader(context) }
                return self.outcome ?? .snapshot(self.snapshot)
            }, frontmostPIDReader: { [weak client] in client?.frontmostPID }
        )
        observer.onSelectionCleared = { [weak self] in self?.clears += 1 }
        observer.onSelectionChanged = { [weak self] _ in self?.shows += 1 }
        observer.installAXNotificationMonitor(monitor)
        monitor.start()
    }

    func capture() async {
        _ = await observer.captureSelection(preferredSourceAppPID: 123)
        #expect(observer.currentSelection?.focusedElementID == 11)
        #expect(observer.currentSelection?.text == "Synthetic held text")
    }

    func send(_ notification: AXMonitoredNotification) async {
        // Wait for the installed monitor callback, including its MainActor hop,
        // before advancing the manual scheduler. A bare Task.yield is not a drain.
        await withCheckedContinuation { continuation in
            let forward = monitor.onPotentialSelectionChange
            monitor.onPotentialSelectionChange = { [weak monitor] pid, kind in
                forward?(pid, kind)
                monitor?.onPotentialSelectionChange = forward
                continuation.resume()
            }
            client.trigger(processIdentifier: 123, notification: notification)
        }
    }

    func settle(_ duration: TimeInterval = 0.05) async {
        scheduler.advance(by: duration)
        await observer.waitForPendingSelectionReadForTesting()
    }

    func stop() {
        observer.installAXNotificationMonitor(nil)
        observer.stopPolling()
        monitor.stop()
    }
}

@Test(arguments: AXMonitoredNotification.allCases)
@MainActor
func testInstalledAXMonitorRetainsReadOnlyNoiseWithoutPromotingOrExtendingRecovery(_ notification: AXMonitoredNotification) async {
    let fixture = NotificationSelectionFixture()
    defer { fixture.stop() }
    await fixture.capture()
    await fixture.send(notification)
    await fixture.settle()
    #expect(fixture.observer.currentSelection?.text == "Synthetic held text")

    fixture.outcome = .unavailable(focusedElementID: 11)
    fixture.observer.pollForTesting()
    await fixture.observer.waitForPendingSelectionReadForTesting()
    await fixture.send(notification)
    await fixture.settle()
    fixture.outcome = .snapshot(fixture.snapshot)
    await fixture.settle(0.05) // Original recovery +100ms, still polling-origin.
    #expect(fixture.observer.currentSelection?.text == "Synthetic held text")
    fixture.outcome = .unavailable(focusedElementID: 11)
    await fixture.settle(0.15)
    await fixture.settle(0.25) // Original +500ms deadline, without extension.
    await fixture.send(notification)
    await fixture.settle()
    let readsAfterExpiry = fixture.reads
    await fixture.settle(1)
    #expect(fixture.reads == readsAfterExpiry)
    #expect(fixture.observer.currentSelection?.text == "Synthetic held text")
    #expect(fixture.clears == 0)
    #expect(fixture.shows == 0)
}

@Test(arguments: [11, 22])
@MainActor
func testDelayedAXFocusRebindCannotClearNewerExplicitCapture(_ completedFocus: Int) async {
    let fixture = NotificationSelectionFixture(monitorFocus: 7)
    defer { fixture.stop() }
    fixture.client.deferFocusRequests = true
    await fixture.send(.focusedUIElementChanged)
    await fixture.capture() // New capture supersedes the earlier focus request.
    fixture.client.focusedElements[123] = FakeAXNotificationElement(stableID: 11)
    fixture.client.completeFocus(FakeAXNotificationElement(stableID: completedFocus))
    // Both an already-current identity and an older mismatching completion must
    // wait for fresh AX evidence instead of invalidating this newer capture.
    #expect(fixture.observer.currentSelection?.focusedElementID == 11)
    #expect(fixture.clears == 0)
    await fixture.settle()
    #expect(fixture.observer.currentSelection?.text == "Synthetic held text")
    #expect(fixture.clears == 0)
}

@MainActor
private final class NotificationControlledReader {
    private var pending: CheckedContinuation<AXSelectionReadOutcome, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func read(_ context: AXSelectionReadContext) async -> AXSelectionReadOutcome {
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ outcome: AXSelectionReadOutcome) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: outcome)
    }
}

@Test(arguments: ["settle", "active", "queued", "recovery"])
@MainActor
func testInstalledAXNoiseCannotOverridePhysicalSelectionWork(_ phase: String) async {
    let fixture = NotificationSelectionFixture()
    defer { fixture.stop() }
    await fixture.capture()
    if phase == "settle" {
        fixture.observer.checkSelectionFromEvent(frontmostPID: 123)
        await fixture.send(.valueChanged)
        await fixture.settle()
        #expect(fixture.reads == 1)
    } else if phase == "recovery" {
        fixture.outcome = .unavailable(focusedElementID: 11)
        fixture.observer.checkSelectionFromEvent(frontmostPID: 123)
        await fixture.settle()
        await fixture.send(.valueChanged)
        fixture.outcome = .snapshot(fixture.snapshot)
        await fixture.settle(0.1)
        await fixture.settle(0.4)
        #expect(fixture.reads == 2)
    } else {
        let reader = NotificationControlledReader()
        fixture.reader = { await reader.read($0) }
        if phase == "queued" {
            fixture.observer.pollForTesting()
            await reader.waitUntilStarted()
        }
        fixture.observer.checkSelectionFromEvent(frontmostPID: 123)
        fixture.scheduler.advance(by: 0.05)
        if phase == "active" { await reader.waitUntilStarted() }
        await fixture.send(.valueChanged)
        if phase == "queued" {
            fixture.observer.pollForTesting() // Lower-priority work cannot replace the queued event.
            reader.finish(.unavailable(focusedElementID: 11))
            await reader.waitUntilStarted()
        }
        reader.finish(.snapshot(fixture.snapshot))
        await fixture.observer.waitForPendingSelectionReadForTesting()
        #expect(fixture.reads == (phase == "active" ? 1 : 2))
    }
    #expect(fixture.observer.currentSelection == nil)
    #expect(fixture.clears == 1)
}

@Test(arguments: ["focus", "role", "writable", "authoritative-clear", "user-dismiss"])
@MainActor
func testInstalledAXMonitorDoesNotRetainInvalidOrDismissedReadOnlySource(_ change: String) async {
    let fixture = NotificationSelectionFixture()
    defer { fixture.stop() }
    await fixture.capture()
    switch change {
    case "focus": fixture.snapshot = notificationSelectionSnapshot(focus: 22)
    case "role": fixture.snapshot = notificationSelectionSnapshot(role: "AXTextArea", writable: true)
    case "writable": fixture.snapshot = notificationSelectionSnapshot(writable: true)
    case "authoritative-clear": fixture.outcome = .cleared
    default: fixture.observer.dismissExplicitSelectionHold()
    }
    await fixture.send(.selectedTextChanged)
    await fixture.settle()
    await fixture.settle(1)
    #expect(fixture.observer.currentSelection == nil)
    #expect(fixture.clears == 1)
    #expect(fixture.shows == 0)
}

@Test(arguments: AXMonitoredNotification.allCases)
@MainActor
func testOrdinaryAXNotificationCaptureKeepsEventMode(_ notification: AXMonitoredNotification) async {
    let fixture = NotificationSelectionFixture()
    defer { fixture.stop() }
    fixture.snapshot = notificationSelectionSnapshot(role: "AXTextArea", writable: true, text: "Selected editor text")
    await fixture.send(notification)
    await fixture.settle()
    #expect(fixture.observer.currentCaptureResult?.captureMode == .event)
    #expect(fixture.shows == 1)
}

@Test @MainActor
func testOrdinaryAXNotificationSupersedesAnOlderInFlightPhysicalSnapshot() async {
    let fixture = NotificationSelectionFixture()
    defer { fixture.stop() }
    let first = notificationSelectionSnapshot(role: "AXTextArea", writable: true, text: "Editor selection A")
    let latest = notificationSelectionSnapshot(role: "AXTextArea", writable: true, text: "Editor selection B")
    let reader = NotificationControlledReader()
    var firstRead = true
    fixture.reader = { context in
        if firstRead {
            firstRead = false
            return await reader.read(context)
        }
        return .snapshot(latest)
    }
    var published: [String] = []
    fixture.observer.onSelectionChanged = { published.append($0.selection.text) }
    fixture.observer.checkSelectionFromEvent(frontmostPID: 123)
    fixture.scheduler.advance(by: 0.05)
    await reader.waitUntilStarted()
    fixture.snapshot = latest
    await fixture.send(.selectedTextChanged)
    fixture.scheduler.advance(by: 0.05)
    reader.finish(.snapshot(first))
    await fixture.observer.waitForPendingSelectionReadForTesting()
    #expect(fixture.reads == 2)
    #expect(published == ["Editor selection B"])
    #expect(fixture.observer.currentSelection?.text == "Editor selection B")
    #expect(fixture.observer.currentCaptureResult?.captureMode == .event)
}
