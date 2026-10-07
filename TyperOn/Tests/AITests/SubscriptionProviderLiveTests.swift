// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

/// Opt-in only: actual installed CLIs and accounts. Four short synthetic requests,
/// with no saved settings changes. Enable TYPERON_LIVE_SUBSCRIPTIONS=1 in the test host.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct SubscriptionProviderLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPERON_LIVE_SUBSCRIPTIONS"] == "1"),
          arguments: [AIProvider.codex, .claudeCode])
    func installedSubscriptionStreamsTextAndUnderstandsImage(provider: AIProvider) async throws {
        let connection = await SubscriptionCLI.checkConnection(provider: provider, executablePath: nil)
        try #require(connection.isReady, "The installed CLI is not signed in with a subscription")
        let model = try #require(connection.models.first(where: {
            $0.supportsImageInput && $0.reasoningEfforts?.contains { $0.id == "low" } == true
        }), "No exact model advertising image input and Low effort was returned")
        let service = SubscriptionAIService(provider: provider, executablePath: connection.executablePath)
        let config = ResolvedAIConfig(apiKey: "", model: model.id, temperature: 0.1, maxTokens: 100,
                                      reasoningEffort: "low")
        let textRequest = ChatRequest(model: model.id, messages: [
            .system("Return only the exact requested text."),
            .user("Return exactly TYPERON_SUBSCRIPTION_OK")
        ])
        var text = ""
        for try await part in service.stream(request: textRequest, config: config) { text += part }
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "TYPERON_SUBSCRIPTION_OK")

        // A generated 16x16 red PNG; no screen capture or personal content.
        let png = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="
        let imageRequest = ChatRequest(model: model.id, messages: [
            .system("Name the solid color of the image. Reply with one English word in uppercase."),
            .user("What color is this image?", imageURLs: ["data:image/png;base64," + png])
        ])
        var answer = ""
        for try await event in service.streamChat(request: imageRequest, config: config) {
            if case .text(let part) = event { answer += part }
        }
        #expect(answer.trimmingCharacters(in: .whitespacesAndNewlines) == "RED")
    }
}
