// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit

@MainActor
@Observable
final class AccessibilityPermissionStatusController {
    private let permissionChecker: () -> Bool
    private let openSettingsHandler: () -> Void
    private let notificationCenter: NotificationCenter
    private let didBecomeActiveNotification: Notification.Name

    private var appDidBecomeActiveObserver: Any?

    private(set) var isGranted = false
    private(set) var isStarted = false

    init(
        permissionChecker: @escaping () -> Bool,
        openSettingsHandler: @escaping () -> Void,
        notificationCenter: NotificationCenter = .default,
        didBecomeActiveNotification: Notification.Name = NSApplication.didBecomeActiveNotification
    ) {
        self.permissionChecker = permissionChecker
        self.openSettingsHandler = openSettingsHandler
        self.notificationCenter = notificationCenter
        self.didBecomeActiveNotification = didBecomeActiveNotification
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        refresh()

        appDidBecomeActiveObserver = notificationCenter.addObserver(
            forName: didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        if let appDidBecomeActiveObserver {
            notificationCenter.removeObserver(appDidBecomeActiveObserver)
            self.appDidBecomeActiveObserver = nil
        }
    }

    func refresh() {
        isGranted = permissionChecker()
    }

    func openSettings() {
        openSettingsHandler()
    }
}
