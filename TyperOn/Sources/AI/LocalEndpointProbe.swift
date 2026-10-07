// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

enum LocalEndpointProbeResult: Equatable, Sendable {
    case success(modelCount: Int)
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success(let modelCount):
            return modelCount == 1 ? "Connected. 1 model available." : "Connected. \(modelCount) models available."
        case .failure(let message):
            return message
        }
    }
}

/// `Test Connection` in Settings -> API \ Models: one `GET {baseURL}/models` that never writes settings or Keychain.
struct LocalEndpointProbe: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: configuration)
        }
    }

    func probe(baseURLText: String, apiKey: String) async -> LocalEndpointProbeResult {
        let baseURL: URL
        do {
            baseURL = try AIEndpointURL.normalize(baseURLText)
        } catch {
            return .failure(error.localizedDescription)
        }
        return await probe(endpoint: .openAICompatible(baseURL: baseURL), apiKey: apiKey)
    }

    func probe(endpoint: AIEndpointConfiguration, apiKey: String) async -> LocalEndpointProbeResult {
        do {
            let data = try await AIEndpointRequest.data(
                url: endpoint.modelsURL,
                endpoint: endpoint,
                apiKey: apiKey,
                session: session
            )
            let response = try JSONDecoder().decode(OpenAIModelListResponse.self, from: data)
            return .success(modelCount: response.modelIDs.count)
        } catch let error as AIEndpointRequestError {
            return .failure(error.localizedDescription)
        } catch is DecodingError {
            return .failure("The endpoint answered, but the model list was not in the OpenAI format.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

enum AIEndpointRequestError: LocalizedError, Equatable, Sendable {
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "The endpoint answered with HTTP \(code)."
        case .invalidResponse:
            return "The endpoint did not return a valid HTTP response."
        }
    }
}

/// Shared GET helper for catalog and connection checks; it carries the provider's header rules.
enum AIEndpointRequest {
    static func data(
        url: URL,
        endpoint: AIEndpointConfiguration,
        apiKey: String,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        endpoint.addAttributionHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw failure(for: endpoint, statusCode: nil)
        }
        guard http.statusCode == 200 else {
            throw failure(for: endpoint, statusCode: http.statusCode)
        }
        return data
    }

    /// OpenRouter keeps the `URLError` its catalog reported before the endpoint became configurable;
    /// a user-configured local endpoint reports the status code instead.
    private static func failure(for endpoint: AIEndpointConfiguration, statusCode: Int?) -> any Error {
        switch endpoint.provider {
        case .openRouter:
            return URLError(.badServerResponse)
        case .openAICompatible:
            guard let statusCode else { return AIEndpointRequestError.invalidResponse }
            return AIEndpointRequestError.httpStatus(statusCode)
        case .codex, .claudeCode:
            return AIEndpointRequestError.invalidResponse
        }
    }
}
