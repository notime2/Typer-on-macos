// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI
import UniformTypeIdentifiers

struct ModulesSettingsView: View {
    let environment: AppEnvironment
    let onAddCustomModule: () -> Void

    @State private var enabledModules: Set<String> = []
    @State private var enabledModuleOrder: [String] = []
    @State private var expandedModule: String?
    @State private var draggedModuleID: String?

    init(
        environment: AppEnvironment,
        onAddCustomModule: @escaping () -> Void = {}
    ) {
        self.environment = environment
        self.onAddCustomModule = onAddCustomModule
    }

    var body: some View {
        contentContainer
            .onAppear {
                syncStateFromRegistry()
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
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.md) {
                Text("Enable or disable modules. Drag enabled modules to reorder toolbar actions.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button(action: onAddCustomModule) {
                    Image(systemName: "plus.circle")
                    Text("Add Custom Module")
                }
                .font(.system(size: 13))
                .buttonStyle(.glass)
                .fixedSize(horizontal: true, vertical: false)
            }

            ForEach(moduleItems) { item in
                moduleRow(for: item)
            }
        }
        .onDrop(of: [UTType.text], delegate: ResetDragDropDelegate(draggedModuleID: $draggedModuleID))
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.background)
    }

    private var moduleItems: [ModuleListItem] {
        let enabled = orderedEnabledModules.map {
            ModuleListItem(id: $0.id, module: $0, isEnabled: true)
        }
        let disabled = environment.moduleRegistry.modules
            .filter { !enabledModules.contains($0.id) }
            .map { ModuleListItem(id: $0.id, module: $0, isEnabled: false) }
        return enabled + disabled
    }

    private var orderedEnabledModules: [any TextModule] {
        var seen = Set<String>()
        var ordered: [any TextModule] = []

        for moduleId in enabledModuleOrder where enabledModules.contains(moduleId) {
            guard let module = environment.moduleRegistry.module(byId: moduleId) else { continue }
            if seen.insert(module.id).inserted {
                ordered.append(module)
            }
        }

        for module in environment.moduleRegistry.modules where enabledModules.contains(module.id) {
            if seen.insert(module.id).inserted {
                ordered.append(module)
            }
        }

        return ordered
    }

    @ViewBuilder
    private func moduleRow(for item: ModuleListItem) -> some View {
        let row = ModuleRow(
            module: item.module,
            isEnabled: item.isEnabled,
            isExpanded: expandedModule == item.id,
            isReorderable: item.isEnabled,
            environment: environment,
            onToggle: { enabled in
                handleToggle(enabled: enabled, moduleId: item.id)
            },
            onExpand: {
                withAnimation(DS.Animation.quick) {
                    expandedModule = expandedModule == item.id ? nil : item.id
                }
            }
        )

        if item.isEnabled {
            row
                .onDrag {
                    draggedModuleID = item.id
                    return NSItemProvider(object: item.id as NSString)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: EnabledModuleReorderDropDelegate(
                        targetModuleID: item.id,
                        enabledModuleOrder: $enabledModuleOrder,
                        draggedModuleID: $draggedModuleID,
                        onOrderChanged: { persistEnabledOrder() }
                    )
                )
                .opacity(draggedModuleID == item.id ? 0.3 : 1)
                .scaleEffect(draggedModuleID == item.id ? 0.98 : 1)
        } else {
            row
                .onDrop(of: [UTType.text], delegate: ResetDragDropDelegate(draggedModuleID: $draggedModuleID))
        }
    }

    private func syncStateFromRegistry() {
        let activeIDs = environment.moduleRegistry.activeModules.map(\.id)
        enabledModules = Set(activeIDs)
        enabledModuleOrder = activeIDs
    }

    private func handleToggle(enabled: Bool, moduleId: String) {
        if enabled {
            enabledModules.insert(moduleId)
            enabledModuleOrder.removeAll { $0 == moduleId }
            enabledModuleOrder.append(moduleId)
        } else {
            enabledModules.remove(moduleId)
            enabledModuleOrder.removeAll { $0 == moduleId }
        }

        environment.moduleRegistry.setEnabled(enabled, for: moduleId)
        persistEnabledOrder()
    }

    private func persistEnabledOrder() {
        let normalized = normalizedEnabledOrder()
        enabledModuleOrder = normalized
        environment.moduleRegistry.setOrder(normalized)
    }

    private func normalizedEnabledOrder() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for moduleId in enabledModuleOrder where enabledModules.contains(moduleId) {
            if seen.insert(moduleId).inserted {
                ordered.append(moduleId)
            }
        }

        for module in environment.moduleRegistry.modules where enabledModules.contains(module.id) {
            if seen.insert(module.id).inserted {
                ordered.append(module.id)
            }
        }

        return ordered
    }
}

