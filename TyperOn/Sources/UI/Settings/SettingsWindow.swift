// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let environment: AppEnvironment
    private let state: SettingsWindowState
    private let sizePreferences: SettingsWindowSizePreferences
    private var isApplyingProgrammaticResize = false

    private let fallbackVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

    init(environment: AppEnvironment, state: SettingsWindowState, userDefaults: UserDefaults = .standard) {
        self.environment = environment
        self.state = state
        self.sizePreferences = SettingsWindowSizePreferences(
            defaults: userDefaults,
            persistsChanges: !environment.isStreamReplay
        )
        super.init()
    }

    func show(tab: SettingsTab = .general) {
        state.selectedTab = tab

        if let window {
            applyWindowSizing(window, centerWindow: !window.isVisible)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: SettingsView(environment: environment, state: state))
        // The window policy owns sizing; long detail content is reachable through scrolling.
        hostingView.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowSizingPolicy.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Typer On Settings"
        // The sidebar runs the full window height under a transparent titlebar, and the tab
        // name is drawn once over the detail column, so the window title stays hidden.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hostingView
        window.delegate = self
        applyWindowSizing(window, centerWindow: true)
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !isApplyingProgrammaticResize,
              let window = notification.object as? NSWindow,
              window == self.window else { return }
        sizePreferences.save(window.contentRect(forFrameRect: window.frame).size)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard !isApplyingProgrammaticResize,
              let window = notification.object as? NSWindow,
              !window.inLiveResize,
              window == self.window else { return }
        applyWindowSizing(window, centerWindow: false)
    }

    private func applyWindowSizing(_ window: NSWindow, centerWindow: Bool) {
        isApplyingProgrammaticResize = true
        defer { isApplyingProgrammaticResize = false }

        let availableFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? fallbackVisibleFrame
        let availableContentSize = window.contentRect(forFrameRect: availableFrame).size
        window.contentMinSize = SettingsWindowSizingPolicy.clampedContentSize(
            SettingsWindowSizingPolicy.defaultMinimumContentSize,
            minimumContentSize: SettingsWindowSizingPolicy.defaultMinimumContentSize,
            availableContentSize: availableContentSize
        )
        window.setContentSize(SettingsWindowSizingPolicy.resolvedContentSize(
            savedContentSize: sizePreferences.preferredContentSize(),
            availableContentSize: availableContentSize
        ))
        if centerWindow {
            window.center()
        }
        let origin = NSPoint(
            x: min(max(window.frame.minX, availableFrame.minX), availableFrame.maxX - window.frame.width),
            y: min(max(window.frame.minY, availableFrame.minY), availableFrame.maxY - window.frame.height)
        )
        window.setFrameOrigin(origin)
    }
}

struct SettingsWindowSizePreferences {
    static let currentVersion = 1
    let defaults: UserDefaults
    let persistsChanges: Bool

    func preferredContentSize() -> CGSize {
        guard defaults.integer(for: .settingsWindowSizingVersion) >= Self.currentVersion else {
            let size = SettingsWindowSizingPolicy.defaultContentSize
            if persistsChanges {
                save(size)
                defaults.set(Self.currentVersion, for: .settingsWindowSizingVersion)
            }
            return size
        }
        let width = defaults.double(for: .settingsWindowWidth)
        let height = defaults.double(for: .settingsWindowHeight)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return SettingsWindowSizingPolicy.defaultContentSize
        }
        return CGSize(width: width, height: height)
    }

    func save(_ size: CGSize) {
        guard persistsChanges else { return }
        defaults.set(size.width, for: .settingsWindowWidth)
        defaults.set(size.height, for: .settingsWindowHeight)
    }
}

@MainActor
final class SettingsWindowState: ObservableObject {
    @Published var selectedTab: SettingsTab = .general
    @Published private(set) var isAddingCustomPrompt = false

    private var shouldReturnToModulesAfterPromptCreation = false

