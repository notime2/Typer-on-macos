// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Testing
@testable import Typer_On

@Test
@MainActor
func testRefreshUpdatesGrantedStateFromPermissionChecker() {
    var isGranted = false
    let controller = AccessibilityPermissionStatusController(
        permissionChecker: { isGranted },
        openSettingsHandler: {}
    )

    #expect(controller.isGranted == false)

    isGranted = true
    controller.refresh()

    #expect(controller.isGranted == true)
}

@Test
@MainActor
func testStartPerformsInitialRefresh() {
    let controller = AccessibilityPermissionStatusController(
        permissionChecker: { true },
        openSettingsHandler: {},
        notificationCenter: NotificationCenter(),
        didBecomeActiveNotification: Notification.Name("permission-status-tests.didBecomeActive")
    )

    #expect(controller.isGranted == false)
    #expect(controller.isStarted == false)

    controller.start()

    #expect(controller.isGranted == true)
    #expect(controller.isStarted == true)
}

@Test
@MainActor
func testDidBecomeActiveNotificationRefreshesGrantedStateAfterStart() async {
    let notificationCenter = NotificationCenter()
    let didBecomeActiveNotification = Notification.Name("permission-status-tests.didBecomeActive")
    var isGranted = false

    let controller = AccessibilityPermissionStatusController(
        permissionChecker: { isGranted },
        openSettingsHandler: {},
        notificationCenter: notificationCenter,
        didBecomeActiveNotification: didBecomeActiveNotification
    )

    controller.start()
    #expect(controller.isGranted == false)

    isGranted = true
    notificationCenter.post(name: didBecomeActiveNotification, object: nil)
    await Task.yield()

    #expect(controller.isGranted == true)
}

@Test
@MainActor
func testDidBecomeActiveNotificationDoesNotRefreshAfterStop() async {
    let notificationCenter = NotificationCenter()
    let didBecomeActiveNotification = Notification.Name("permission-status-tests.didBecomeActive")
    var isGranted = false

    let controller = AccessibilityPermissionStatusController(
        permissionChecker: { isGranted },
        openSettingsHandler: {},
        notificationCenter: notificationCenter,
        didBecomeActiveNotification: didBecomeActiveNotification
    )

    controller.start()
    controller.stop()

    isGranted = true
    notificationCenter.post(name: didBecomeActiveNotification, object: nil)
    await Task.yield()

    #expect(controller.isGranted == false)
    #expect(controller.isStarted == false)
}

@Test
@MainActor
func testRepeatedStartDoesNotDuplicateObserverRefreshesOnlyOncePerNotification() async {
    let notificationCenter = NotificationCenter()
    let didBecomeActiveNotification = Notification.Name("permission-status-tests.didBecomeActive")
    var isGranted = false
    var refreshCallCount = 0

    let controller = AccessibilityPermissionStatusController(
        permissionChecker: {
            refreshCallCount += 1
            return isGranted
        },
        openSettingsHandler: {},
        notificationCenter: notificationCenter,
        didBecomeActiveNotification: didBecomeActiveNotification
    )

    controller.start()
    controller.start()
    #expect(refreshCallCount == 1)

    isGranted = true
    notificationCenter.post(name: didBecomeActiveNotification, object: nil)
    await Task.yield()

    #expect(refreshCallCount == 2)
    #expect(controller.isGranted == true)
}
