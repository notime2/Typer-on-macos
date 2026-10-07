// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import ApplicationServices

enum AXMonitoredNotification: String, CaseIterable, Sendable {
    case selectedTextChanged = "AXSelectedTextChanged"
    case valueChanged = "AXValueChanged"
    case focusedUIElementChanged = "AXFocusedUIElementChanged"

    var cfString: CFString {
        rawValue as CFString
    }
}

protocol AXNotificationElementHandle: AnyObject {
    var stableID: Int { get }
}

protocol AXNotificationObserverHandle: AnyObject {
    var processIdentifier: pid_t { get }
}

protocol AXNotificationMonitoringClient {
    func frontmostProcessIdentifier() -> pid_t?
    func makeObserver(
        processIdentifier: pid_t,
        callback: @escaping (AXMonitoredNotification, pid_t) -> Void
    ) -> AXNotificationObserverHandle?
    func applicationElement(processIdentifier: pid_t) -> AXNotificationElementHandle?
    func focusedElement(processIdentifier: pid_t) -> AXNotificationElementHandle?
    @MainActor func requestFocusedElement(processIdentifier: pid_t,
        completion: @escaping @MainActor @Sendable (AXNotificationElementHandle?) -> Void)
    func add(
        notification: AXMonitoredNotification,
        observer: AXNotificationObserverHandle,
        element: AXNotificationElementHandle
    ) -> Bool
    func remove(
        notification: AXMonitoredNotification,
        observer: AXNotificationObserverHandle,
        element: AXNotificationElementHandle
    )
    func attachToRunLoop(observer: AXNotificationObserverHandle)
    func detachFromRunLoop(observer: AXNotificationObserverHandle)
}

extension AXNotificationMonitoringClient {
    @MainActor func requestFocusedElement(processIdentifier: pid_t,
        completion: @escaping @MainActor @Sendable (AXNotificationElementHandle?) -> Void) {
        completion(focusedElement(processIdentifier: processIdentifier))
    }
}

private final class AXNotificationMonitorBox: @unchecked Sendable {
    weak var monitor: AXNotificationMonitor?

    init(_ monitor: AXNotificationMonitor) {
        self.monitor = monitor
    }
}

@MainActor
final class AXNotificationMonitor {
    private let client: AXNotificationMonitoringClient
    private let notificationCenter: NotificationCenter

    private var workspaceObserver: Any?
    private var observerHandle: AXNotificationObserverHandle?
    private var applicationElement: AXNotificationElementHandle?
    private var focusedElement: AXNotificationElementHandle?
    private var installedApplicationNotifications: Set<AXMonitoredNotification> = []
    private var installedFocusedNotifications: Set<AXMonitoredNotification> = []
    private var currentProcessIdentifier: pid_t?
    private var bindingGeneration = 0
    private var focusReadActive = false
    private var pendingFocusPID: pid_t?

    var onPotentialSelectionChange: ((pid_t, AXMonitoredNotification) -> Void)?
    var onFocusedElementChanged: ((pid_t, Int?) -> Void)?

    var isRunning: Bool {
        workspaceObserver != nil || observerHandle != nil
    }

    init(
        client: AXNotificationMonitoringClient = SystemAXNotificationClient(),
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.client = client
        self.notificationCenter = notificationCenter
    }

