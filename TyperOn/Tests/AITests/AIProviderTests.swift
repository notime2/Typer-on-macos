// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@Suite
struct AIProviderResolutionTests {
    @Test
    func missingOrUnknownProviderValuesResolveToOpenRouter() {
        #expect(AIProvider.resolve(rawValue: nil) == .openRouter)
        #expect(AIProvider.resolve(rawValue: "") == .openRouter)
        #expect(AIProvider.resolve(rawValue: "anthropic-direct") == .openRouter)
        #expect(AIProvider.resolve(rawValue: "openRouter") == .openRouter)
        #expect(AIProvider.resolve(rawValue: "openAICompatible") == .openAICompatible)
    }

    @Test
    func defaultSettingsKeepOpenRouterTransport() {
        let settings = AIProviderSettings.resolve(provider: nil, localBaseURL: nil)
        #expect(settings.provider == .openRouter)
        #expect(settings.localBaseURL == nil)
        #expect(settings.endpoint == .openRouter)
        #expect(settings.catalogSource == .openRouter)
    }

    @Test
    func localProviderWithoutUsableBaseURLHasNoTransport() {
        for raw in ["", "   ", "localhost:11434/v1", "http://example.com/v1"] {
            let settings = AIProviderSettings.resolve(provider: "openAICompatible", localBaseURL: raw)
            #expect(settings.provider == .openAICompatible)
            #expect(settings.localBaseURL == nil)
            #expect(settings.endpoint == nil)
            #expect(settings.catalogSource == .unconfigured)
        }
    }

    @Test
    func localProviderResolvesEndpointAndCatalogSource() throws {
        let settings = AIProviderSettings.resolve(
            provider: "openAICompatible", localBaseURL: "http://localhost:11434/v1/"
        )
        let endpoint = try #require(settings.endpoint)
        #expect(endpoint.provider == .openAICompatible)
        #expect(endpoint.baseURL.absoluteString == "http://localhost:11434/v1")
        #expect(settings.catalogSource == .openAICompatible(baseURL: endpoint.baseURL))
    }

    @Test
    func onboardingReadinessFollowsTheActiveProvider() throws {
        let localURL = try AIEndpointURL.normalize(AIEndpointURL.lmStudioExample)
        #expect(AIProviderReadiness.isConfigured(provider: .openRouter, hasOpenRouterKey: true, localBaseURL: nil))
        #expect(!AIProviderReadiness.isConfigured(provider: .openRouter, hasOpenRouterKey: false, localBaseURL: localURL))
        #expect(AIProviderReadiness.isConfigured(provider: .openAICompatible, hasOpenRouterKey: false, localBaseURL: localURL))
        #expect(!AIProviderReadiness.isConfigured(provider: .openAICompatible, hasOpenRouterKey: true, localBaseURL: nil))
    }

    @Test
    func moduleInheritanceHintsNameTheActiveProvider() {
        #expect(ModuleProviderHint.credentialLabel(provider: .openRouter, host: nil) == "Using global OpenRouter key")
        #expect(ModuleProviderHint.modelLabel(provider: .openRouter, host: nil) == "Using global model (OpenRouter)")
        #expect(
            ModuleProviderHint.credentialLabel(provider: .openAICompatible, host: "localhost:11434")
                == "Using local endpoint (localhost:11434)"
        )
        #expect(
            ModuleProviderHint.modelLabel(provider: .openAICompatible, host: "localhost:11434")
                == "Using global model (localhost:11434)"
        )
        #expect(
            ModuleProviderHint.credentialLabel(provider: .openAICompatible, host: nil)
                == "Using local endpoint (not configured)"
        )
    }
}

@Suite
struct AIEndpointURLTests {
    @Test
    func normalizationTrimsTrailingSlashesAndDuplicateSegments() throws {
        let cases: [(String, String)] = [
            ("http://localhost:11434/v1", "http://localhost:11434/v1"),
            ("  http://localhost:11434/v1/  ", "http://localhost:11434/v1"),
            ("http://localhost:11434/v1///", "http://localhost:11434/v1"),
            ("http://localhost:11434//v1", "http://localhost:11434/v1"),
            ("http://localhost:1234/v1/chat/completions", "http://localhost:1234/v1"),
            ("http://localhost:1234/v1/models", "http://localhost:1234/v1"),
            ("http://localhost:11434", "http://localhost:11434"),
            ("http://localhost:11434/v1?key=value#anchor", "http://localhost:11434/v1"),
            ("HTTP://localhost:11434/v1", "http://localhost:11434/v1"),
            ("https://models.example.com/openai/v1/", "https://models.example.com/openai/v1"),
        ]
        for (input, expected) in cases {
            let normalized = try AIEndpointURL.normalize(input)
            #expect(normalized.absoluteString == expected, "normalizing \(input)")
        }
    }

