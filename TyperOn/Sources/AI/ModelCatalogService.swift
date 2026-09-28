// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

enum AIModelDefaults {
    static let defaultModelID = "google/gemini-3.1-flash-lite-preview"
    static let defaultModelName = "Gemini 3.1 Flash Lite"
    static let defaultTemperature = 0.7
    static let defaultMaxTokens = 20480
}

@MainActor
@Observable
final class ModelCatalogService {
    private(set) var models: [OpenRouterModel] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var source: ModelCatalogSource = .openRouter
    private var resolvedModelsByID: [String: OpenRouterModel] = [:]
    private var modelResolutionIDs: [String: UUID] = [:]
    private var modelsByID: [String: OpenRouterModel] = [:]
    private var catalogGroups: [(provider: String, models: [OpenRouterModel])] = []
    @ObservationIgnored private var refreshes: [RefreshKey: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var resolutions: [ResolutionKey: (id: UUID, task: Task<OpenRouterModel?, Never>)] = [:]
    @ObservationIgnored private var cacheLoad: Task<Void, Never>?
    @ObservationIgnored private var latestRefreshID: UUID?
    @ObservationIgnored private var searchCache: (query: String, groups: [(provider: String, models: [OpenRouterModel])])?
    private let session: URLSession
    private let userDefaults: UserDefaults
    private let allowsRemoteRequests: Bool

    /// Local catalogs are stored per base URL, so switching endpoints never shows another endpoint's list.
    private struct LocalCatalogCache: Codable, Sendable {
        let endpoint: String
        let modelIDs: [String]
    }

    private struct RefreshKey: Hashable {
        let source: ModelCatalogSource
        // Credentials are used only to separate in-flight work, never persisted or logged.
        let apiKey: String
    }

    private struct ResolutionKey: Hashable {
        let modelID: String
        // Credentials are used only to separate in-flight work, never persisted or logged.
        let apiKey: String
    }

    private struct PreparedCatalog: Sendable {
        let models: [OpenRouterModel]
        let byID: [String: OpenRouterModel]
        let groups: [(provider: String, models: [OpenRouterModel])]
    }

    init(
        session: URLSession = .shared,
        userDefaults: UserDefaults = .standard,
        allowsRemoteRequests: Bool = true
    ) {
        self.session = session
        self.userDefaults = userDefaults
        self.allowsRemoteRequests = allowsRemoteRequests
    }

    static let defaultModels: [OpenRouterModel] = [
        OpenRouterModel(id: AIModelDefaults.defaultModelID, name: AIModelDefaults.defaultModelName, context_length: 1048576),
        OpenRouterModel(id: "anthropic/claude-sonnet-4-20250514", name: "Claude Sonnet 4", context_length: 200000),
        OpenRouterModel(id: "anthropic/claude-haiku-4-5-20251001", name: "Claude Haiku 4.5", context_length: 200000),
        OpenRouterModel(id: "openai/gpt-4o", name: "GPT-4o", context_length: 128000),
        OpenRouterModel(id: "openai/gpt-4o-mini", name: "GPT-4o Mini", context_length: 128000),
        OpenRouterModel(id: "google/gemini-2.5-pro-preview", name: "Gemini 2.5 Pro", context_length: 1048576),
        OpenRouterModel(id: "meta-llama/llama-4-maverick", name: "Llama 4 Maverick", context_length: 131072),
    ]

    /// Models to display — fetched list, or the OpenRouter fallback defaults for the OpenRouter source only.
    var displayModels: [OpenRouterModel] {
        guard models.isEmpty else { return models }
        return source == .openRouter ? Self.defaultModels : []
    }

    /// Grouped by provider for UI sections
    var groupedModels: [(provider: String, models: [OpenRouterModel])] {
        guard models.isEmpty else { return catalogGroups }
        return source == .openRouter ? Self.defaultGroups : []
    }

    /// Points the catalog at another provider or base URL, dropping the previous source's published list.
    func setSource(_ newSource: ModelCatalogSource) {
        guard newSource != source else { return }
        source = newSource
        searchCache = nil
        models = []
        modelsByID = [:]
        catalogGroups = []
        resolvedModelsByID = [:]
        cacheLoad = nil
        latestRefreshID = nil
        error = nil
    }

    private static let defaultGroups = Dictionary(grouping: defaultModels, by: \.providerName)
        .sorted { $0.key < $1.key }.map { (provider: $0.key, models: $0.value) }
    private static let defaultModelsByID = Dictionary(defaultModels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    func groups(matching query: String) -> [(provider: String, models: [OpenRouterModel])] {
        // Read the observable snapshot even on a cache hit so SwiftUI tracks catalog changes.
        let groups = groupedModels
        guard !query.isEmpty else { return groups }
        if let searchCache, searchCache.query == query { return searchCache.groups }
        let filtered = groups.compactMap { group -> (provider: String, models: [OpenRouterModel])? in
            let matches = group.models.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
            }
            return matches.isEmpty ? nil : (group.provider, matches)
        }
        searchCache = (query, filtered)
        return filtered
    }

    func fetchModels(apiKey: String, source requestedSource: ModelCatalogSource? = nil) async {
        if let requestedSource { setSource(requestedSource) }
        guard allowsRemoteRequests, let endpoint = source.endpoint else { return }
        guard !endpoint.requiresAPIKey || !apiKey.isEmpty else { return }

        let activeSource = source
        let refreshKey = RefreshKey(source: activeSource, apiKey: apiKey)
        if let pending = refreshes[refreshKey] {
            latestRefreshID = pending.id
            error = nil
            await pending.task.value
            return
        }
        let refreshID = UUID()
        latestRefreshID = refreshID
        isLoading = true
        error = nil
        let task = Task {
            defer {
                refreshes.removeValue(forKey: refreshKey)
                isLoading = !refreshes.isEmpty
            }
            do {
                let data = try await AIEndpointRequest.data(
                    url: endpoint.modelsURL, endpoint: endpoint, apiKey: apiKey, session: session
                )
                let prepared = try await Task.detached { try Self.prepare(data, source: activeSource) }.value
                guard latestRefreshID == refreshID, source == activeSource else { return }
                error = nil
                publish(prepared)
                storeCache(data: data, prepared: prepared, source: activeSource)
                Log.ai.info(
                    "Fetched \(self.models.count) models from \(activeSource.provider.rawValue, privacy: .public)"
                )
            } catch {
                guard latestRefreshID == refreshID, source == activeSource else { return }
                self.error = error.localizedDescription
                Log.ai.error("Failed to fetch model catalog")
                await loadCached()
            }
        }
        refreshes[refreshKey] = (refreshID, task)
        await task.value
    }

    func loadCached() async {
        guard models.isEmpty else { return }
        if let cacheLoad { await cacheLoad.value; return }
        let activeSource = source
        guard let data = cachedCatalogData(for: activeSource) else { return }
        let task = Task {
            defer { cacheLoad = nil }
            guard let prepared = try? await Task.detached(operation: {
                try Self.prepare(data, source: activeSource)
            }).value,
                  models.isEmpty, source == activeSource else { return }
            publish(prepared)
            Log.ai.info("Loaded \(self.models.count) cached models")
        }
        cacheLoad = task
        await task.value
    }

    private func cachedCatalogData(for source: ModelCatalogSource) -> Data? {
        switch source {
        case .openRouter:
            return userDefaults.data(for: .cachedModelList)
        case .openAICompatible(let baseURL):
            guard let data = userDefaults.data(for: .cachedLocalModelList),
                  let cache = try? JSONDecoder().decode(LocalCatalogCache.self, from: data),
                  cache.endpoint == baseURL.absoluteString else { return nil }
            return data
        case .unconfigured:
            return nil
        }
    }

    private func storeCache(data: Data, prepared: PreparedCatalog, source: ModelCatalogSource) {
        switch source {
        case .openRouter:
            userDefaults.set(data, for: .cachedModelList)
        case .openAICompatible(let baseURL):
            let cache = LocalCatalogCache(endpoint: baseURL.absoluteString, modelIDs: prepared.models.map(\.id))
            guard let encoded = try? JSONEncoder().encode(cache) else { return }
            userDefaults.set(encoded, for: .cachedLocalModelList)
        case .unconfigured:
            return
        }
    }

    private nonisolated static func prepare(_ data: Data, source: ModelCatalogSource) throws -> PreparedCatalog {
        switch source {
        case .openRouter:
            let models = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data).data
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            return PreparedCatalog(
                models: models,
                byID: Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                groups: Dictionary(grouping: models, by: \.providerName).sorted { $0.key < $1.key }
                    .map { (provider: $0.key, models: $0.value) }
            )
        case .openAICompatible:
            let modelIDs: [String]
            if let cache = try? JSONDecoder().decode(LocalCatalogCache.self, from: data) {
                modelIDs = cache.modelIDs
            } else {
                modelIDs = try JSONDecoder().decode(OpenAIModelListResponse.self, from: data).modelIDs
            }
            return prepareLocal(modelIDs)
        case .unconfigured:
            throw AIEndpointRequestError.invalidResponse
        }
    }

