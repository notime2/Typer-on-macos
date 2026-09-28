// SPDX-License-Identifier: Apache-2.0
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
    @State private var localBaseURLError: String?
    @State private var connectionResult: LocalEndpointProbeResult?
    @State private var isTestingConnection = false
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
        _temperature = State(initialValue: temp > 0 ? temp : 0.7)
        _maxTokens = State(initialValue: tokens > 0 ? tokens : 20480)
        _showAdvanced = State(initialValue: defaults.bool(for: .showAdvancedParams))
        _draftCatalog = State(initialValue: environment.makeDraftModelCatalog())
    }

    var body: some View {
        contentContainer
            .onAppear {
                if !environment.isStreamReplay {
                    apiKey = environment.keychainService.getGlobalAPIKey() ?? ""
                    localAPIKey = environment.keychainService.getLocalEndpointAPIKey() ?? ""
                }
                applyDraftCatalogSource()
            }
            .onChange(of: provider) { _, _ in
                connectionResult = nil
                applyDraftCatalogSource()
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
                Picker("Provider", selection: $provider) {
                    ForEach(AIProvider.allCases, id: \.self) { candidate in
                        Text(candidate.displayName).tag(candidate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(
                    provider == .openRouter
                        ? "Hosted models through openrouter.ai with your own key."
                        : "Any OpenAI-compatible server you run, such as Ollama or LM Studio."
                )
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textTertiary)
            }
            .disabled(environment.isStreamReplay)

            Divider().foregroundStyle(DS.Colors.separator)

            if provider == .openRouter {
                openRouterSection
            } else {
                localEndpointSection
            }

            Divider().foregroundStyle(DS.Colors.separator)

            sectionHeader("Model")

            ModelPickerView(
                catalog: draftCatalog,
                clipboardManager: environment.clipboardManager,
                selectedModelId: modelBinding,
                apiKey: catalogAPIKey,
                source: draftCatalogSource
            )

            Divider().foregroundStyle(DS.Colors.separator)

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

            Divider().foregroundStyle(DS.Colors.separator)

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
                        connectionResult = nil
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

    private var modelBinding: Binding<String> {
        provider == .openRouter ? $selectedModel : $localSelectedModel
    }

    private var catalogAPIKey: String {
        guard !environment.isStreamReplay else { return "" }
        switch provider {
        case .openRouter:
            return apiKey
        case .openAICompatible:
            return localAPIKey
        }
    }

    /// The endpoint currently typed in this view, so the picker lists the draft rather than the saved endpoint.
    private var draftCatalogSource: ModelCatalogSource {
        switch provider {
        case .openRouter:
            return .openRouter
        case .openAICompatible:
            guard let url = try? AIEndpointURL.normalize(localBaseURL) else { return .unconfigured }
            return .openAICompatible(baseURL: url)
        }
    }

    private func applyDraftCatalogSource() {
        draftCatalog.setSource(draftCatalogSource)
        Task { await draftCatalog.loadCached() }
    }

    private func testConnection() {
        guard !environment.isStreamReplay else { return }
        let baseURLText = localBaseURL
        let key = localAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        isTestingConnection = true
        connectionResult = nil
        Task {
            let result = await LocalEndpointProbe().probe(baseURLText: baseURLText, apiKey: key)
            connectionResult = result
            isTestingConnection = false
            if result.isSuccess {
                localBaseURLError = nil
                await draftCatalog.fetchModels(apiKey: key, source: draftCatalogSource)
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

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            environment.keychainService.deleteGlobalAPIKey()
        } else {
            environment.keychainService.setGlobalAPIKey(key)
        }

        let trimmedLocalKey = localAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLocalKey.isEmpty {
            environment.keychainService.deleteLocalEndpointAPIKey()
        } else {
            environment.keychainService.setLocalEndpointAPIKey(trimmedLocalKey)
        }

        if let normalizedBaseURL {
            localBaseURL = normalizedBaseURL
            UserDefaults.standard.setLocalEndpointBaseURL(normalizedBaseURL)
        }
        UserDefaults.standard.setAIProvider(provider)
        UserDefaults.standard.setGlobalModelID(selectedModel, for: .openRouter)
        UserDefaults.standard.setGlobalModelID(localSelectedModel, for: .openAICompatible)
        UserDefaults.standard.set(temperature, for: .temperature)
        UserDefaults.standard.set(maxTokens, for: .maxTokens)

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