    @Test
    func requestURLsJoinExactlyOnce() throws {
        for raw in ["http://localhost:11434/v1", "http://localhost:11434/v1/", "http://localhost:11434/v1/chat/completions"] {
            let endpoint = AIEndpointConfiguration.openAICompatible(baseURL: try AIEndpointURL.normalize(raw))
            #expect(endpoint.chatCompletionsURL.absoluteString == "http://localhost:11434/v1/chat/completions")
            #expect(endpoint.modelsURL.absoluteString == "http://localhost:11434/v1/models")
            #expect(endpoint.imagesURL == nil)
            #expect(endpoint.displayHost == "localhost:11434")
        }

        let rootEndpoint = AIEndpointConfiguration.openAICompatible(
            baseURL: try AIEndpointURL.normalize("http://127.0.0.1:8080")
        )
        #expect(rootEndpoint.chatCompletionsURL.absoluteString == "http://127.0.0.1:8080/chat/completions")
        #expect(rootEndpoint.modelsURL.absoluteString == "http://127.0.0.1:8080/models")
    }

    @Test
    func plainHTTPIsAcceptedOnlyForLoopbackAndPrivateHosts() throws {
        let allowed = [
            "http://localhost:11434/v1",
            "http://127.0.0.1:11434/v1",
            "http://127.9.9.9/v1",
            "http://[::1]:1234/v1",
            "http://mac-studio.local:1234/v1",
            "http://10.0.0.7:8000/v1",
            "http://172.16.0.1:8000/v1",
            "http://172.31.255.255:8000/v1",
            "http://192.168.1.42:1234/v1",
        ]
        for raw in allowed {
            #expect(throws: Never.self) { try AIEndpointURL.normalize(raw) }
        }

        let rejected = [
            "http://example.com/v1",
            "http://8.8.8.8/v1",
            "http://11.0.0.1/v1",
            "http://172.15.0.1/v1",
            "http://172.32.0.1/v1",
            "http://192.169.0.1/v1",
            "http://[2001:db8::1]/v1",
        ]
        for raw in rejected {
            var captured: AIEndpointError?
            do {
                _ = try AIEndpointURL.normalize(raw)
            } catch let error as AIEndpointError {
                captured = error
            } catch {
                Issue.record("Unexpected error type for \(raw)")
            }
            guard case .insecureRemoteHost = captured else {
                Issue.record("Expected \(raw) to be rejected as an insecure remote host")
                continue
            }
        }
    }

    @Test
    func httpsIsAcceptedForAnyHostAndOtherSchemesAreRejected() throws {
        #expect(try AIEndpointURL.normalize("https://api.example.com/v1").absoluteString == "https://api.example.com/v1")
        #expect(try AIEndpointURL.normalize("https://127.0.0.1:8443/v1").absoluteString == "https://127.0.0.1:8443/v1")

        #expect(throws: AIEndpointError.emptyBaseURL) { try AIEndpointURL.normalize("   ") }
        #expect(throws: AIEndpointError.unsupportedScheme("ftp")) { try AIEndpointURL.normalize("ftp://localhost/v1") }
        #expect(throws: AIEndpointError.unsupportedScheme("localhost")) {
            try AIEndpointURL.normalize("localhost:11434/v1")
        }
        #expect(throws: AIEndpointError.malformedBaseURL) { try AIEndpointURL.normalize("/v1/models") }
        #expect(throws: AIEndpointError.missingHost) { try AIEndpointURL.normalize("http:///v1") }
    }

    @Test
    func openRouterEndpointKeepsItsExactURLsAndHeaderRules() {
        let endpoint = AIEndpointConfiguration.openRouter
        #expect(endpoint.baseURL.absoluteString == "https://openrouter.ai/api/v1")
        #expect(endpoint.chatCompletionsURL.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(endpoint.modelsURL.absoluteString == "https://openrouter.ai/api/v1/models")
        #expect(endpoint.imagesURL?.absoluteString == "https://openrouter.ai/api/v1/images")
        #expect(endpoint.sendsOpenRouterHeaders)
        #expect(endpoint.requiresAPIKey)

        let local = AIEndpointConfiguration.openAICompatible(baseURL: URL(string: "http://localhost:11434/v1")!)
        #expect(!local.sendsOpenRouterHeaders)
        #expect(!local.requiresAPIKey)
    }
}

