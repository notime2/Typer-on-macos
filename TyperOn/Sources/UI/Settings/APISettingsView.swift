// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

struct APISettingsView: View {
    let environment: AppEnvironment

    @State private var apiKey: String = ""
    @State private var selectedModel: String
    @State private var provider: AIProvider
    @State private var localBaseURL: String
    @State private var localAPIKey: String = ""
    @State private var localSelectedModel: String
    @State private var codexSelectedModel: String
    @State private var claudeSelectedModel: String
    /// Explicit CLI executables; `nil` searches the usual install locations.
    @State private var codexExecutablePath: String?
    @State private var claudeExecutablePath: String?
    /// Keychain values of the HTTP providers viewed in this session, as read. A provider that was
    /// never viewed has no entry, so Save cannot clear or rewrite its key.
    @State private var loadedCredentials: [AIProvider: String] = [:]
    @State private var localBaseURLError: String?
    @State private var connectionResult: LocalEndpointProbeResult?
    @State private var isTestingConnection = false
    @State private var connectionTestID = UUID()
    @State private var temperature: Double
    @State private var maxTokens: Int
    @State private var showKey = false
    @State private var showLocalKey = false
    @State private var saved = false
    @State private var showAdvanced: Bool
    /// The provider picker on this tab is an unsaved draft, so it lists models from its own catalog.
    @State private var draftCatalog: ModelCatalogService

    init(
        environment: AppEnvironment
    ) {
        self.environment = environment
        let defaults = UserDefaults.standard
        let providerSettings = defaults.aiProviderSettings
        let temp = defaults.double(for: .temperature)
        let tokens = defaults.integer(for: .maxTokens)
        _provider = State(initialValue: providerSettings.provider)
        _localBaseURL = State(
            initialValue: providerSettings.localBaseURLText.isEmpty
                ? AIEndpointURL.ollamaExample
                : providerSettings.localBaseURLText
        )
        _selectedModel = State(initialValue: defaults.globalModelID(for: .openRouter))
        _localSelectedModel = State(initialValue: defaults.globalModelID(for: .openAICompatible))
        _codexSelectedModel = State(initialValue: defaults.globalModelID(for: .codex))
        _claudeSelectedModel = State(initialValue: defaults.globalModelID(for: .claudeCode))
        _codexExecutablePath = State(initialValue: defaults.subscriptionExecutablePath(for: .codex))
        _claudeExecutablePath = State(initialValue: defaults.subscriptionExecutablePath(for: .claudeCode))
        _temperature = State(initialValue: defaults.object(forKey: SettingsKey.temperature.rawValue) != nil ? temp : 0.7)
        _maxTokens = State(initialValue: tokens > 0 ? tokens : 20480)
        _showAdvanced = State(initialValue: defaults.bool(for: .showAdvancedParams))
        _draftCatalog = State(initialValue: environment.makeDraftModelCatalog())
    }

