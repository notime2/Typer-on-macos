// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// OpenRouter-shaped Chat Completions transport.
/// The endpoint configuration parameterizes URLs, headers and credential rules, so the
/// OpenAI-compatible local provider reuses this SSE path instead of duplicating it.
final class AIEndpointService: AIService, @unchecked Sendable {
    private let session: URLSession

    let endpoint: AIEndpointConfiguration
    let apiKey: String
    let defaultModel: String
    let defaultTemperature: Double
    let defaultMaxTokens: Int

    init(
        endpoint: AIEndpointConfiguration = .openRouter,
        apiKey: String,
        defaultModel: String = AIModelDefaults.defaultModelID,
        defaultTemperature: Double = 0.7,
        defaultMaxTokens: Int = 20480,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.defaultModel = defaultModel
        self.defaultTemperature = defaultTemperature
        self.defaultMaxTokens = defaultMaxTokens

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: config)
        }
    }

    func stream(request: ChatRequest, config: ResolvedAIConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in streamChat(request: request, config: config) {
                        if Task.isCancelled {
                            continuation.finish(throwing: AIError.cancelled)
                            return
                        }

                        if case .text(let content) = event {
                            continuation.yield(content)
                        }
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

    func streamChat(
        request: ChatRequest,
        config: ResolvedAIConfig
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let streamRequest = ChatRequest(
                        model: config.model,
                        messages: request.messages,
                        temperature: config.temperature,
                        maxTokens: config.maxTokens,
                        stream: true
                    )

                    let urlRequest = try buildURLRequest(for: streamRequest, apiKey: config.apiKey)
                    let (bytes, response) = try await session.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AIError.invalidResponse
                    }
                    if !(200...299).contains(httpResponse.statusCode) {
                        var bodyData = Data()
                        for try await byte in bytes {
                            bodyData.append(byte)
                        }
                        try self.validateResponse(httpResponse, data: bodyData)
                    }

                    var seenImagePayloads = Set<Data>()
                    var hasSeenText = false
                    var receivedTerminalMarker = false
                    streamLines: for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.finish(throwing: AIError.cancelled)
                            return
                        }

                        switch SSEParser.parseLine(line) {
                        case .ignored:
                            continue
                        case .done:
                            receivedTerminalMarker = true
                            break streamLines
                        case .malformedData:
                            throw AIError.invalidResponse
                        case .response(let response):
                            if let providerError = response.error {
                                throw self.streamError(from: providerError)
                            }
                            if response.choices.contains(where: { $0.finish_reason == "error" }) {
                                throw AIError.httpError(
                                    statusCode: 500,
                                    body: "\(self.providerLabel) stream ended with an error."
                                )
                            }

                            let events = SSEParser.parseEvents(
                                response: response,
                                seenImagePayloads: &seenImagePayloads,
                                hasSeenText: &hasSeenText
                            )
                            for event in events {
                                continuation.yield(event)
                            }
                        }
                    }

                    guard receivedTerminalMarker else {
                        throw AIError.invalidResponse
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
        let urlRequest = try buildImagesURLRequest(for: request, config: config)
        let (data, response) = try await session.data(for: urlRequest)
        try validateResponse(response, data: data)
        return try Self.decodeImageGenerationResult(from: data)
    }

    // MARK: - Requests

    func buildURLRequest(for request: ChatRequest, apiKey: String) throws -> URLRequest {
        guard !apiKey.isEmpty || !endpoint.requiresAPIKey else { throw AIError.noAPIKey }

        var urlRequest = URLRequest(url: endpoint.chatCompletionsURL)
        urlRequest.httpMethod = "POST"
        if !apiKey.isEmpty {
            urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        endpoint.addAttributionHeaders(to: &urlRequest)
        urlRequest.httpBody = try JSONEncoder().encode(request)

        return urlRequest
    }

    func buildImagesURLRequest(
        for request: ImageGenerationRequest,
        config: ResolvedAIConfig
    ) throws -> URLRequest {
        guard let imagesURL = endpoint.imagesURL else {
            throw AIServiceFeatureError.imageGenerationUnsupported
        }
        guard !config.apiKey.isEmpty else { throw AIError.noAPIKey }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIServiceFeatureError.emptyImageGenerationPrompt
        }

        let resolvedRequest = ImageGenerationRequest(
            model: config.model,
            prompt: request.prompt,
            inputReferences: request.inputReferences
        )

        var urlRequest = URLRequest(url: imagesURL)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        endpoint.addAttributionHeaders(to: &urlRequest)
        urlRequest.httpBody = try JSONEncoder().encode(resolvedRequest)
        return urlRequest
    }

    static func decodeImageGenerationResult(from data: Data) throws -> ImageGenerationResult {
        let response: ImagesResponse
        do {
            response = try JSONDecoder().decode(ImagesResponse.self, from: data)
        } catch {
            throw AIError.invalidResponse
        }

        guard !response.data.isEmpty else { throw AIError.invalidResponse }

        var images: [GeneratedImage] = []
        var invalidImageCount = 0
        for image in response.data {
            guard let b64JSON = image.b64JSON,
                  let decodedData = Data(base64Encoded: b64JSON),
                  !decodedData.isEmpty,
                  let mimeType = normalizedImageMIMEType(image.mediaType, data: decodedData) else {
                invalidImageCount += 1
                continue
            }
            images.append(GeneratedImage(data: decodedData, mimeType: mimeType))
        }

        return ImageGenerationResult(images: images, invalidImageCount: invalidImageCount)
    }

    private static func normalizedImageMIMEType(_ mediaType: String?, data: Data) -> String? {
        let resolvedMediaType: String
        if let mediaType {
            resolvedMediaType = mediaType
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let typeIdentifier = CGImageSourceGetType(source) as String?,
                  let inferredMediaType = UTType(typeIdentifier)?.preferredMIMEType else {
                return nil
            }
            resolvedMediaType = inferredMediaType
        }

        let normalized = resolvedMediaType.lowercased()
        guard normalized.hasPrefix("image/") else { return nil }

        let subtype = normalized.dropFirst("image/".count)
        guard !subtype.isEmpty else { return nil }

        let validCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.+-")
        guard subtype.unicodeScalars.allSatisfy(validCharacters.contains) else { return nil }
        return normalized
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }
        try validateResponse(httpResponse, data: data)
    }

    private func validateResponse(_ httpResponse: HTTPURLResponse, data: Data) throws {
        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401:
            throw AIError.invalidAPIKey
        case 402:
            throw AIError.insufficientCredits
        case 404:
            let model = parseErrorModel(from: data)
            throw AIError.modelNotFound(model)
        case 429:
            throw AIError.rateLimited
        case 408, 504:
            throw AIError.timeout
        default:
            let body = parseErrorMessage(from: data)
            throw AIError.httpError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    private func parseErrorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return sanitizedProviderMessage(message)
        }
        return sanitizedProviderMessage(String(data: data, encoding: .utf8) ?? "Unknown error")
    }

    private var providerLabel: String {
        endpoint.provider == .openRouter ? "OpenRouter" : "The local endpoint"
    }

    private func sanitizedProviderMessage(_ message: String) -> String {
        let lowercaseMessage = message.lowercased()
        if lowercaseMessage.contains("data:image")
            || lowercaseMessage.contains(#"data:image\/"#)
            || lowercaseMessage.contains(";base64,")
            || lowercaseMessage.contains("b64_json") {
            return "\(providerLabel) returned an error. Image data was omitted."
        }

        let redacted = message.replacingOccurrences(
            of: #"data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=_-]+"#,
            with: "[image data omitted]",
            options: [.regularExpression, .caseInsensitive]
        )
        let maximumLength = 2_048
        guard redacted.count > maximumLength else { return redacted }
        return String(redacted.prefix(maximumLength)) + "..."
    }

    private func streamError(from providerError: ChatResponse.ProviderError) -> AIError {
        switch providerError.code {
        case 401:
            return .invalidAPIKey
        case 402:
            return .insufficientCredits
        case 408, 504:
            return .timeout
        case 429:
            return .rateLimited
        default:
            return .httpError(
                statusCode: providerError.code ?? 500,
                body: sanitizedProviderMessage(providerError.message)
            )
        }
    }

    private func parseErrorModel(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let metadata = error["metadata"] as? [String: Any],
           let model = metadata["model"] as? String {
            return model
        }
        return "unknown"
    }

    private struct ImagesResponse: Decodable {
        let data: [Image]

        struct Image: Decodable {
            let b64JSON: String?
            let mediaType: String?

            private enum CodingKeys: String, CodingKey {
                case b64JSON = "b64_json"
                case mediaType = "media_type"
            }

            init(from decoder: any Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                    b64JSON = nil
                    mediaType = nil
                    return
                }
                b64JSON = try? container.decodeIfPresent(String.self, forKey: .b64JSON)
                mediaType = try? container.decodeIfPresent(String.self, forKey: .mediaType)
            }
        }
    }
}