    /// A local server lists IDs only: the ID is the display name and modality metadata stays absent.
    private nonisolated static func prepareLocal(_ modelIDs: [String]) -> PreparedCatalog {
        let models = modelIDs
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { OpenRouterModel(id: $0, name: $0, context_length: nil) }
        return PreparedCatalog(
            models: models,
            byID: Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            groups: models.isEmpty ? [] : [(provider: "Local", models: models)]
        )
    }

    private func publish(_ prepared: PreparedCatalog) {
        searchCache = nil
        modelsByID = prepared.byID
        catalogGroups = prepared.groups
        models = prepared.models
    }

    /// Find an exact catalog entry for a model ID without guessing from its name or provider.
    func model(for modelID: String) -> OpenRouterModel? {
        let listedModel = modelsByID[modelID]
        if listedModel?.hasCompleteModalityMetadata == true {
            return listedModel
        }
        return resolvedModelsByID[modelID] ?? listedModel
    }

    /// Resolve full metadata for one exact model ID when the catalog has no complete modality data.
    /// Only OpenRouter exposes per-model metadata; a local endpoint keeps its listed entry.
    func resolveModel(for modelID: String, apiKey: String) async -> OpenRouterModel? {
        guard allowsRemoteRequests, source == .openRouter else { return model(for: modelID) }
        let key = ResolutionKey(modelID: modelID, apiKey: apiKey)
        if let pending = resolutions[key] {
            modelResolutionIDs[modelID] = pending.id
            return await pending.task.value
        }
        let existingModel = model(for: modelID)
        if existingModel?.hasCompleteModalityMetadata == true {
            return existingModel
        }

        guard !apiKey.isEmpty, let url = singleModelURL(for: modelID) else {
            return existingModel
        }

        let resolutionID = UUID()
        modelResolutionIDs[modelID] = resolutionID
        let task = Task<OpenRouterModel?, Never> {
            defer {
                resolutions.removeValue(forKey: key)
                if modelResolutionIDs[modelID] == resolutionID {
                    modelResolutionIDs.removeValue(forKey: modelID)
                }
            }
            do {
                let data = try await AIEndpointRequest.data(
                    url: url, endpoint: .openRouter, apiKey: apiKey, session: session
                )
                let resolvedModel = try await Task.detached {
                    try JSONDecoder().decode(OpenRouterModelResponse.self, from: data).data
                }.value
                guard resolvedModel.id == modelID else { throw URLError(.cannotParseResponse) }
                if modelResolutionIDs[modelID] == resolutionID {
                    resolvedModelsByID[modelID] = resolvedModel
                }
                // Every waiter receives its request's result, even if a newer context superseded publication.
                return resolvedModel
            } catch {
                Log.ai.error("Failed to resolve OpenRouter model metadata for \(modelID, privacy: .public)")
                return model(for: modelID)
            }
        }
        resolutions[key] = (resolutionID, task)
        return await task.value
    }

    /// Find display name for a model ID
    func displayName(for modelId: String) -> String {
        guard models.isEmpty else { return modelsByID[modelId]?.displayName ?? modelId }
        guard source == .openRouter else { return modelId }
        return Self.defaultModelsByID[modelId]?.displayName ?? modelId
    }

    private func singleModelURL(for modelID: String) -> URL? {
        guard let separator = modelID.firstIndex(of: "/"),
              separator != modelID.startIndex,
              modelID.index(after: separator) != modelID.endIndex else {
            return nil
        }

        let author = String(modelID[..<separator])
        let slug = String(modelID[modelID.index(after: separator)...])
        return URL(string: "https://openrouter.ai/api/v1/model")?
            .appendingPathComponent(author)
            .appendingPathComponent(slug)
    }
}