private struct ModuleListItem: Identifiable {
    let id: String
    let module: any TextModule
    let isEnabled: Bool
}

private struct EnabledModuleReorderDropDelegate: DropDelegate {
    let targetModuleID: String
    @Binding var enabledModuleOrder: [String]
    @Binding var draggedModuleID: String?
    let onOrderChanged: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedModuleID,
              draggedModuleID != targetModuleID,
              let fromIndex = enabledModuleOrder.firstIndex(of: draggedModuleID),
              let toIndex = enabledModuleOrder.firstIndex(of: targetModuleID),
              fromIndex != toIndex else {
            return
        }

        withAnimation(DS.Animation.quick) {
            enabledModuleOrder.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }

        onOrderChanged()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(DS.Animation.smooth) {
            draggedModuleID = nil
        }
        onOrderChanged()
        return true
    }
}

private struct ResetDragDropDelegate: DropDelegate {
    @Binding var draggedModuleID: String?

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(DS.Animation.smooth) {
            draggedModuleID = nil
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct ModuleRow: View {
    let module: any TextModule
    let isEnabled: Bool
    let isExpanded: Bool
    let isReorderable: Bool
    let environment: AppEnvironment
    let onToggle: (Bool) -> Void
    let onExpand: () -> Void

    @State private var useGlobal = true
    @State private var modelDraft = ModuleModelDraft()
    @AppStorage(SettingsKey.selectedModel.rawValue) private var globalModel = AIModelDefaults.defaultModelID
    @AppStorage(SettingsKey.localSelectedModel.rawValue) private var localGlobalModel = ""
    @AppStorage(SettingsKey.codexSelectedModel.rawValue) private var codexGlobalModel = ""
    @AppStorage(SettingsKey.claudeSelectedModel.rawValue) private var claudeGlobalModel = ""
    @AppStorage(SettingsKey.aiProvider.rawValue) private var globalProviderRawValue = AIProvider.fallback.rawValue
    @State private var customApiKey = ""
    @State private var hasStoredModuleAPIKey = false
    @State private var outputLanguageMode: ModuleOutputLanguageMode = .defaultLanguage
    @State private var autoReplaceOriginalText = false
    @State private var promptText = ""
    @State private var saveFeedbackState = ModuleSettingsSaveFeedbackState()
    @FocusState private var focusedField: ModuleSettingsSaveFeedbackState.FocusedField?

    private var trimmedShortDescription: String? {
        let trimmed = module.shortDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Provider selection is global only; module overrides apply to whichever provider is active.
    private var providerSettings: AIProviderSettings {
        AIProviderSettings.resolve(
            provider: globalProviderRawValue,
            localBaseURL: UserDefaults.standard.string(for: .localEndpointBaseURL)
        )
    }

    /// A subscription CLI signs in with one shared account, so a module has no key of its own there.
    private var usesSubscriptionProvider: Bool {
        providerSettings.provider.isSubscription
    }

    private var effectiveGlobalModel: String {
        switch providerSettings.provider {
        case .openRouter:
            return globalModel
        case .openAICompatible:
            return localGlobalModel
        case .codex:
            return codexGlobalModel
        case .claudeCode:
            // An unset model resolves through the shared default instead of a second copy of it here.
            return claudeGlobalModel.isEmpty
                ? UserDefaults.standard.globalModelID(for: .claudeCode)
                : claudeGlobalModel
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isReorderable ? DS.Colors.textTertiary : .clear)
                    .frame(width: 10)

                ModuleIconView(icon: module.icon, size: 14)
                    .frame(width: 24)
                    .foregroundStyle(isEnabled ? DS.Colors.accent : DS.Colors.textTertiary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(module.name).font(.system(size: 14, weight: .medium))
                    if let shortDescription = trimmedShortDescription {
                        Text(shortDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textTertiary)
                    }
                }

                Spacer()

                Button {
                    onExpand()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)

                Toggle("", isOn: .init(get: { isEnabled }, set: { onToggle($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(DS.Spacing.md)

            if isExpanded {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    Divider().foregroundStyle(DS.Colors.separator)

                    Toggle("Use global AI settings", isOn: $useGlobal)
                        .font(.system(size: 13))

                    if !useGlobal {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            if usesSubscriptionProvider {
                                Label(
                                    ModuleProviderHint.credentialLabel(provider: providerSettings.provider, host: nil),
                                    systemImage: "person.crop.circle"
                                )
                                .font(.system(size: 12))
                                .foregroundStyle(DS.Colors.textTertiary)
                                .help("Module API keys apply to OpenRouter and local endpoints only. Saved keys are kept.")
                            } else {
                                moduleAPIKeySection
                            }

                            ModelPickerView(
                                catalog: environment.modelCatalog,
                                clipboardManager: environment.clipboardManager,
                                selectedModelId: Binding(
                                    get: { modelDraft.effectiveModel(globalModel: effectiveGlobalModel) },
                                    set: { modelDraft.select($0) }
                                ),
                                apiKey: catalogAPIKey
                            )

                            HStack(spacing: DS.Spacing.sm) {
                                if modelDraft.customModel == nil {
                                    Label(
                                        ModuleProviderHint.modelLabel(
                                            provider: providerSettings.provider,
                                            host: providerSettings.endpoint?.displayHost
                                        ),
                                        systemImage: "globe"
                                    )
                                    .foregroundStyle(DS.Colors.textTertiary)
                                } else {
                                    Button("Use global model") {
                                        modelDraft.select("")
                                    }
                                    .buttonStyle(.glass)
                                }
                            }
                            .font(.system(size: 12))
                        }
                    }

                    if module.id != "content-generation" {
                        Toggle("Automatically replace original text", isOn: $autoReplaceOriginalText)
                            .font(.system(size: 13))
                            .help(
                                "Processes the selection in the background and replaces it as soon as the result is ready. "
                                + "The Processing window opens only if processing or replacement fails. "
                                + "Use Undo in the source app to revert an automatic replacement."
                            )
                    }

                    Divider().foregroundStyle(DS.Colors.separator)

                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Text("Output Language")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Colors.textSecondary)

                        Picker("Output Language", selection: $outputLanguageMode) {
                            Text("Default Language").tag(ModuleOutputLanguageMode.defaultLanguage)
                            Text("Source Language").tag(ModuleOutputLanguageMode.sourceLanguage)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Text("System Prompt")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Colors.textSecondary)

                        TextEditor(text: $promptText)
                            .font(.system(size: 13))
                            .frame(minHeight: 120)
                            .focused($focusedField, equals: .systemPrompt)
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.button)
                                    .stroke(DS.Colors.separator, lineWidth: 0.5)
                            )

                        HStack {
                            Button("Reset to Default Prompt") {
                                promptText = defaultPromptText(for: outputLanguageMode)
                            }
                            .font(.system(size: 12))
                            .buttonStyle(.glass)

                            Spacer()

                            if saveFeedbackState.status == .saved {
                                Label("Module settings saved", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.green)
                                    .transition(.opacity)
                            }

                            Button("Save Module Settings") {
                                saveModuleConfig()
                            }
                            .font(.system(size: 12))
                            .buttonStyle(.glassProminent)
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.md)
            }
        }
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.Colors.separator, lineWidth: 0.5))
        .onAppear { loadModuleConfig() }
        .onChange(of: modelDraft) { _, _ in
            saveFeedbackState.markEdited()
        }
        .onChange(of: focusedField) { _, newValue in
            saveFeedbackState.updateFocusedField(newValue)
        }
        .onChange(of: outputLanguageMode) { oldMode, newMode in
            let oldDefaultPrompt = normalizedPrompt(defaultPromptText(for: oldMode))
            if normalizedPrompt(promptText) == oldDefaultPrompt {
                promptText = defaultPromptText(for: newMode)
            }
        }
    }

