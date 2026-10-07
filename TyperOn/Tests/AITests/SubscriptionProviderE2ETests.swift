// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Foundation
import Testing
@testable import Typer_On

/// Process e2e: persisted settings -> AppEnvironment -> real view models -> executable
/// fixture -> streamed UI state. No AIService mock and no real credentials/network.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct SubscriptionProviderE2ETests {
    @Test(arguments: ["codex", "claudeCode"])
    func savedEffortReachesBothProcessingAndChat(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        fixture.defaults.set("high", forKey: providerID == "codex" ? "codexReasoningEffort" : "claudeReasoningEffort")
        let environment = try fixture.environment()
        let processing = ProcessingViewModel(environment: environment)
        processing.process(module: TranslationModule(), selection: fixture.selection)
        await processing.waitForPendingWorkForTesting()
        #expect(processing.error == nil)
        #expect(try fixture.lastEffort() == "high")

        let chat = ChatViewModel(environment: environment)
        chat.inputText = "Synthetic effort question"
        chat.sendMessage()
        await chat.waitForPendingWorkForTesting()
        #expect(chat.error == nil)
        #expect(try fixture.lastEffort() == "high")
    }

    @Test(arguments: ["codex", "claudeCode"])
    func defaultEffortLeavesCLIConfigurationUntouched(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        let provider = try #require(AIProvider(rawValue: providerID))
        fixture.defaults.setReasoningEffort("high", for: provider)
        fixture.defaults.setReasoningEffort(nil, for: provider)
        #expect(fixture.defaults.reasoningEffort(for: provider) == nil)
        let environment = try fixture.environment()
        #expect(environment.resolveAIConfig(for: TranslationModule()).reasoningEffort == nil)
        let processing = ProcessingViewModel(environment: environment)
        processing.process(module: TranslationModule(), selection: fixture.selection)
        await processing.waitForPendingWorkForTesting()
        #expect(processing.error == nil)
        #expect(processing.resultText == "Synthetic reply")
        #expect(try fixture.lastEffort() == nil)
    }

    @Test(arguments: ["codex", "claudeCode"])
    func moduleOverrideReconcilesEffortAgainstItsOwnModel(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        let provider = try #require(AIProvider(rawValue: providerID))
        fixture.defaults.setReasoningEffort("high", for: provider)
        let environment = try fixture.environment()
        for model in ["e2e-override", "e2e-no-effort", "e2e-unknown"] {
            fixture.defaults.set(try JSONEncoder().encode([
                "translation": ModuleAIConfig(useGlobal: false, customModel: model)
            ]), for: .moduleAIConfigs)
            let config = environment.resolveAIConfig(for: TranslationModule())
            #expect(config.model == model)
            #expect(config.reasoningEffort == "high")
            let processing = ProcessingViewModel(environment: environment)
            processing.process(module: TranslationModule(), selection: fixture.selection)
            await processing.waitForPendingWorkForTesting()
            #expect(processing.error == nil)
            #expect(processing.resultText == "Synthetic reply")
            #expect(try fixture.lastTurnInput().contains(model))
            // Only Codex declares a fallback default for the override model.
            #expect(try fixture.lastEffort() == (provider == .codex && model == "e2e-override" ? "low" : nil))
            #expect(fixture.defaults.reasoningEffort(for: provider) == "high")
        }
    }

    @Test(arguments: ["codex", "claudeCode"])
    func modelCatalogPreservesAdvertisedEffortLevels(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        let provider = try #require(AIProvider(rawValue: providerID))
        let source = ModelCatalogSource.subscription(provider: provider,
            executablePath: fixture.defaults.subscriptionExecutablePath(for: provider))
        let catalog = ModelCatalogService(userDefaults: fixture.defaults)
        catalog.setSource(source)
        await catalog.fetchModels(apiKey: "")
        let connection = try #require(catalog.subscriptionConnectionResult)
        try #require(connection.isReady)
        let data = try JSONEncoder().encode(connection.models)
        let models = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let model = try #require(models.first)
        let efforts = model["reasoningEfforts"] as? [[String: Any]]
        #expect(efforts?.contains { $0["id"] as? String == "high" } == true)
        let cached = ModelCatalogService(userDefaults: fixture.defaults, allowsRemoteRequests: false)
        cached.setSource(source)
        await cached.loadCached()
        let restored = try #require(cached.model(for: "e2e-model"))
        #expect(restored.reasoningEfforts?.map(\.id) == (provider == .codex
            ? ["low", "medium", "high"] : ["low", "medium", "high", "max"]))
        #expect(restored.defaultReasoningEffort == (provider == .codex ? "medium" : nil))
        #expect(restored == catalog.model(for: "e2e-model"))

        // The old cache schema has neither optional effort field.
        let legacy: [String: Any] = [
            "executablePath": try #require(fixture.defaults.subscriptionExecutablePath(for: provider)),
            "models": [["id": "legacy-model", "name": "Legacy model"]]
        ]
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: legacy),
            for: provider == .codex ? .cachedCodexModels : .cachedClaudeModels)
        let legacyCatalog = ModelCatalogService(userDefaults: fixture.defaults, allowsRemoteRequests: false)
        legacyCatalog.setSource(source)
        await legacyCatalog.loadCached()
        let legacyModel = try #require(legacyCatalog.model(for: "legacy-model"))
        #expect(legacyModel.reasoningEfforts == nil)
        #expect(legacyModel.defaultReasoningEffort == nil)
        #expect(legacyModel.reconciledReasoningEffort("high") == nil)
    }

    @Test
    func inheritedCustomHeadersCannotReplaceSubscriptionAuthentication() {
        let environment = SubscriptionCLI.environment(executable: URL(fileURLWithPath: "/synthetic/claude"), base: [
            "ANTHROPIC_CUSTOM_HEADERS": "Authorization: Bearer synthetic-external-token\nX-Api-Key: synthetic-external-api-key",
            "ANTHROPIC_API_KEY": "synthetic-api-key",
            "CODEX_HOME": "/synthetic/codex-home",
            "CLAUDE_CONFIG_DIR": "/synthetic/claude-home",
            "FORCE_COLOR": "1"
        ])
        #expect(environment["ANTHROPIC_CUSTOM_HEADERS"] == nil)
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["CODEX_HOME"] == "/synthetic/codex-home")
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/synthetic/claude-home")
        #expect(environment["FORCE_COLOR"] == nil)
        #expect(environment["NO_COLOR"] == "1")
    }

    @Test(arguments: ["expired", "expiringSoon"])
    func officialClaudeExpiryStatusDistinguishesUnusableLoginFromRenewalWarning(mode: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: "claudeCode")
        defer { fixture.cleanUp() }
        try fixture.setMode(mode)
        let result = await SubscriptionCLI.checkConnection(provider: .claudeCode,
            executablePath: fixture.defaults.subscriptionExecutablePath(for: .claudeCode))
        #expect(result.isReady == (mode == "expiringSoon"))
        if mode == "expired" { #expect(result.message.contains("Sign in")) }
        #expect(try fixture.recordedInput().contains("--text"))
    }

    @Test
    func settingsEntryHasRequestedTitle() {
        #expect(SettingsTab.api.title == "API \\ Models")
        #expect(SettingsSidebarItem(tab: .api).title == "API \\ Models")
    }

    @Test(arguments: ["codex", "claudeCode"])
    func allTextActionsReachSelectedCLI(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        fixture.defaults.setReasoningEffort("high", for: try #require(AIProvider(rawValue: providerID)))
        let environment = try fixture.environment()
        let custom = CustomPromptModule(id: "e2e-custom", name: "E2E custom", icon: "star",
                                        shortDescription: nil, systemPrompt: "Return the synthetic result.")
        let modules = environment.moduleRegistry.modules.filter { $0.id != "content-generation" }
            + [custom as any TextModule]
        #expect(modules.count >= 8)
        for module in modules {
            let viewModel = ProcessingViewModel(environment: environment)
            viewModel.process(module: module, selection: fixture.selection)
            await viewModel.waitForPendingWorkForTesting()
            #expect(viewModel.error == nil, "Module \(module.id) failed: \(viewModel.error ?? "")")
            #expect(viewModel.resultText == "Synthetic reply", "Module \(module.id) did not stream")
            #expect(!viewModel.isStreaming)
            #expect(try fixture.lastEffort() == "high", "Module \(module.id) dropped saved effort")
        }
        #expect(try fixture.recordedInput().contains("Synthetic selection"))
    }

    @Test(arguments: ["codex", "claudeCode"])
    func chatFollowUpAndModuleOverrideReachCLI(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        fixture.defaults.setReasoningEffort("high", for: try #require(AIProvider(rawValue: providerID)))
        fixture.defaults.set(try JSONEncoder().encode([
            "content-generation": ModuleAIConfig(useGlobal: false, customModel: "e2e-override")
        ]), for: .moduleAIConfigs)
        let environment = try fixture.environment()
        let viewModel = ChatViewModel(environment: environment)
        viewModel.setPendingSelectionText("Synthetic context")
        viewModel.inputText = "Synthetic first question"
        viewModel.sendMessage()
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.error == nil)
        #expect(viewModel.messages.last?.text == "Synthetic reply")
        #expect(try fixture.lastEffort() == (providerID == "codex" ? "low" : nil))
        viewModel.inputText = "Synthetic follow-up"
        viewModel.sendMessage()
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.error == nil)
        #expect(viewModel.messages.filter { $0.role == .assistant }.count == 2)
        #expect(viewModel.messages.last?.text == "Synthetic reply")
        #expect(try fixture.lastEffort() == (providerID == "codex" ? "low" : nil))
        let recorded = try fixture.lastTurnInput()
        for required in ["Synthetic context", "Synthetic first question", "Synthetic reply", "Synthetic follow-up", "e2e-override"] {
            #expect(recorded.contains(required), "CLI input missing \(required)")
        }
    }

    @Test(arguments: ["codex", "claudeCode"])
    func refineAndAutomaticReplacementUseSuccessfulFinalResult(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        fixture.defaults.setReasoningEffort("high", for: try #require(AIProvider(rawValue: providerID)))
        let environment = try fixture.environment()
        var replacements: [String] = []
        let viewModel = ProcessingViewModel(environment: environment, replaceAction: { text, _ in
            replacements.append(text)
            return .replaced(.accessibility)
        })
        viewModel.process(module: GrammarFixModule(), selection: fixture.selection, mode: .automaticReplacement)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.error == nil)
        #expect(replacements == ["Synthetic reply"])
        viewModel.userComment = "Synthetic refinement"
        viewModel.refine()
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.resultText == "Synthetic reply")
        #expect(replacements.count == 1)
        #expect(try fixture.lastTurnInput().contains("Synthetic refinement"))
        #expect(try fixture.lastEffort() == "high")
    }

    @Test(arguments: ["codex", "claudeCode"])
    func failedTurnDoesNotReplaceAndRetryCanRecover(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        fixture.defaults.setReasoningEffort("high", for: try #require(AIProvider(rawValue: providerID)))
        try fixture.setMode("failure")
        let environment = try fixture.environment()
        var replacements = 0
        let viewModel = ProcessingViewModel(environment: environment, replaceAction: { _, _ in
            replacements += 1
            return .replaced(.accessibility)
        })
        viewModel.process(module: TranslationModule(), selection: fixture.selection, mode: .automaticReplacement)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.error != nil)
        #expect(!viewModel.isStreaming)
        #expect(replacements == 0)
        try fixture.setMode("success")
        viewModel.retry()
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.error == nil)
        #expect(viewModel.resultText == "Synthetic reply")
        #expect(try fixture.lastEffort() == "high")
    }

    @Test(arguments: ["codex", "claudeCode"])
    func providerModelsPersistIndependentlyAndReplayNeverSpawnsCLI(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        let provider = try #require(AIProvider(rawValue: providerID))
        fixture.defaults.setGlobalModelID("subscription-model", for: provider)
        fixture.defaults.setGlobalModelID("original-openrouter-model", for: .openRouter)
        #expect(fixture.defaults.globalModelID(for: provider) == "subscription-model")
        #expect(fixture.defaults.globalModelID(for: .openRouter) == "original-openrouter-model")
        fixture.defaults.setReasoningEffort("high", for: .codex)
        fixture.defaults.setReasoningEffort("low", for: .claudeCode)
        #expect(fixture.defaults.reasoningEffort(for: .codex) == "high")
        #expect(fixture.defaults.reasoningEffort(for: .claudeCode) == "low")
        fixture.defaults.setReasoningEffort(nil, for: .codex)
        #expect(fixture.defaults.string(for: .codexReasoningEffort) == nil)
        #expect(fixture.defaults.reasoningEffort(for: .claudeCode) == "low")
        fixture.defaults.setReasoningEffort("max", for: .openRouter)
        fixture.defaults.setReasoningEffort("max", for: .openAICompatible)
        #expect(fixture.defaults.reasoningEffort(for: .openRouter) == nil)
        #expect(fixture.defaults.reasoningEffort(for: .openAICompatible) == nil)
        #expect(fixture.defaults.reasoningEffort(for: .claudeCode) == "low")
        fixture.defaults.setReasoningEffort(" \n", for: .claudeCode)
        #expect(fixture.defaults.string(for: .claudeReasoningEffort) == nil)
        let replay = try StreamReplayFixture(chunks: ["Replay"], intervalMilliseconds: 1)
        let environment = AppEnvironment(streamReplayFixture: replay, userDefaults: fixture.defaults,
                                         chatHistoryStore: ChatHistoryStore(fileURL: nil))
        environment.bootstrap()
        await environment.modelCatalog.loadCached()
        await environment.modelCatalog.fetchModels(apiKey: "")
        #expect(environment.aiService == nil)
        #expect(environment.requestAIService is StreamReplayService)
        #expect(!FileManager.default.fileExists(atPath: fixture.inputLog.path))
    }

    @Test(arguments: ["codex", "claudeCode"])
    func screenshotTravelsInMemoryToSelectedCLI(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        fixture.defaults.setReasoningEffort("high", for: try #require(AIProvider(rawValue: providerID)))
        let environment = try fixture.environment()
        let service = try #require(environment.aiService)
        // A synthetic 1x1 PNG, never a desktop screenshot or personal content.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII="
        let request = ChatRequest(model: "e2e-model", messages: [
            .system("Describe the synthetic image."),
            .user("Synthetic image question", imageURLs: ["data:image/png;base64," + png])
        ])
        var result = ""
        for try await event in service.streamChat(request: request,
                                                  config: environment.resolveAIConfig(for: ContentGenerationModule())) {
            if case .text(let text) = event { result += text }
        }
        #expect(result == "Synthetic reply")
        #expect(try fixture.recordedInput().contains(png))
        #expect(try fixture.lastEffort() == "high")
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        #expect(!files.contains { $0.hasSuffix(".png") })
    }

    @Test(arguments: ["codex", "claudeCode"])
    func stopTerminatesActualChildAndNeverReplaces(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        try fixture.setMode("stall")
        let environment = try fixture.environment()
        var replacements = 0
        let viewModel = ProcessingViewModel(environment: environment, replaceAction: { _, _ in
            replacements += 1
            return .replaced(.accessibility)
        })
        viewModel.process(module: TranslationModule(), selection: fixture.selection, mode: .automaticReplacement)
        let pidFile = fixture.directory.appendingPathComponent("turn.pid")
        try await waitForProcessCondition { FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        viewModel.cancel()
        await viewModel.waitForPendingWorkForTesting()
        try await waitForProcessCondition { kill(pid, 0) != 0 }
        #expect(!viewModel.isStreaming)
        #expect(replacements == 0)
    }

    @Test(arguments: ["codex", "claudeCode"])
    func signedOutAccountFailsWithoutReplacing(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        try fixture.setMode("signedOut")
        let environment = try fixture.environment()
        var replacements = 0
        let viewModel = ProcessingViewModel(environment: environment, replaceAction: { _, _ in
            replacements += 1
            return .replaced(.accessibility)
        })
        viewModel.process(module: TranslationModule(), selection: fixture.selection, mode: .automaticReplacement)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.error != nil)
        #expect(!viewModel.isStreaming)
        #expect(replacements == 0)
    }

    @Test(arguments: ["codex", "claudeCode"])
    func connectionProbeRejectsAPIKeyAccount(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        try fixture.setMode("apiKey")
        let provider = try #require(AIProvider(rawValue: providerID))
        let result = await SubscriptionCLI.checkConnection(
            provider: provider, executablePath: fixture.defaults.subscriptionExecutablePath(for: provider)
        )
        #expect(!result.isReady)
        #expect(!result.message.isEmpty)
    }

    @Test(arguments: ["codex", "claudeCode"])
    func missingExplicitExecutableNeverFallsBackToInstalledCLI(providerID: String) async throws {
        let provider = try #require(AIProvider(rawValue: providerID))
        let result = await SubscriptionCLI.checkConnection(
            provider: provider, executablePath: "/missing-typeron-e2e-executable/\(providerID)"
        )
        #expect(!result.isReady)
        #expect(!result.message.isEmpty)
    }

    @Test(arguments: ["codex", "claudeCode"])
    func malformedCLIOutputFailsWithoutReplacement(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        try fixture.setMode("malformed")
        let environment = try fixture.environment()
        var replacements = 0
        let viewModel = ProcessingViewModel(environment: environment, replaceAction: { _, _ in
            replacements += 1
            return .replaced(.accessibility)
        })
        viewModel.process(module: TranslationModule(), selection: fixture.selection, mode: .automaticReplacement)
        await viewModel.waitForPendingWorkForTesting()
        #expect(viewModel.error != nil)
        #expect(!viewModel.isStreaming)
        #expect(replacements == 0)
    }

    @Test(arguments: ["codex", "claudeCode"])
    func draftConnectionCheckDoesNotChangeActiveProvider(providerID: String) async throws {
        let fixture = try SubscriptionCLIFixture(providerID: providerID)
        defer { fixture.cleanUp() }
        let provider = try #require(AIProvider(rawValue: providerID))
        fixture.defaults.setAIProvider(.openRouter)
        let environment = AppEnvironment(userDefaults: fixture.defaults, chatHistoryStore: ChatHistoryStore(fileURL: nil))
        // No bootstrap: OpenRouter remains unconfigured and cannot make a request in this test.
        let draft = environment.makeDraftModelCatalog()
        draft.setSource(.subscription(provider: provider, executablePath: fixture.defaults.subscriptionExecutablePath(for: provider)))
        await draft.fetchModels(apiKey: "")
        #expect(draft.subscriptionConnectionResult?.isReady == true)
        #expect(environment.providerSettings.provider == .openRouter)
        #expect(environment.modelCatalog.source == .openRouter)
        #expect(environment.modelCatalog.subscriptionConnectionResult == nil)
    }

    private func waitForProcessCondition(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "CLI process did not reach the expected lifecycle state")
    }
}