    func start() {
        guard workspaceObserver == nil else { return }
        let monitorBox = AXNotificationMonitorBox(self)

        workspaceObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                monitorBox.monitor?.rebindToFrontmostApplication()
            }
        }

        rebindToFrontmostApplication()
    }

    func stop() {
        tearDownCurrentBinding()

        if let workspaceObserver {
            notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    func rebindToFrontmostApplication() {
        guard let processIdentifier = client.frontmostProcessIdentifier(),
              processIdentifier > 0 else {
            tearDownCurrentBinding()
            return
        }

        if currentProcessIdentifier != processIdentifier || observerHandle == nil {
            tearDownCurrentBinding()
            bind(to: processIdentifier)
            return
        }

        rebindFocusedElementNotifications(for: processIdentifier)
    }

    private func bind(to processIdentifier: pid_t) {
        let monitorBox = AXNotificationMonitorBox(self)
        guard let observerHandle = client.makeObserver(
            processIdentifier: processIdentifier,
            callback: { notification, processIdentifier in
                Task { @MainActor in
                    monitorBox.monitor?.handle(notification: notification, processIdentifier: processIdentifier)
                }
            }
        ) else {
            Log.accessibility.warning("AX notification monitor unavailable for pid \(processIdentifier)")
            return
        }

        client.attachToRunLoop(observer: observerHandle)
        self.observerHandle = observerHandle
        currentProcessIdentifier = processIdentifier
        applicationElement = client.applicationElement(processIdentifier: processIdentifier)

        if let applicationElement {
            if client.add(
                notification: .focusedUIElementChanged,
                observer: observerHandle,
                element: applicationElement
            ) {
                installedApplicationNotifications.insert(.focusedUIElementChanged)
            }
        }

        rebindFocusedElementNotifications(for: processIdentifier)
        Log.accessibility.info("AX notification monitor bound to pid \(processIdentifier)")
    }

    private func rebindFocusedElementNotifications(for processIdentifier: pid_t) {
        guard observerHandle != nil else { return }
        if focusReadActive {
            pendingFocusPID = processIdentifier
            return
        }
        focusReadActive = true
        let generation = bindingGeneration
        client.requestFocusedElement(processIdentifier: processIdentifier) { [weak self] element in
            guard let self else { return }
            self.focusReadActive = false
            if self.bindingGeneration == generation, self.currentProcessIdentifier == processIdentifier,
               self.client.frontmostProcessIdentifier() == processIdentifier {
                // A failed focus read must not discard a valid subscription.
                if let element { self.installFocusedElement(element, for: processIdentifier) }
            }
            if let pending = self.pendingFocusPID {
                self.pendingFocusPID = nil
                self.rebindFocusedElementNotifications(for: pending)
            }
        }
    }

    private func installFocusedElement(_ nextFocusedElement: AXNotificationElementHandle?, for processIdentifier: pid_t) {
        guard let observerHandle, focusedElement?.stableID != nextFocusedElement?.stableID else { return }
        let hadFocusedElement = focusedElement != nil
        if let focusedElement {
            for notification in installedFocusedNotifications {
                client.remove(notification: notification, observer: observerHandle, element: focusedElement)
            }
        }

        installedFocusedNotifications.removeAll()
        focusedElement = nextFocusedElement
        if hadFocusedElement {
            onFocusedElementChanged?(processIdentifier, nextFocusedElement?.stableID)
            onPotentialSelectionChange?(processIdentifier, .focusedUIElementChanged)
        }

        guard let nextFocusedElement else { return }

        for notification in [AXMonitoredNotification.selectedTextChanged, .valueChanged] {
            if client.add(notification: notification, observer: observerHandle, element: nextFocusedElement) {
                installedFocusedNotifications.insert(notification)
            }
        }
    }

    private func handle(notification: AXMonitoredNotification, processIdentifier: pid_t) {
        guard currentProcessIdentifier == processIdentifier,
              client.frontmostProcessIdentifier() == processIdentifier else { return }
        if notification == .focusedUIElementChanged {
            rebindFocusedElementNotifications(for: processIdentifier)
        }

        Log.accessibility.debug("AX notification received: type=\(notification.rawValue, privacy: .public) pid=\(processIdentifier)")
        onPotentialSelectionChange?(processIdentifier, notification)
    }

    private func tearDownCurrentBinding() {
        bindingGeneration += 1
        pendingFocusPID = nil
        if let observerHandle,
           let applicationElement {
            for notification in installedApplicationNotifications {
                client.remove(notification: notification, observer: observerHandle, element: applicationElement)
            }
        }

        if let observerHandle,
           let focusedElement {
            for notification in installedFocusedNotifications {
                client.remove(notification: notification, observer: observerHandle, element: focusedElement)
            }
        }

        installedApplicationNotifications.removeAll()
        installedFocusedNotifications.removeAll()
        applicationElement = nil
        focusedElement = nil
        currentProcessIdentifier = nil

        if let observerHandle {
            client.detachFromRunLoop(observer: observerHandle)
            self.observerHandle = nil
        }
    }
}

private final class SystemAXNotificationClient: AXNotificationMonitoringClient {
    private let focusQueue = DispatchQueue(label: "typer-on.ax-notification-focus", qos: .userInitiated)

    @MainActor func requestFocusedElement(processIdentifier: pid_t,
        completion: @escaping @MainActor @Sendable (AXNotificationElementHandle?) -> Void) {
        focusQueue.async {
            let handle = Self.readFocusedElement(processIdentifier: processIdentifier)
            Task { @MainActor in completion(handle) }
        }
    }

    func frontmostProcessIdentifier() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func makeObserver(
        processIdentifier: pid_t,
        callback: @escaping (AXMonitoredNotification, pid_t) -> Void
    ) -> AXNotificationObserverHandle? {
        SystemAXObserverHandle(processIdentifier: processIdentifier, callback: callback)
    }

    func applicationElement(processIdentifier: pid_t) -> AXNotificationElementHandle? {
        SystemAXElementHandle(element: AXUIElementCreateApplication(processIdentifier))
    }

    func focusedElement(processIdentifier: pid_t) -> AXNotificationElementHandle? {
        Self.readFocusedElement(processIdentifier: processIdentifier)
    }

    private static func readFocusedElement(processIdentifier: pid_t) -> SystemAXElementHandle? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.05)
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard result == .success,
              let focusedElement = focusedElement as! AXUIElement? else {
            return nil
        }
        AXUIElementSetMessagingTimeout(focusedElement, 0.05)
        return SystemAXElementHandle(element: focusedElement)
    }

    func add(
        notification: AXMonitoredNotification,
        observer: AXNotificationObserverHandle,
        element: AXNotificationElementHandle
    ) -> Bool {
        guard let observer = observer as? SystemAXObserverHandle,
              let element = element as? SystemAXElementHandle else {
            return false
        }

        let result = AXObserverAddNotification(
            observer.observer,
            element.element,
            notification.cfString,
            observer.callbackUserData
        )
        return result == .success
    }

    func remove(
        notification: AXMonitoredNotification,
        observer: AXNotificationObserverHandle,
        element: AXNotificationElementHandle
    ) {
        guard let observer = observer as? SystemAXObserverHandle,
              let element = element as? SystemAXElementHandle else {
            return
        }

        AXObserverRemoveNotification(observer.observer, element.element, notification.cfString)
    }

    func attachToRunLoop(observer: AXNotificationObserverHandle) {
        guard let observer = observer as? SystemAXObserverHandle else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer.observer), .commonModes)
    }

    func detachFromRunLoop(observer: AXNotificationObserverHandle) {
        guard let observer = observer as? SystemAXObserverHandle else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer.observer), .commonModes)
    }
}