    private var moduleAPIKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField(hasStoredModuleAPIKey ? "Leave blank to keep saved module key" : "Custom API Key (optional)", text: $customApiKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($focusedField, equals: .customAPIKey)

            HStack(spacing: DS.Spacing.sm) {
                Label(
                    hasStoredModuleAPIKey
                        ? "Module API key saved in Keychain"
                        : ModuleProviderHint.credentialLabel(
                            provider: providerSettings.provider,
                            host: providerSettings.endpoint?.displayHost
                        ),
                    systemImage: hasStoredModuleAPIKey ? "checkmark.circle.fill" : "globe"
                )
                .font(.system(size: 12))
                .foregroundStyle(hasStoredModuleAPIKey ? .green : DS.Colors.textTertiary)

                Spacer()

                if hasStoredModuleAPIKey {
                    Button("Clear Saved Key") {
                        clearStoredModuleAPIKey()
                    }
                    .font(.system(size: 12))
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private func loadModuleConfig() {
        let loadedConfig = currentConfig()
        useGlobal = loadedConfig?.useGlobal ?? true
        modelDraft = ModuleModelDraft(customModel: loadedConfig?.customModel)
        customApiKey = ""
        // A CLI provider ignores module keys, so its settings never read the Keychain.
        hasStoredModuleAPIKey = !usesSubscriptionProvider
            && environment.keychainService.getModuleAPIKey(moduleId: module.id)?.isEmpty == false
        outputLanguageMode = loadedConfig?.resolvedOutputLanguageMode(for: module.id)
            ?? ModuleOutputLanguageMode.defaultMode(for: module.id)
        autoReplaceOriginalText = loadedConfig?.autoReplaceOriginalText ?? false

        let defaultPrompt = defaultPromptText(for: outputLanguageMode)
        let trimmedCustomPrompt = loadedConfig?.customSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        promptText = trimmedCustomPrompt.isEmpty ? defaultPrompt : trimmedCustomPrompt
    }

    private func saveModuleConfig() {
        var configs: [String: ModuleAIConfig] = [:]
        if let data = UserDefaults.standard.data(for: .moduleAIConfigs),
           let existing = try? JSONDecoder().decode([String: ModuleAIConfig].self, from: data) {
            configs = existing
        }

        let trimmedKey = customApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            environment.keychainService.setModuleAPIKey(trimmedKey, moduleId: module.id)
            hasStoredModuleAPIKey = true
            customApiKey = ""
        }

        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultPrompt = defaultPromptText(for: outputLanguageMode)
        let normalizedDefaultPrompt = normalizedPrompt(defaultPrompt)
        let customPromptToStore: String?
        if trimmedPrompt.isEmpty || normalizedPrompt(trimmedPrompt) == normalizedDefaultPrompt {
            customPromptToStore = nil
        } else {
            customPromptToStore = trimmedPrompt
        }

        let existingConfig = configs[module.id]

        configs[module.id] = ModuleAIConfig(
            useGlobal: useGlobal,
            // The key state was not read under a CLI provider; keep it for the HTTP providers.
            usesModuleAPIKey: usesSubscriptionProvider
                ? (existingConfig?.usesModuleAPIKey ?? false)
                : hasStoredModuleAPIKey,
            customModel: modelDraft.customModel,
            customTemperature: existingConfig?.customTemperature,
            customMaxTokens: existingConfig?.customMaxTokens,
            customSystemPrompt: customPromptToStore,
            outputLanguageMode: outputLanguageMode,
            autoReplaceOriginalText: autoReplaceOriginalText
        )

        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, for: .moduleAIConfigs)
        }
        NotificationCenter.default.post(name: .aiConfigurationChanged, object: nil)

        if customPromptToStore == nil {
            promptText = defaultPrompt
        }

        focusedField = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        saveFeedbackState.markSaved()
    }