@Suite(.serialized)
struct AIProviderPersistenceTests {
    @Test
    func providerAndBaseURLRoundTripThroughUserDefaults() throws {
        let suiteName = "AIProviderPersistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults.aiProviderSettings.provider == .openRouter)
        #expect(defaults.aiProviderSettings.endpoint == .openRouter)

        defaults.setAIProvider(.openAICompatible)
        defaults.setLocalEndpointBaseURL("http://localhost:1234/v1")
        #expect(defaults.string(for: .aiProvider) == "openAICompatible")
        #expect(defaults.aiProviderSettings.provider == .openAICompatible)
        #expect(defaults.aiProviderSettings.localBaseURL?.absoluteString == "http://localhost:1234/v1")

        defaults.set("not-a-provider", for: .aiProvider)
        #expect(defaults.aiProviderSettings.provider == .openRouter)

        defaults.setAIProvider(.openRouter)
        #expect(defaults.aiProviderSettings.endpoint == .openRouter)
    }

    @Test
    func eachProviderKeepsItsOwnGlobalModelSelection() throws {
        let suiteName = "AIProviderModel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults.activeGlobalModelID == AIModelDefaults.defaultModelID)
        #expect(defaults.globalModelID(for: .openAICompatible).isEmpty)

        defaults.setActiveGlobalModelID("openai/gpt-4o")
        #expect(defaults.string(for: .selectedModel) == "openai/gpt-4o")
        #expect(defaults.object(forKey: SettingsKey.localSelectedModel.rawValue) == nil)

        defaults.setAIProvider(.openAICompatible)
        defaults.setLocalEndpointBaseURL(AIEndpointURL.ollamaExample)
        #expect(defaults.activeGlobalModelID.isEmpty)

        defaults.setActiveGlobalModelID("gemma4:e2b-mlx")
        #expect(defaults.string(for: .localSelectedModel) == "gemma4:e2b-mlx")
        #expect(defaults.string(for: .selectedModel) == "openai/gpt-4o")
        #expect(defaults.activeGlobalModelID == "gemma4:e2b-mlx")

        defaults.setAIProvider(.openRouter)
        #expect(defaults.activeGlobalModelID == "openai/gpt-4o")
    }

    @Test
    func localEndpointKeyUsesItsOwnKeychainAccount() {
        let storage = ProviderKeychainMemory()
        let keychain = KeychainService(accessOverrides: storage.overrides)

        keychain.setGlobalAPIKey("openrouter-key")
        keychain.setLocalEndpointAPIKey("local-key")

        #expect(keychain.getGlobalAPIKey() == "openrouter-key")
        #expect(keychain.getLocalEndpointAPIKey() == "local-key")
        #expect(storage.snapshot()["local-endpoint-api-key"] == "local-key")
        #expect(storage.snapshot()["openrouter-api-key"] == "openrouter-key")

        keychain.deleteLocalEndpointAPIKey()
        #expect(keychain.getLocalEndpointAPIKey() == nil)
        #expect(keychain.getGlobalAPIKey() == "openrouter-key")
    }

    @Test
    func replayGateKeepsTheLocalEndpointKeyUnreadable() {
        let storage = ProviderKeychainMemory()
        storage.seed("local-endpoint-api-key", "local-key")
        let replay = KeychainService(allowsSystemAccess: false, accessOverrides: storage.overrides)

        #expect(replay.getLocalEndpointAPIKey() == nil)
        replay.setLocalEndpointAPIKey("synthetic replacement")
        replay.deleteLocalEndpointAPIKey()
        #expect(storage.snapshot()["local-endpoint-api-key"] == "local-key")
    }
}

private final class ProviderKeychainMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func snapshot() -> [String: String] { lock.withLock { values } }

    func seed(_ account: String, _ value: String) {
        lock.withLock { values[account] = value }
    }

    var overrides: KeychainAccessOverrides {
        KeychainAccessOverrides(
            read: { [self] account in lock.withLock { values[account] } },
            write: { [self] account, value in lock.withLock { values[account] = value } },
            delete: { [self] account in lock.withLock { _ = values.removeValue(forKey: account) } }
        )
    }
}
