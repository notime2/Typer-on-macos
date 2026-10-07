// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Sparkle

/// Sparkle updater. `AppDelegate` creates it only for a normal launch, never under XCTest or
/// stream replay, so tests and replay never reach the update feed.
@MainActor
final class AppUpdater: NSObject {
    private var controller: SPUStandardUpdaterController!

    /// Version a scheduled check found and left waiting; the status bar menu shows it.
    private(set) var pendingUpdateVersion: String?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    var updater: SPUUpdater { controller.updater }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

// A menu-bar app has no Dock icon to badge, so a scheduled check that finds an update surfaces
// it in the status bar menu instead of stealing focus.
extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        pendingUpdateVersion = update.displayVersionString
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingUpdateVersion = nil
    }
}
