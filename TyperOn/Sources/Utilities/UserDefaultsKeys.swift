// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

enum SettingsKey: String {
    case autoDetectSelection
    case selectionTriggerStyle
    case globalHotkey
    case defaultTargetLanguage
    case selectedModel
    case aiProvider
    case localEndpointBaseURL
    case localSelectedModel
    case codexSelectedModel
    case claudeSelectedModel
    case codexExecutablePath
    case claudeExecutablePath
    case cachedCodexModels
    case cachedClaudeModels
    case maxTokens
    case temperature
    case enabledModuleIDs
    case moduleOrder
    case customPrompts
    case moduleAIConfigs
    case cachedModelList
    case cachedLocalModelList
    case showAdvancedParams
    case settingsWindowWidth
    case settingsWindowHeight
    case settingsWindowSizingVersion
    case showChatHistorySidebar
}

extension UserDefaults {
    func value<T>(for key: SettingsKey) -> T? {
        object(forKey: key.rawValue) as? T
    }

    func set(_ value: Any?, for key: SettingsKey) {
        set(value, forKey: key.rawValue)
    }

    func string(for key: SettingsKey) -> String? {
        string(forKey: key.rawValue)
    }

    func bool(for key: SettingsKey) -> Bool {
        bool(forKey: key.rawValue)
    }

    func double(for key: SettingsKey) -> Double {
        double(forKey: key.rawValue)
    }

    func integer(for key: SettingsKey) -> Int {
        integer(forKey: key.rawValue)
    }

    func data(for key: SettingsKey) -> Data? {
        data(forKey: key.rawValue)
    }

    var autoDetectSelectionEnabled: Bool {
        if object(forKey: SettingsKey.autoDetectSelection.rawValue) == nil {
            return true
        }
        return bool(for: .autoDetectSelection)
    }

    func setAutoDetectSelectionEnabled(_ enabled: Bool) {
        set(enabled, for: .autoDetectSelection)
    }

    var selectionTriggerStyle: SelectionTriggerStyle {
        guard let rawValue = string(for: .selectionTriggerStyle),
              let style = SelectionTriggerStyle(rawValue: rawValue) else {
            return .glassDot
        }
        return style
    }

    func setSelectionTriggerStyle(_ style: SelectionTriggerStyle) {
        set(style.rawValue, for: .selectionTriggerStyle)
    }

    /// The default target language: the saved choice, otherwise the first supported
    /// system language from `Locale.preferredLanguages`, otherwise English.
    var defaultTargetLanguage: String {
        TargetLanguageCatalog.resolveDefaultLanguage(
            saved: string(for: .defaultTargetLanguage),
            preferredLanguages: Locale.preferredLanguages
        )
    }

    func setDefaultTargetLanguage(_ language: String) {
        set(language, for: .defaultTargetLanguage)
    }

    /// The language Translate targets when the input already matches `defaultTargetLanguage`.
    var translationFallbackLanguage: String? {
        TargetLanguageCatalog.translationFallbackLanguage(
            for: defaultTargetLanguage,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    /// The persisted provider selection. Missing or unknown values resolve to OpenRouter.
    var aiProviderSettings: AIProviderSettings {
        AIProviderSettings.resolve(
            provider: string(for: .aiProvider),
            localBaseURL: string(for: .localEndpointBaseURL),
            subscriptionExecutablePath: subscriptionExecutablePath(for: AIProvider.resolve(rawValue: string(for: .aiProvider)))
        )
    }

    func setAIProvider(_ provider: AIProvider) {
        set(provider.rawValue, for: .aiProvider)
    }

    func setLocalEndpointBaseURL(_ baseURL: String) {
        set(baseURL, for: .localEndpointBaseURL)
    }

    /// The global model for the active provider; each provider keeps its own selection.
    var activeGlobalModelID: String {
        globalModelID(for: aiProviderSettings.provider)
    }

    func globalModelID(for provider: AIProvider) -> String {
        switch provider {
        case .openRouter:
            return string(for: .selectedModel) ?? AIModelDefaults.defaultModelID
        case .openAICompatible:
            return string(for: .localSelectedModel) ?? ""
        case .codex:
            return string(for: .codexSelectedModel) ?? ""
        case .claudeCode:
            return string(for: .claudeSelectedModel) ?? "sonnet"
        }
    }

    func setGlobalModelID(_ modelID: String, for provider: AIProvider) {
        switch provider {
        case .openRouter:
            set(modelID, for: .selectedModel)
        case .openAICompatible:
            set(modelID, for: .localSelectedModel)
        case .codex:
            set(modelID, for: .codexSelectedModel)
        case .claudeCode:
            set(modelID, for: .claudeSelectedModel)
        }
    }

    func setActiveGlobalModelID(_ modelID: String) {
        setGlobalModelID(modelID, for: aiProviderSettings.provider)
    }

    func subscriptionExecutablePath(for provider: AIProvider) -> String? {
        switch provider {
        case .codex: string(for: .codexExecutablePath)
        case .claudeCode: string(for: .claudeExecutablePath)
        case .openRouter, .openAICompatible: nil
        }
    }

    func setSubscriptionExecutablePath(_ path: String?, for provider: AIProvider) {
        let path = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .codex: set(path?.isEmpty == false ? path : nil, for: .codexExecutablePath)
        case .claudeCode: set(path?.isEmpty == false ? path : nil, for: .claudeExecutablePath)
        case .openRouter, .openAICompatible: break
        }
    }
}