    var body: some View {
        contentContainer
            .onAppear {
                loadCredentialIfNeeded()
                applyDraftCatalogSource()
            }
            .onChange(of: provider) { _, _ in
                connectionResult = nil
                loadCredentialIfNeeded()
                applyDraftCatalogSource()
            }
            .onChange(of: codexExecutablePath) { _, _ in
                applyDraftCatalogSource()
            }
            .onChange(of: claudeExecutablePath) { _, _ in
                applyDraftCatalogSource()
            }
            .onChange(of: localAPIKey) { _, _ in
                invalidateConnectionTest()
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
            sectionHeader("AI Provider")

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                // Four provider names do not fit a segmented control at the minimum window width.
                Picker("Provider", selection: $provider) {
                    ForEach(AIProvider.allCases, id: \.self) { candidate in
                        Text(candidate.displayName).tag(candidate)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()

                Text(providerSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(environment.isStreamReplay)

            Divider().foregroundStyle(DS.Colors.separator)

            switch provider {
            case .openRouter:
                openRouterSection
            case .openAICompatible:
                localEndpointSection
            case .codex, .claudeCode:
                subscriptionSection
            }

            Divider().foregroundStyle(DS.Colors.separator)

            sectionHeader("Model")

            ModelPickerView(
                catalog: draftCatalog,
                clipboardManager: environment.clipboardManager,
                selectedModelId: modelBinding,
                apiKey: catalogAPIKey,
                source: draftCatalogSource,
                // The connection status above already reports why a CLI catalog is unavailable.
                showsCatalogError: !provider.isSubscription
            )

            Divider().foregroundStyle(DS.Colors.separator)

            // The CLIs take neither value, so the sliders would promise control they do not have.
            if !provider.isSubscription {
                advancedSection

                Divider().foregroundStyle(DS.Colors.separator)
            }

            HStack {
                Spacer()
                if saved {
                    Text("Saved!").font(.system(size: 13)).foregroundStyle(.green)
                }
                Button("Save") {
                    save()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(environment.isStreamReplay)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.background)
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    HStack {
                        Text("Temperature").font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text(String(format: "%.1f", temperature))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    Slider(value: $temperature, in: 0...2, step: 0.1)
                    Text("Lower = more focused, higher = more creative")
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.textTertiary)
                }

                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    HStack {
                        Text("Max Tokens").font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text("\(maxTokens)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    Slider(value: .init(get: { Double(maxTokens) }, set: { maxTokens = Int($0) }),
                           in: 256...20480, step: 256)
                }
            }
            .padding(.top, DS.Spacing.sm)
        } label: {
            HStack {
                Text("Advanced")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                showAdvanced.toggle()
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DS.Colors.textSecondary)
        .onChange(of: showAdvanced) { _, newValue in
            guard !environment.isStreamReplay else { return }
            UserDefaults.standard.set(newValue, for: .showAdvancedParams)
        }
    }

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            sectionHeader(provider == .codex ? "Codex CLI" : "Claude Code CLI")

            SubscriptionConnectionView(
                provider: provider,
                statusCatalog: subscriptionStatusCatalog,
                executablePath: provider == .codex ? $codexExecutablePath : $claudeExecutablePath,
                onCheckConnection: { checkSubscriptionConnection() }
            )
            // Codex and Claude Code share this slot; a sign-in note must not carry over.
            .id(provider)
        }
        .disabled(environment.isStreamReplay)
    }

    private var openRouterSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            sectionHeader("OpenRouter API")

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("API Key").font(.system(size: 14, weight: .medium))
                Text(environment.isStreamReplay ? "Local replay does not use an API key." : "Get your key at openrouter.ai/keys")
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.textTertiary)