    func beginCustomPromptCreation(returnToModules: Bool) {
        shouldReturnToModulesAfterPromptCreation = returnToModules
        isAddingCustomPrompt = true
        selectedTab = .customPrompts
    }

    func cancelCustomPromptCreation() {
        isAddingCustomPrompt = false
        shouldReturnToModulesAfterPromptCreation = false
    }

    func completeCustomPromptCreation() {
        isAddingCustomPrompt = false

        if shouldReturnToModulesAfterPromptCreation {
            selectedTab = .modules
        }

        shouldReturnToModulesAfterPromptCreation = false
    }
}

struct SettingsWindowSizingPolicy {
    static let sidebarIdealWidth: CGFloat = 180
    static let defaultMinimumContentSize = CGSize(width: 580, height: 576)

    static let defaultContentSize = CGSize(width: 760, height: 620)

    static func resolvedContentSize(
        savedContentSize: CGSize?,
        availableContentSize: CGSize
    ) -> CGSize {
        clampedContentSize(
            savedContentSize ?? defaultContentSize,
            minimumContentSize: defaultMinimumContentSize,
            availableContentSize: availableContentSize
        )
    }

    static func clampedContentSize(
        _ contentSize: CGSize,
        minimumContentSize: CGSize,
        availableContentSize: CGSize
    ) -> CGSize {
        let maxWidth = max(availableContentSize.width, 1)
        let maxHeight = max(availableContentSize.height, 1)
        let minWidth = min(minimumContentSize.width, maxWidth)
        let minHeight = min(minimumContentSize.height, maxHeight)

        return CGSize(
            width: min(max(contentSize.width, minWidth), maxWidth),
            height: min(max(contentSize.height, minHeight), maxHeight)
        )
    }
}

struct SettingsView: View {
    let environment: AppEnvironment
    @ObservedObject var state: SettingsWindowState

    var body: some View {
        NavigationSplitView {
            List(SettingsSidebarItem.all, selection: selectedTabBinding) { item in
                SettingsSidebarRow(item: item)
            }
            .listStyle(.sidebar)
            // Settings has five fixed tabs; a collapse toggle would only hide them.
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(
                min: SettingsWindowSizingPolicy.sidebarIdealWidth,
                ideal: SettingsWindowSizingPolicy.sidebarIdealWidth,
                max: SettingsWindowSizingPolicy.sidebarIdealWidth
            )
        } detail: {
            SettingsDetailScaffold(title: state.selectedTab.title) {
                SettingsDetailView(
                    environment: environment,
                    state: state
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var selectedTabBinding: Binding<SettingsTab?> {
        Binding {
            state.selectedTab
        } set: { tab in
            if let tab {
                state.selectedTab = tab
            }
        }
    }
}

struct SettingsDetailView: View {
    let environment: AppEnvironment
    @ObservedObject var state: SettingsWindowState

    var body: some View {
        Group {
            switch state.selectedTab {
            case .general:
                GeneralSettingsView(environment: environment)
            case .api:
                APISettingsView(environment: environment)
            case .modules:
                ModulesSettingsView(
                    environment: environment,
                    onAddCustomModule: {
                        state.beginCustomPromptCreation(returnToModules: true)
                    }
                )
            case .customPrompts:
                CustomPromptsSettingsView(
                    environment: environment,
                    state: state
                )
            case .chatHistory:
                ChatHistorySettingsView(environment: environment)
            }
        }
    }
}

enum SettingsTab: String, CaseIterable {
    case general
    case api
    case modules
    case customPrompts
    case chatHistory

    var title: String {
        switch self {
        case .general: "General"
        case .api: "API \\ Models"
        case .modules: "Modules"
        case .customPrompts: "Custom Modules"
        case .chatHistory: "Chat History"
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .api: "key"
        case .modules: "square.stack.3d.up"
        case .customPrompts: "text.bubble"
        case .chatHistory: "clock.arrow.circlepath"
        }
    }
}