    private var catalogAPIKey: String {
        // A CLI catalog refreshes through the signed-in account and must not read any saved key.
        guard !environment.isStreamReplay, !usesSubscriptionProvider else { return "" }
        return ModuleModelDraft.catalogAPIKey(
            enteredKey: customApiKey,
            storedModuleKey: environment.keychainService.getModuleAPIKey(moduleId: module.id),
            globalKey: providerSettings.provider == .openRouter
                ? environment.keychainService.getGlobalAPIKey()
                : environment.keychainService.getLocalEndpointAPIKey()
        )
    }

    private func clearStoredModuleAPIKey() {
        environment.keychainService.deleteModuleAPIKey(moduleId: module.id)
        hasStoredModuleAPIKey = false
        customApiKey = ""
    }

    private func defaultPromptText(for mode: ModuleOutputLanguageMode) -> String {
        var context = ModuleContext.default
        context.targetLanguage = UserDefaults.standard.defaultTargetLanguage
        context.fallbackTargetLanguage = UserDefaults.standard.translationFallbackLanguage
        context.outputLanguageMode = mode
        context.sourceLanguageName = String.defaultLanguageDetectionFallback
        context.customSystemPrompt = nil

        let messages = module.buildPrompt(for: "", context: context)
        return messages.first(where: { $0.role == "system" })?.content ?? ""
    }

    private func normalizedPrompt(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentConfig() -> ModuleAIConfig? {
        guard let data = UserDefaults.standard.data(for: .moduleAIConfigs),
              let configs = try? JSONDecoder().decode([String: ModuleAIConfig].self, from: data) else {
            return nil
        }

        return configs[module.id]
    }
}
