// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let environment: AppEnvironment
    private weak var coordinator: AppCoordinator?
    private let onboardingController: OnboardingWindowController
    private let globalAPIKeyProvider: () -> String?
    private var frontmostAppPIDBeforeMenuOpen: pid_t?

    init(
        environment: AppEnvironment,
        coordinator: AppCoordinator,
        onboardingController: OnboardingWindowController,
        globalAPIKeyProvider: (() -> String?)? = nil
    ) {
        self.environment = environment
        self.coordinator = coordinator
        self.onboardingController = onboardingController
        self.globalAPIKeyProvider = globalAPIKeyProvider ?? { environment.keychainService.getGlobalAPIKey() }
        super.init()
        setupStatusBar()

        NotificationCenter.default.addObserver(
            self, selector: #selector(hotkeyDidChange), name: .hotkeyChanged, object: nil
        )
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "Typer On")
        button.image?.size = NSSize(width: 18, height: 18)

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu

        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        rebuildMenu(menu: menu)
    }

    private func rebuildMenu(menu: NSMenu) {
        menu.removeAllItems()

        // Header
        let headerItem = NSMenuItem(title: "Typer On", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Capture text
        let combo = KeyCombo.load() ?? KeyCombo.defaultGlobalHotkey
        let captureItem = NSMenuItem(title: "Capture Selected Text", action: #selector(captureText), keyEquivalent: combo.keyEquivalentCharacter)
        captureItem.keyEquivalentModifierMask = combo.nsEventModifierFlags
        captureItem.target = self
        menu.addItem(captureItem)

        let openChatItem = NSMenuItem(title: "Open Chat Window", action: #selector(openChatWindow), keyEquivalent: "")
        openChatItem.target = self
        menu.addItem(openChatItem)

        let chatHistoryItem = NSMenuItem(title: "Chat History", action: nil, keyEquivalent: "")
        chatHistoryItem.submenu = chatHistorySubmenu()
        menu.addItem(chatHistoryItem)

        let isAutoDetectEnabled = UserDefaults.standard.autoDetectSelectionEnabled
        let autoDetectItem = NSMenuItem(
            title: isAutoDetectEnabled ? "Pause Auto-Detect" : "Resume Auto-Detect",
            action: #selector(toggleAutoDetect),
            keyEquivalent: ""
        )
        autoDetectItem.target = self
        menu.addItem(autoDetectItem)

        menu.addItem(NSMenuItem.separator())

        // Quick module access
        let modulesHeader = NSMenuItem(title: "Quick Actions", action: nil, keyEquivalent: "")
        modulesHeader.isEnabled = false
        menu.addItem(modulesHeader)

        for module in environment.moduleRegistry.activeModules {
            let item = NSMenuItem(title: module.name, action: #selector(triggerModule(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = module.id
            if let img = menuImage(for: module) {
                item.image = img
            }
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Model selection submenu
        let providerSettings = environment.providerSettings
        let currentModel = UserDefaults.standard.activeGlobalModelID
        // A subscription CLI runs its own default model until one is chosen.
        let modelDisplayName = currentModel.isEmpty
            ? (providerSettings.provider.isSubscription ? "Default" : "Not selected")
            : environment.modelCatalog.displayName(for: currentModel)
        let modelItem = NSMenuItem(title: "Model: \(modelDisplayName)", action: nil, keyEquivalent: "")
        let modelSubmenu = NSMenu()

        let globalItem = NSMenuItem(title: "Global: \(modelDisplayName)", action: nil, keyEquivalent: "")
        globalItem.isEnabled = false
        modelSubmenu.addItem(globalItem)
        modelSubmenu.addItem(NSMenuItem.separator())

        let moduleEntries = moduleModelOverrideEntries()
        if moduleEntries.isEmpty {
            let emptyItem = NSMenuItem(title: "Module models: none", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            modelSubmenu.addItem(emptyItem)
        } else {
            let moduleHeader = NSMenuItem(title: "Module models", action: nil, keyEquivalent: "")
            moduleHeader.isEnabled = false
            modelSubmenu.addItem(moduleHeader)

            for entry in moduleEntries {
                let displayName = environment.modelCatalog.displayName(for: entry.modelId)
                let modules = entry.moduleLabels.joined(separator: ", ")
                let title = "\(displayName) - \(modules)"
                let item = NSMenuItem(title: title, action: #selector(selectModel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.modelId
                if entry.modelId == currentModel {
                    item.state = .on
                }
                modelSubmenu.addItem(item)
            }
        }

        modelSubmenu.addItem(NSMenuItem.separator())
        let changeModelItem = NSMenuItem(title: "Change model...", action: #selector(showModelSettings), keyEquivalent: "")
        changeModelItem.target = self
        modelSubmenu.addItem(changeModelItem)

        modelItem.submenu = modelSubmenu
        menu.addItem(modelItem)

        menu.addItem(NSMenuItem.separator())

        // Provider credential status
        let apiItem: NSMenuItem
        if environment.isStreamReplay {
            apiItem = NSMenuItem(title: "Local Replay: No API Key Needed", action: nil, keyEquivalent: "")
            apiItem.isEnabled = false
        } else if providerSettings.provider == .openAICompatible {
            // A local endpoint has no required key, so it reports its host instead of a missing-key state.
            let title = providerSettings.endpoint.map { "Local Endpoint: \($0.displayHost)" }
                ?? "Local Endpoint: Not Configured"
            apiItem = NSMenuItem(title: title, action: #selector(showModelSettings), keyEquivalent: "")
            apiItem.target = self
        } else if providerSettings.provider.isSubscription {
            // A CLI provider has no API key. The row shows what the saved catalog's last check
            // found; building the menu never launches the CLI or reads the Keychain.
            let state = SubscriptionConnectionState(catalog: environment.modelCatalog)
            apiItem = NSMenuItem(
                title: "\(providerSettings.provider.displayName): \(state.label)",
                action: #selector(showModelSettings),
                keyEquivalent: ""
            )
            apiItem.target = self
            apiItem.toolTip = environment.modelCatalog.subscriptionConnectionResult?.message
        } else {
            let hasKey = globalAPIKeyProvider()?.isEmpty == false
            let apiTitle = hasKey ? "API Key: Configured" : "Set API Key..."
            apiItem = NSMenuItem(title: apiTitle, action: #selector(showAPIKeyInput), keyEquivalent: "k")
            apiItem.keyEquivalentModifierMask = [.command]
            apiItem.target = self
        }
        menu.addItem(apiItem)

        // Accessibility status
        environment.accessibilityManager.checkPermission()
        let axStatus = environment.accessibilityManager.isTrusted ? "Accessibility: Granted" : "Grant Accessibility..."
        let axItem = NSMenuItem(title: axStatus, action: #selector(checkAccessibility), keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)

        menu.addItem(NSMenuItem.separator())

        let onboardingItem = NSMenuItem(title: "Reopen Onboarding", action: #selector(showOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        let updater = environment.appUpdater
        let updateTitle = updater?.pendingUpdateVersion.map { "Update Available (\($0))..." } ?? "Check for Updates..."
        let updateItem = NSMenuItem(title: updateTitle, action: nil, keyEquivalent: "")
        if let updater, updater.updater.canCheckForUpdates {
            updateItem.action = #selector(checkForUpdates)
            updateItem.target = self
        } else {
            updateItem.isEnabled = false
        }
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

    }

    // MARK: - Actions

    @objc private func hotkeyDidChange() {
        rebuildMenu()
    }

    @objc private func captureText() {
        let preferredPID = preferredSourceAppPIDForCapture()
        Task { @MainActor [weak self] in
            await self?.coordinator?.triggerCapture(preferredSourceAppPID: preferredPID)
        }
    }

    @objc private func triggerModule(_ sender: NSMenuItem) {
        guard let moduleId = sender.representedObject as? String else { return }
        let preferredPID = preferredSourceAppPIDForCapture()
        Task { @MainActor [weak self] in
            await self?.coordinator?.triggerDirectModule(moduleId, preferredSourceAppPID: preferredPID)
        }
    }

    @objc private func openChatWindow() {
        let preferredPID = preferredSourceAppPIDForCapture()
        Task { @MainActor [weak self] in
            await self?.coordinator?.openChat(preferredSourceAppPID: preferredPID)
        }
    }

    @objc private func openNewChat() {
        coordinator?.openChat(.newDraft(pendingSelectionText: nil))
    }

    @objc private func openStoredChat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator?.openChat(.existing(id))
    }

    @objc private func showChatHistorySettings() {
        environment.showSettings(tab: .chatHistory)
    }

    @objc private func toggleAutoDetect() {
        let currentValue = UserDefaults.standard.autoDetectSelectionEnabled
        UserDefaults.standard.setAutoDetectSelectionEnabled(!currentValue)
        NotificationCenter.default.post(name: .autoDetectSelectionChanged, object: nil)
        rebuildMenu()
    }

    @objc private func showAPIKeyInput() {
        guard !environment.isStreamReplay,
              environment.providerSettings.provider == .openRouter else { return }
        let alert = NSAlert()
        alert.messageText = "OpenRouter API Key"
        alert.informativeText = "Enter your OpenRouter API key. Get one at openrouter.ai/keys"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        if environment.keychainService.getGlobalAPIKey()?.isEmpty == false {
            alert.addButton(withTitle: "Clear")
        }
        alert.addButton(withTitle: "Cancel")

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "sk-or-v1-..."
        if let existing = environment.keychainService.getGlobalAPIKey() {
            input.stringValue = existing
        }
        alert.accessoryView = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                environment.keychainService.deleteGlobalAPIKey()
                Log.app.info("API key cleared")
            } else {
                environment.keychainService.setGlobalAPIKey(key)
                Log.app.info("API key saved")
            }
            environment.bootstrap()
            rebuildMenu()
        } else if response == .alertSecondButtonReturn,
                  environment.keychainService.getGlobalAPIKey()?.isEmpty == false {
            environment.keychainService.deleteGlobalAPIKey()
            environment.bootstrap()
            rebuildMenu()
            Log.app.info("API key cleared")
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String else { return }
        applyModelSelection(modelId)
    }

    @objc private func showSettings() {
        environment.showSettings()
    }

    @objc private func showModelSettings() {
        environment.showSettings(tab: .api)
    }

    @objc private func showOnboarding() {
        onboardingController.show()
    }

    @objc private func checkAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdates() {
        environment.appUpdater?.checkForUpdates()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        frontmostAppPIDBeforeMenuOpen = NSWorkspace.shared.frontmostApplication?.processIdentifier
        rebuildMenu(menu: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        frontmostAppPIDBeforeMenuOpen = nil
    }

    func applyModelSelection(_ modelId: String) {
        UserDefaults.standard.setActiveGlobalModelID(modelId)
        environment.bootstrap()
        NotificationCenter.default.post(name: .aiConfigurationChanged, object: nil)
        rebuildMenu()
        Log.app.info("Model changed to: \(modelId)")
    }

#if DEBUG
    func statusMenuForTesting() -> NSMenu? {
        statusItem?.menu
    }

    func modelMenuTitleForTesting() -> String? {
        statusItem?.menu?.items.first(where: { $0.title.hasPrefix("Model: ") })?.title
    }
#endif

    private func chatHistorySubmenu() -> NSMenu {
        let submenu = NSMenu()

        let newChatItem = NSMenuItem(title: "New Chat", action: #selector(openNewChat), keyEquivalent: "")
        newChatItem.target = self
        submenu.addItem(newChatItem)
        submenu.addItem(NSMenuItem.separator())

        let recent = environment.chatHistoryStore.conversations.prefix(10)
        if recent.isEmpty {
            let emptyItem = NSMenuItem(title: "No saved chats", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        }
        for conversation in recent {
            let item = NSMenuItem(title: conversation.title, action: #selector(openStoredChat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = conversation.id
            submenu.addItem(item)
        }

        submenu.addItem(NSMenuItem.separator())
        let openHistoryItem = NSMenuItem(title: "Open History...", action: #selector(showChatHistorySettings), keyEquivalent: "")
        openHistoryItem.target = self
        submenu.addItem(openHistoryItem)

        return submenu
    }

    private func menuImage(for module: any TextModule) -> NSImage? {
        NSImage(systemSymbolName: module.icon, accessibilityDescription: module.name)
    }

    private func moduleModelOverrideEntries() -> [ModelMenuOverrideEntry] {
        guard let data = UserDefaults.standard.data(for: .moduleAIConfigs),
              let configs = try? JSONDecoder().decode([String: ModuleAIConfig].self, from: data) else {
            return []
        }

        let activeIDs = Set(environment.moduleRegistry.activeModules.map(\.id))
        let modules = environment.moduleRegistry.modules.map { module in
            ModelMenuModuleInfo(
                id: module.id,
                name: module.name,
                isEnabled: activeIDs.contains(module.id)
            )
        }

        return ModelMenuStateBuilder.moduleOverrideEntries(modules: modules, configs: configs)
    }

    private func preferredSourceAppPIDForCapture() -> pid_t? {
        guard let pid = frontmostAppPIDBeforeMenuOpen else { return nil }
        if pid == ProcessInfo.processInfo.processIdentifier {
            return nil
        }
        return pid
    }
}