@MainActor
private struct SubscriptionCLIFixture {
    let suiteName = "SubscriptionE2E.\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL
    let providerID: String
    var inputLog: URL { directory.appendingPathComponent("input.jsonl") }
    var selection: TextSelection {
        TextSelection(text: "Synthetic selection", cursorPosition: .zero, sourceAppPID: 123)
    }

    init(providerID: String) throws {
        self.providerID = providerID
        defaults = try #require(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(providerID == "codex" ? "codex" : "claude")
        try Self.script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defaults.set(providerID, forKey: "aiProvider")
        defaults.set(executable.path, forKey: providerID == "codex" ? "codexExecutablePath" : "claudeExecutablePath")
        defaults.set("e2e-model", forKey: providerID == "codex" ? "codexSelectedModel" : "claudeSelectedModel")
    }

    func environment() throws -> AppEnvironment {
        // Fails before bootstrap on the old app, so the red run cannot contact OpenRouter.
        _ = try #require(AIProvider(rawValue: providerID), "Subscription provider is not implemented")
        let environment = AppEnvironment(userDefaults: defaults, chatHistoryStore: ChatHistoryStore(fileURL: nil))
        environment.bootstrap()
        #expect(environment.providerSettings.provider.rawValue == providerID)
        #expect(environment.aiService != nil)
        return environment
    }