                HStack(spacing: DS.Spacing.sm) {
                    Group {
                        if showKey {
                            TextField("sk-or-v1-...", text: $apiKey)
                        } else {
                            SecureField("sk-or-v1-...", text: $apiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.glass)
                }

                if !apiKey.isEmpty {
                    HStack {
                        Spacer()
                        Button("Clear Saved Key") {
                            apiKey = ""
                            save()
                        }
                        .font(.system(size: 12))
                        .buttonStyle(.glass)
                    }
                }
            }
        }
        .disabled(environment.isStreamReplay)
    }

    private var localEndpointSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            sectionHeader("Local Endpoint")

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Base URL").font(.system(size: 14, weight: .medium))
                Text("Ollama: \(AIEndpointURL.ollamaExample)  -  LM Studio: \(AIEndpointURL.lmStudioExample)")
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.textTertiary)

                TextField(AIEndpointURL.ollamaExample, text: $localBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onChange(of: localBaseURL) { _, _ in
                        localBaseURLError = nil
                        applyDraftCatalogSource()
                    }

                if let localBaseURLError {
                    Text(localBaseURLError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("API Key (optional)").font(.system(size: 14, weight: .medium))
                Text("Only needed if your server requires one. It is stored in the Keychain.")
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.textTertiary)

                HStack(spacing: DS.Spacing.sm) {
                    Group {
                        if showLocalKey {
                            TextField("Leave blank for no key", text: $localAPIKey)
                        } else {
                            SecureField("Leave blank for no key", text: $localAPIKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button {
                        showLocalKey.toggle()
                    } label: {
                        Image(systemName: showLocalKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.glass)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                Button("Test Connection") {
                    testConnection()
                }
                .buttonStyle(.glass)
                .disabled(isTestingConnection || environment.isStreamReplay)

                if isTestingConnection {
                    Text("Testing...")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.textTertiary)
                } else if let connectionResult {
                    Text(connectionResult.message)
                        .font(.system(size: 12))
                        .foregroundStyle(connectionResult.isSuccess ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
        .disabled(environment.isStreamReplay)
    }

    private var providerSummary: String {
        switch provider {
        case .openRouter:
            return "Hosted models through openrouter.ai with your own key."
        case .openAICompatible:
            return "Any OpenAI-compatible server you run, such as Ollama or LM Studio."
        case .codex:
            return "Your ChatGPT subscription through the Codex CLI installed on this Mac."
        case .claudeCode:
            return "Your Claude subscription through the Claude Code CLI installed on this Mac."
        }
    }

    private var modelBinding: Binding<String> {
        switch provider {
        case .openRouter:
            return $selectedModel
        case .openAICompatible:
            return $localSelectedModel
        case .codex:
            return $codexSelectedModel
        case .claudeCode:
            return $claudeSelectedModel
        }
    }

    private var catalogAPIKey: String {
        guard !environment.isStreamReplay else { return "" }
        switch provider {
        case .openRouter:
            return apiKey
        case .openAICompatible:
            return localAPIKey
        case .codex, .claudeCode:
            return ""
        }
    }

    /// The endpoint or CLI currently drafted in this view, so the picker lists the draft rather than the saved one.
    private var draftCatalogSource: ModelCatalogSource {
        switch provider {
        case .openRouter:
            return .openRouter
        case .openAICompatible:
            guard let url = try? AIEndpointURL.normalize(localBaseURL) else { return .unconfigured }
            return .openAICompatible(baseURL: url)
        case .codex:
            return .subscription(provider: provider, executablePath: codexExecutablePath)
        case .claudeCode:
            return .subscription(provider: provider, executablePath: claudeExecutablePath)
        }
    }

    /// The draft's own check wins. Before one runs, the saved catalog's result applies when it
    /// probed the same executable, so an already connected CLI is not shown as unchecked.
    private var subscriptionStatusCatalog: ModelCatalogService {
        let saved = environment.modelCatalog
        if draftCatalog.subscriptionConnectionResult == nil, !draftCatalog.isLoading,
           saved.source == draftCatalogSource {
            return saved
        }
        return draftCatalog
    }

    private func applyDraftCatalogSource() {
        invalidateConnectionTest()
        draftCatalog.setSource(draftCatalogSource)
        Task { await draftCatalog.loadCached() }
    }

    private func invalidateConnectionTest() {
        connectionTestID = UUID()
        isTestingConnection = false
        connectionResult = nil
    }

    /// Reads only the key of the HTTP provider being viewed, once. A CLI provider has no key,
    /// so selecting one never touches the Keychain.
    private func loadCredentialIfNeeded() {
        guard !environment.isStreamReplay, loadedCredentials[provider] == nil else { return }
        switch provider {
        case .openRouter:
            apiKey = environment.keychainService.getGlobalAPIKey() ?? ""
            loadedCredentials[provider] = apiKey
        case .openAICompatible:
            localAPIKey = environment.keychainService.getLocalEndpointAPIKey() ?? ""
            loadedCredentials[provider] = localAPIKey
        case .codex, .claudeCode:
            break
        }
    }

    /// Writes the selected HTTP provider's key only when it was loaded and then edited. Saving a
    /// CLI provider, or an unchanged key, leaves every stored key as it is.
    private func saveCredentialIfChanged() {
        guard let loaded = loadedCredentials[provider] else { return }
        switch provider {
        case .openRouter:
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key != loaded else { return }
            if key.isEmpty {
                environment.keychainService.deleteGlobalAPIKey()
            } else {
                environment.keychainService.setGlobalAPIKey(key)
            }
            loadedCredentials[provider] = key
        case .openAICompatible:
            let key = localAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key != loaded else { return }
            if key.isEmpty {
                environment.keychainService.deleteLocalEndpointAPIKey()
            } else {
                environment.keychainService.setLocalEndpointAPIKey(key)
            }
            loadedCredentials[provider] = key
        case .codex, .claudeCode:
            break
        }
    }

    /// Runs the CLI's read-only connection check against the draft catalog; it also loads that CLI's models.
    private func checkSubscriptionConnection() {
        guard !environment.isStreamReplay else { return }
        let source = draftCatalogSource
        Task {
            guard draftCatalogSource == source else { return }
            await draftCatalog.fetchModels(apiKey: "", source: source)
        }
    }

    private func testConnection() {
        guard !environment.isStreamReplay, provider == .openAICompatible else { return }
        let baseURLText = localBaseURL
        let key = localAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = draftCatalogSource
        let requestID = UUID()
        connectionTestID = requestID
        isTestingConnection = true
        connectionResult = nil
        Task {
            defer { if connectionTestID == requestID { isTestingConnection = false } }
            let result = await LocalEndpointProbe().probe(baseURLText: baseURLText, apiKey: key)
            guard connectionTestID == requestID, draftCatalogSource == source else { return }
            connectionResult = result
            if result.isSuccess {
                localBaseURLError = nil
                await draftCatalog.fetchModels(apiKey: key, source: source)
                guard connectionTestID == requestID, draftCatalogSource == source else { return }
                if localSelectedModel.isEmpty,
                   let first = draftCatalog.displayModels.first {
                    localSelectedModel = first.id
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.Colors.textSecondary)
            .textCase(.uppercase)
    }

    private func save() {
        guard !environment.isStreamReplay else { return }

        var normalizedBaseURL: String?
        if provider == .openAICompatible {
            do {
                normalizedBaseURL = try AIEndpointURL.normalize(localBaseURL).absoluteString
                localBaseURLError = nil
            } catch {
                localBaseURLError = error.localizedDescription
                return
            }
        }

        saveCredentialIfChanged()

        if let normalizedBaseURL {
            localBaseURL = normalizedBaseURL
            UserDefaults.standard.setLocalEndpointBaseURL(normalizedBaseURL)
        }
        UserDefaults.standard.setAIProvider(provider)
        UserDefaults.standard.setGlobalModelID(selectedModel, for: .openRouter)
        UserDefaults.standard.setGlobalModelID(localSelectedModel, for: .openAICompatible)
        UserDefaults.standard.setGlobalModelID(codexSelectedModel, for: .codex)
        UserDefaults.standard.setGlobalModelID(claudeSelectedModel, for: .claudeCode)
        UserDefaults.standard.setSubscriptionExecutablePath(codexExecutablePath, for: .codex)
        UserDefaults.standard.setSubscriptionExecutablePath(claudeExecutablePath, for: .claudeCode)
        if !provider.isSubscription {
            UserDefaults.standard.set(temperature, for: .temperature)
            UserDefaults.standard.set(maxTokens, for: .maxTokens)
        }

        environment.bootstrap()
        NotificationCenter.default.post(name: .aiConfigurationChanged, object: nil)
        saved = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saved = false
        }

        let savedProvider = provider.rawValue
        Log.app.info("API settings saved for provider \(savedProvider, privacy: .public)")
    }
}
