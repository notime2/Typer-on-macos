// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    let environment: AppEnvironment
    private var coordinator: AppCoordinator?
    private var onboardingController: OnboardingWindowController?

    override init() {
        do {
            let fixture = AppRuntime.isRunningTests
                ? nil
                : try StreamReplayFixture.fromLaunchArguments(ProcessInfo.processInfo.arguments)
            environment = AppEnvironment(streamReplayFixture: fixture)
        } catch {
            Log.app.error("Stream replay launch rejected: \(error.localizedDescription, privacy: .public)")
            exit(64)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppRuntime.isRunningTests else {
            Log.app.info("Running under XCTest - skipping app bootstrap")
            return
        }

        environment.bootstrap()

        coordinator = AppCoordinator(environment: environment)
        coordinator?.start()

        if !environment.isStreamReplay {
            environment.appUpdater = AppUpdater()
        }

        onboardingController = OnboardingWindowController(environment: environment)
        statusBarController = StatusBarController(
            environment: environment,
            coordinator: coordinator!,
            onboardingController: onboardingController!
        )

        if environment.isStreamReplay {
            environment.accessibilityManager.checkPermission()
            Log.app.info("Local stream replay enabled; AI and catalog network requests are disabled")
        } else if OnboardingWindowController.needsOnboarding {
            onboardingController?.show()
        } else {
            environment.accessibilityManager.checkPermission()
            if !environment.accessibilityManager.isTrusted {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
            }
        }

        Log.app.info("Typer On launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