    func setMode(_ mode: String) throws {
        try mode.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }

    func recordedInput() throws -> String { try String(contentsOf: inputLog, encoding: .utf8) }

    func lastEffort() throws -> String? {
        let entries = try recordedInput().split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        if providerID == "codex" {
            return (entries.last { $0["method"] as? String == "turn/start" })?["params"]
                .flatMap { $0 as? [String: Any] }?["effort"] as? String
        }
        let args = entries.compactMap { $0["argv"] as? [String] }.last { $0.contains("--system-prompt") }
        guard let args, let index = args.firstIndex(of: "--effort"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    func lastTurnInput() throws -> String {
        let entries = try recordedInput().split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let turn: [String: Any]?
        let instructions: [String: Any]?
        if providerID == "codex" {
            turn = entries.last { $0["method"] as? String == "turn/start" }
            instructions = entries.last { $0["method"] as? String == "thread/start" }
        } else {
            turn = entries.last { entry in
                guard let input = entry["stdin"] as? String,
                      let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any] else { return false }
                return object["type"] as? String == "user"
            }
            instructions = entries.last { ($0["argv"] as? [String])?.contains("--system-prompt") == true }
        }
        let data = try JSONSerialization.data(withJSONObject: [try #require(instructions), try #require(turn)])
        return String(decoding: data, as: UTF8.self)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Tiny real executable speaking the providers' public wire formats. Logs synthetic input only.
    private static let script = #"""
    #!/usr/bin/python3
    import json, os, signal, sys
    from pathlib import Path
    root = Path(__file__).parent
    def emit(value):
        print(json.dumps(value), flush=True)
    def record(value):
        with (root / 'input.jsonl').open('a') as out:
            out.write(json.dumps(value) + '\n')
    def failing():
        return (root / 'mode').exists() and (root / 'mode').read_text() == 'failure'
    def mode():
        return (root / 'mode').read_text() if (root / 'mode').exists() else 'success'
    def stall():
        if mode() == 'stall':
            (root / 'turn.pid.tmp').write_text(str(os.getpid()))
            (root / 'turn.pid.tmp').replace(root / 'turn.pid')
            signal.pause()
    record({'argv': sys.argv[1:]})
    if '--version' in sys.argv:
        print('fixture-cli 1.0')
        sys.exit(0)
    if 'auth' in sys.argv or 'login' in sys.argv:
        if 'auth' in sys.argv:
            if '--text' in sys.argv:
                if mode() == 'expired':
                    print('Login: Expired \u2014 log in again')
                else:
                    print('Login method: Claude Max account')
                    if mode() == 'expiringSoon':
                        print('Your login expires in 3 days - run /login to renew')
            else:
                emit({'loggedIn': mode() != 'signedOut', 'authMethod': 'api_key' if mode() == 'apiKey' else 'claude.ai', 'apiProvider': 'firstParty', 'subscriptionType': None if mode() == 'apiKey' else 'max'})
        else:
            print('Not logged in' if mode() == 'signedOut' else 'Logged in using an API key' if mode() == 'apiKey' else 'Logged in using ChatGPT')
        if mode() == 'signedOut':
            sys.exit(1)
        sys.exit(0)
    if 'app-server' in sys.argv:
        for line in sys.stdin:
            msg = json.loads(line)
            record(msg)
            method = msg.get('method', '')
            if 'id' not in msg:
                continue
            result = {}
            if method == 'initialize':
                result = {'userAgent': 'fixture-cli'}
            elif method == 'account/read':
                result = {'account': None if mode() == 'signedOut' else {'type': 'apiKey' if mode() == 'apiKey' else 'chatgpt', 'email': 'fixture@example.invalid', 'planType': 'plus'}, 'requiresOpenaiAuth': True}
            elif method == 'config/read':
                result = {'config': {'mcp_servers': {}, 'plugins': {}, 'features': {}}}
            elif method == 'model/list':
                result = {'data': [
                    {'id': 'e2e-model', 'model': 'e2e-model', 'displayName': 'E2E model', 'description': '', 'hidden': False, 'isDefault': True, 'inputModalities': ['text', 'image'], 'supportedReasoningEfforts': [{'reasoningEffort': level, 'description': level} for level in ['low', 'medium', 'high']], 'defaultReasoningEffort': 'medium'},
                    {'id': 'e2e-override', 'model': 'e2e-override', 'displayName': 'Override model', 'hidden': False, 'inputModalities': ['text'], 'supportedReasoningEfforts': [{'reasoningEffort': 'low', 'description': 'Low only'}], 'defaultReasoningEffort': 'low'},
                    {'id': 'e2e-no-effort', 'model': 'e2e-no-effort', 'displayName': 'No effort model', 'hidden': False, 'inputModalities': ['text']}
                ], 'nextCursor': None}
            elif method == 'thread/start':
                result = {'thread': {'id': 'e2e-thread'}}
            elif method == 'turn/start':
                result = {'turn': {'id': 'e2e-turn', 'status': 'inProgress', 'items': []}}
            emit({'id': msg['id'], 'result': result})
            if method == 'turn/start':
                if mode() == 'malformed':
                    print('this is not a JSON event', flush=True)
                    sys.exit(0)
                if mode() == 'signedOut':
                    emit({'method': 'turn/completed', 'params': {'threadId': 'e2e-thread', 'turn': {'id': 'e2e-turn', 'status': 'failed', 'error': {'message': 'Sign in to Codex first.'}}}})
                    continue
                for delta in ['Synthetic ', 'reply']:
                    emit({'method': 'item/agentMessage/delta', 'params': {'threadId': 'e2e-thread', 'turnId': 'e2e-turn', 'itemId': 'e2e-message', 'delta': delta}})
                stall()
                emit({'method': 'item/completed', 'params': {'threadId': 'e2e-thread', 'turnId': 'e2e-turn', 'item': {'id': 'e2e-message', 'type': 'agentMessage', 'text': 'Synthetic reply'}}})
                turn = {'id': 'e2e-turn', 'status': 'failed' if failing() else 'completed', 'items': []}
                if failing():
                    turn['error'] = {'message': 'Synthetic provider failure', 'codexErrorInfo': 'other'}
                emit({'method': 'turn/completed', 'params': {'threadId': 'e2e-thread', 'turn': turn}})
    elif 'exec' in sys.argv:
        record({'stdin': sys.stdin.read()})
        if mode() == 'signedOut':
            emit({'type': 'turn.failed', 'error': {'message': 'Sign in to Codex first.'}})
            sys.exit(1)
        emit({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': 'Synthetic reply'}})
        stall()
        emit({'type': 'turn.failed' if failing() else 'turn.completed', 'error': {'message': 'Synthetic provider failure'}})
    else:
        for line in sys.stdin:
            record({'stdin': line})
            try:
                message = json.loads(line)
            except ValueError:
                message = {}
            if message.get('type') == 'control_request':
                emit({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': message['request_id'], 'response': {'models': [
                    {'value': 'e2e-model', 'resolvedModel': 'claude-opus-5-5', 'displayName': 'E2E model', 'supportsEffort': True, 'supportedEffortLevels': ['low', 'medium', 'high', 'max']},
                    {'value': 'e2e-override', 'resolvedModel': 'claude-sonnet-5-5', 'displayName': 'Override model', 'supportsEffort': True, 'supportedEffortLevels': ['low']},
                    {'value': 'e2e-no-effort', 'resolvedModel': 'claude-haiku-4-5-20251001', 'displayName': 'No effort model'}
                ]}}})
                sys.exit(0)
            if '--input-format' in sys.argv:
                break
        if mode() == 'malformed':
            print('this is not a JSON event', flush=True)
            sys.exit(0)
        if mode() == 'signedOut':
            emit({'type': 'result', 'subtype': 'error_during_execution', 'is_error': True, 'errors': ['Sign in to Claude Code first.']})
            sys.exit(1)
        emit({'type': 'system', 'subtype': 'init', 'session_id': 'e2e-session', 'model': 'e2e-model'})
        for delta in ['Synthetic ', 'reply']:
            emit({'type': 'stream_event', 'event': {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': delta}}, 'session_id': 'e2e-session'})
        stall()
        emit({'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Synthetic reply'}]}, 'session_id': 'e2e-session'})
        emit({'type': 'result', 'subtype': 'error_during_execution' if failing() else 'success', 'is_error': failing(), 'result': 'Synthetic reply', 'errors': ['Synthetic provider failure'] if failing() else [], 'session_id': 'e2e-session'})
    """#
}
