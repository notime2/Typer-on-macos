// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

enum ChatStreamEvent: Sendable, Equatable {
    case text(String)
    case image(data: Data, mimeType: String)
    case invalidImage
}

enum AIServiceFeatureError: LocalizedError, Sendable, Equatable {
    case imageGenerationUnsupported
    case emptyImageGenerationPrompt

    var errorDescription: String? {
        switch self {
        case .imageGenerationUnsupported:
            return "This AI service does not support image generation."
        case .emptyImageGenerationPrompt:
            return "Enter a prompt before generating an image."
        }
    }
}

protocol AIService: Sendable {
    func stream(request: ChatRequest, config: ResolvedAIConfig) -> AsyncThrowingStream<String, Error>
    func streamChat(request: ChatRequest, config: ResolvedAIConfig) -> AsyncThrowingStream<ChatStreamEvent, Error>
    func generateImages(
        request: ImageGenerationRequest,
        config: ResolvedAIConfig
    ) async throws -> ImageGenerationResult
}

extension AIService {
    func streamChat(
        request: ChatRequest,
        config: ResolvedAIConfig
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in stream(request: request, config: config) {
                        if Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        continuation.yield(.text(chunk))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func generateImages(
        request: ImageGenerationRequest,
        config: ResolvedAIConfig
    ) async throws -> ImageGenerationResult {
        throw AIServiceFeatureError.imageGenerationUnsupported
    }
}
