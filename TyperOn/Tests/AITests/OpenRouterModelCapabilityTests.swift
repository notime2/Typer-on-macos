// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@Test
func testOpenRouterModelDecodesExplicitImageModalities() throws {
    let data = Data(
        #"{"id":"vendor/vision","name":"Vision","context_length":32000,"architecture":{"input_modalities":["text","ImAgE"],"output_modalities":["text","IMAGE"]}}"#.utf8
    )

    let model = try JSONDecoder().decode(OpenRouterModel.self, from: data)

    #expect(model.architecture?.input_modalities == ["text", "ImAgE"])
    #expect(model.architecture?.output_modalities == ["text", "IMAGE"])
    #expect(model.supportsImageInput)
    #expect(model.supportsImageOutput)
}

@Test
func testOpenRouterModelRequiresExactImageModality() throws {
    let data = Data(
        #"{"id":"vendor/vision-image-name","name":"Vision Image Model","context_length":32000,"architecture":{"input_modalities":["text","image_url"," image "],"output_modalities":["text","images"]}}"#.utf8
    )

    let model = try JSONDecoder().decode(OpenRouterModel.self, from: data)

    #expect(!model.supportsImageInput)
    #expect(!model.supportsImageOutput)
}

@Test
func testLegacyOpenRouterModelWithoutArchitectureStillDecodesAsUnsupported() throws {
    let data = Data(
        #"{"data":[{"id":"vendor/legacy-vision","name":"Legacy Vision","context_length":16000}]}"#.utf8
    )

    let response = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
    let model = try #require(response.data.first)

    #expect(model.architecture == nil)
    #expect(!model.supportsImageInput)
    #expect(!model.supportsImageOutput)
    #expect(!model.hasCompleteModalityMetadata)
}

@Test
@MainActor
func testModelCatalogLoadsCachedArchitectureAndUsesExactLookup() async throws {
    let suiteName = "OpenRouterModelCapabilityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(
        Data(
            #"{"data":[{"id":"vendor/cached","name":"Cached","context_length":8000,"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}}]}"#.utf8
        ),
        for: .cachedModelList
    )

    let catalog = ModelCatalogService(userDefaults: defaults)
    await catalog.loadCached()

    #expect(catalog.model(for: "vendor/cached")?.supportsImageInput == true)
    #expect(catalog.model(for: "Vendor/Cached") == nil)
}

@Test
@MainActor
func testModelCatalogResolvesMissingMetadataWithResolvedAPIKey() async throws {
    let suiteName = "OpenRouterModelCapabilityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(
        Data(#"{"data":[{"id":"vendor/vision","name":"Old Cache","context_length":8000}]}"#.utf8),
        for: .cachedModelList
    )

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ExactModelURLProtocol.self]
    let catalog = ModelCatalogService(
        session: URLSession(configuration: configuration),
        userDefaults: defaults
    )
    await catalog.loadCached()

    let model = await catalog.resolveModel(for: "vendor/vision", apiKey: "resolved-module-key")

    #expect(model?.supportsImageInput == true)
    #expect(model?.supportsImageOutput == true)
    #expect(catalog.model(for: "vendor/vision")?.supportsImageInput == true)
    #expect(catalog.models.first?.name == "Old Cache")
}

@Test
@MainActor
func testModelCatalogResolvesModelAbsentFromListWithoutChangingPickerModels() async throws {
    let suiteName = "OpenRouterModelCapabilityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ExactModelURLProtocol.self]
    let catalog = ModelCatalogService(
        session: URLSession(configuration: configuration),
        userDefaults: defaults
    )

    let model = await catalog.resolveModel(for: "vendor/vision", apiKey: "resolved-module-key")

    #expect(model?.supportsImageInput == true)
    #expect(catalog.model(for: "vendor/vision")?.supportsImageOutput == true)
    #expect(catalog.models.isEmpty)
}

@Test
@MainActor
func testModelCatalogRejectsMismatchedExactModelResponse() async throws {
    let suiteName = "OpenRouterModelCapabilityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MismatchedModelURLProtocol.self]
    let catalog = ModelCatalogService(
        session: URLSession(configuration: configuration),
        userDefaults: defaults
    )

    let model = await catalog.resolveModel(for: "vendor/requested", apiKey: "key")

    #expect(model == nil)
    #expect(catalog.model(for: "vendor/requested") == nil)
}

private final class ExactModelURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let isExpectedRequest = request.httpMethod == "GET"
            && request.url?.path == "/api/v1/model/vendor/vision"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer resolved-module-key"

        let statusCode = isExpectedRequest ? 200 : 400
        let body: Data
        if isExpectedRequest {
            body = Data(
                #"{"data":{"id":"vendor/vision","name":"Resolved Vision","context_length":32000,"architecture":{"input_modalities":["text","image"],"output_modalities":["text","image"]}}}"#.utf8
            )
        } else {
            body = Data(#"{"error":"unexpected request"}"#.utf8)
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MismatchedModelURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let body = Data(
            #"{"data":{"id":"vendor/different","name":"Wrong Model","context_length":32000,"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}}}"#.utf8
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
