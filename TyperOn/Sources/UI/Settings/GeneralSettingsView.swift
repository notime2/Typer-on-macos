// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    let environment: AppEnvironment

    @State private var launchAtLogin = false
    @State private var autoDetectSelection: Bool
    @State private var selectionTriggerStyle: SelectionTriggerStyle
    @State private var defaultLanguage: String
    @State private var currentCombo: KeyCombo
    @State private var hotkeyErrorMessage: String?
    @State private var permissionController: AccessibilityPermissionStatusController
    @State private var checksForUpdates: Bool
    @State private var installsUpdates: Bool

    init(
        environment: AppEnvironment
    ) {
        self.environment = environment
        let savedAutoDetect = UserDefaults.standard.autoDetectSelectionEnabled
        _autoDetectSelection = State(initialValue: savedAutoDetect)
        _selectionTriggerStyle = State(initialValue: UserDefaults.standard.selectionTriggerStyle)
        _defaultLanguage = State(initialValue: UserDefaults.standard.defaultTargetLanguage)
        let savedCombo = KeyCombo.load() ?? KeyCombo.defaultGlobalHotkey
        _currentCombo = State(initialValue: savedCombo)
        let updater = environment.appUpdater?.updater
        _checksForUpdates = State(initialValue: updater?.automaticallyChecksForUpdates ?? false)
        _installsUpdates = State(initialValue: updater?.automaticallyDownloadsUpdates ?? false)
        _permissionController = State(initialValue: AccessibilityPermissionStatusController(
            permissionChecker: {
                environment.accessibilityManager.checkPermission()
                return environment.accessibilityManager.isTrusted
            },
            openSettingsHandler: {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                NSWorkspace.shared.open(url)
            }
        ))
    }

    var body: some View {
        contentContainer
            .onAppear {
                launchAtLogin = SMAppService.mainApp.status == .enabled
                autoDetectSelection = UserDefaults.standard.autoDetectSelectionEnabled
                selectionTriggerStyle = UserDefaults.standard.selectionTriggerStyle
                permissionController.start()
            }
            .onDisappear {
                permissionController.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: .autoDetectSelectionChanged)) { _ in
                autoDetectSelection = UserDefaults.standard.autoDetectSelectionEnabled
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectionTriggerStyleChanged)) { _ in
                selectionTriggerStyle = UserDefaults.standard.selectionTriggerStyle
            }
    }

    private var contentContainer: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DS.Colors.background)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xl) {
            settingRow("Launch at Login", description: "Start Typer On when you log in") {
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            Divider().foregroundStyle(DS.Colors.separator)

            settingRow("Auto-Detect Selection", description: "Show the floating toolbar automatically when text selection changes") {
                Toggle("", isOn: $autoDetectSelection)
                    .toggleStyle(.switch)
                    .onChange(of: autoDetectSelection) { _, newValue in
                        UserDefaults.standard.setAutoDetectSelectionEnabled(newValue)
                        NotificationCenter.default.post(name: .autoDetectSelectionChanged, object: nil)
                    }
            }

            Divider().foregroundStyle(DS.Colors.separator)

            sectionHeader("Appearance")

            settingRow("Interface Theme", description: "Apply a theme to the floating panel, Chat and Processing windows") {
                Picker("", selection: $selectionTriggerStyle) {
                    ForEach(SelectionTriggerStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .frame(width: 170)
                .onChange(of: selectionTriggerStyle) { _, newValue in
                    UserDefaults.standard.setSelectionTriggerStyle(newValue)
                    NotificationCenter.default.post(name: .selectionTriggerStyleChanged, object: nil)
                }
            }

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Preview")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textSecondary)

                SelectionStylePreviewStrip(selectedStyle: $selectionTriggerStyle)
            }

            Divider().foregroundStyle(DS.Colors.separator)

            sectionHeader("Translation")

            settingRow("Default Language", description: "Target language for translation. Follows your system language until you pick one. Text already in this language is translated to English, or to your next system language when the default is English.") {
                Picker("", selection: $defaultLanguage) {
                    ForEach(TargetLanguageCatalog.supportedLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .frame(width: 160)
                .onChange(of: defaultLanguage) { _, newValue in
                    UserDefaults.standard.setDefaultTargetLanguage(newValue)
                }
            }

            Divider().foregroundStyle(DS.Colors.separator)

            sectionHeader("Accessibility")

            settingRow("Permission Status", description: "Required to detect selected text in other apps") {
                HStack(spacing: DS.Spacing.sm) {
                    Circle()
                        .fill(permissionController.isGranted ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(permissionController.isGranted ? "Granted" : "Not Granted")
                        .font(.system(size: 13))

                    Button("Refresh") {
                        permissionController.refresh()
                    }
                    .font(.system(size: 12))
                    .buttonStyle(.glass)

                    if !permissionController.isGranted {
                        Button("Open Settings") {
                            permissionController.openSettings()
                        }
                        .font(.system(size: 12))
                        .buttonStyle(.glass)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            Divider().foregroundStyle(DS.Colors.separator)

            sectionHeader("Shortcut")

            settingRow("Trigger", description: "Click to record a new shortcut") {
                VStack(alignment: .trailing, spacing: DS.Spacing.xs) {
                    HStack(spacing: DS.Spacing.sm) {
                        HotkeyRecorderView(
                            combo: currentCombo,
                            onRecord: { newCombo in
                                applyHotkey(newCombo)
                            },
                            onRecordingChanged: { recording in
                                if recording {
                                    environment.hotkeyManager?.suspend()
                                } else {
                                    try? environment.hotkeyManager?.resume()
                                }
                            }
                        )

                        Button {
                            applyHotkey(KeyCombo.defaultGlobalHotkey)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.glass)
                        .help("Reset to default (\(KeyCombo.defaultGlobalHotkey.displayString))")
                        .disabled(currentCombo == KeyCombo.defaultGlobalHotkey)
                    }

                    if let errorMsg = hotkeyErrorMessage {
                        Text(errorMsg)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
            }

            if let updater = environment.appUpdater?.updater {
                Divider().foregroundStyle(DS.Colors.separator)

                sectionHeader("Updates")

                settingRow("Automatically check for updates", description: "Look for a new version on GitHub once a day") {
                    Toggle("", isOn: $checksForUpdates)
                        .toggleStyle(.switch)
                        .onChange(of: checksForUpdates) { _, newValue in
                            updater.automaticallyChecksForUpdates = newValue
                        }
                }

                settingRow("Automatically download and install updates", description: "Install a new version in the background; it takes effect on the next launch") {
                    Toggle("", isOn: $installsUpdates)
                        .toggleStyle(.switch)
                        .disabled(!checksForUpdates)
                        .onChange(of: installsUpdates) { _, newValue in
                            updater.automaticallyDownloadsUpdates = newValue
                        }
                }
            }
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.background)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.Colors.textSecondary)
            .textCase(.uppercase)
    }

    private func settingRow<Content: View>(_ title: String, description: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(description).font(.system(size: 12)).foregroundStyle(DS.Colors.textTertiary)
            }
            Spacer()
            content()
        }
    }

    private func applyHotkey(_ newCombo: KeyCombo) {
        guard let manager = environment.hotkeyManager else { return }
        do {
            try manager.applyRegistrations([
                HotkeyRegistration(id: "globalTrigger", combo: newCombo)
            ])
            currentCombo = newCombo
            newCombo.save()
            hotkeyErrorMessage = nil
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
        } catch let error as HotkeyManagerError {
            switch error {
            case .registrationConflict:
                hotkeyErrorMessage = "Shortcut is unavailable. Choose another combination."
            default:
                hotkeyErrorMessage = "Could not activate shortcut. Try another combination."
            }
        } catch {
            hotkeyErrorMessage = "Could not activate shortcut. Try another combination."
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Launch at login failed: \(error)")
        }
    }
}