// The immutable AX reference is transferred after the worker finishes reading it;
// notification registration and subsequent access belong to MainActor.
private final class SystemAXElementHandle: AXNotificationElementHandle, @unchecked Sendable {
    let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    var stableID: Int {
        Int(CFHash(element))
    }
}

private final class SystemAXObserverHandle: AXNotificationObserverHandle {
    final class CallbackBox {
        let processIdentifier: pid_t
        let callback: (AXMonitoredNotification, pid_t) -> Void

        init(
            processIdentifier: pid_t,
            callback: @escaping (AXMonitoredNotification, pid_t) -> Void
        ) {
            self.processIdentifier = processIdentifier
            self.callback = callback
        }
    }

    let processIdentifier: pid_t
    let observer: AXObserver
    let callbackUserData: UnsafeMutableRawPointer

    private let retainedCallbackBox: CallbackBox

    init?(processIdentifier: pid_t, callback: @escaping (AXMonitoredNotification, pid_t) -> Void) {
        var observer: AXObserver?
        let callbackBox = CallbackBox(
            processIdentifier: processIdentifier,
            callback: callback
        )
        let callbackUserData = UnsafeMutableRawPointer(Unmanaged.passRetained(callbackBox).toOpaque())
        let result = AXObserverCreate(processIdentifier, Self.callback, &observer)

        guard result == .success,
              let observer else {
            Unmanaged<CallbackBox>.fromOpaque(callbackUserData).release()
            return nil
        }

        self.processIdentifier = processIdentifier
        self.observer = observer
        self.retainedCallbackBox = callbackBox
        self.callbackUserData = callbackUserData
    }

    deinit {
        Unmanaged<CallbackBox>.fromOpaque(callbackUserData).release()
    }

    private static let callback: AXObserverCallback = { _, _, notification, userData in
        guard let userData else { return }
        let callbackBox = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
        let notificationName = notification as String
        guard let monitoredNotification = AXMonitoredNotification(rawValue: notificationName) else { return }
        callbackBox.callback(monitoredNotification, callbackBox.processIdentifier)
    }
}
