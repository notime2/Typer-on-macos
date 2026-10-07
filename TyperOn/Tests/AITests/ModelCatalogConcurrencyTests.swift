// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@Suite(.serialized)
@MainActor
struct ModelCatalogConcurrencyTests {
    @Test
    func cachedCatalogSearchMatchesNamesAndIDsWithoutChangingSavedState() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(Data(#"{"data":[{"id":"vendor-a/vision-pro","name":"Picture Expert"},{"id":"vendor-b/text-fast","name":"Quick Writer"}]}"#.utf8), for: .cachedModelList)
        fixture.defaults.set("vendor-b/text-fast", for: .selectedModel)
        let saved = try #require(fixture.defaults.persistentDomain(forName: fixture.suiteName)) as NSDictionary

        await fixture.catalog.loadCached()
        #expect(fixture.catalog.groups(matching: "pIcTuRe").flatMap(\.models).map(\.id) == ["vendor-a/vision-pro"])
        #expect(fixture.catalog.groups(matching: "VISION-PRO").flatMap(\.models).map(\.id) == ["vendor-a/vision-pro"])
        #expect(fixture.catalog.groups(matching: "VENDOR-B/").flatMap(\.models).map(\.id) == ["vendor-b/text-fast"])
        #expect(fixture.catalog.groups(matching: "does-not-exist").isEmpty)
        #expect(fixture.catalog.groups(matching: "").flatMap(\.models).map(\.id) == ["vendor-a/vision-pro", "vendor-b/text-fast"])
        #expect(fixture.catalog.groups(matching: "does-not-exist").isEmpty)
        #expect(CatalogGateProtocol.gate.count == 0)
        let current = try #require(fixture.defaults.persistentDomain(forName: fixture.suiteName))
        #expect(saved.isEqual(to: current))
    }

    @Test
    func identicalRefreshesShareRequestAndPublishIndexes() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        async let first: Void = fixture.catalog.fetchModels(apiKey: "test-key")
        async let second: Void = fixture.catalog.fetchModels(apiKey: "test-key")
        await CatalogGateProtocol.gate.waitForRequests(1)
        #expect(fixture.catalog.isLoading)
        CatalogGateProtocol.gate.complete(index: 0, json: #"{"data":[{"id":"z/b","name":"Beta"},{"id":"a/a","name":"Alpha"}]}"#)
        _ = await (first, second)
        #expect(CatalogGateProtocol.gate.count == 1)
        #expect(!fixture.catalog.isLoading)
        #expect(fixture.catalog.displayName(for: "a/a") == "Alpha")
        #expect(fixture.catalog.model(for: "A/A") == nil)
        #expect(fixture.catalog.groupedModels.map(\.provider) == ["A", "Z"])
        #expect(fixture.catalog.groups(matching: "alpha").flatMap(\.models).map(\.id) == ["a/a"])
        #expect(fixture.catalog.groups(matching: "z/").flatMap(\.models).map(\.id) == ["z/b"])
        #expect(fixture.catalog.groups(matching: "missing").isEmpty)
    }

    @Test
    func differentCredentialsCannotPublishAnOlderRefresh() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let old = Task { await fixture.catalog.fetchModels(apiKey: "old-key") }
        await CatalogGateProtocol.gate.waitForRequests(1)
        let new = Task { await fixture.catalog.fetchModels(apiKey: "new-key") }
        await CatalogGateProtocol.gate.waitForRequests(2)
        #expect(CatalogGateProtocol.gate.authorization(at: 0) == "Bearer old-key")
        #expect(CatalogGateProtocol.gate.authorization(at: 1) == "Bearer new-key")
        CatalogGateProtocol.gate.complete(index: 1, json: #"{"data":[{"id":"vendor/new","name":"New"}]}"#)
        await new.value
        #expect(fixture.catalog.isLoading)
        #expect(fixture.catalog.groups(matching: "New").count == 1)
        CatalogGateProtocol.gate.complete(index: 0, json: #"{"data":[{"id":"vendor/old","name":"Old"}]}"#)
        await old.value
        #expect(fixture.catalog.models.map(\.id) == ["vendor/new"])
        #expect(fixture.catalog.model(for: "vendor/old") == nil)
        #expect(!fixture.catalog.isLoading)

        let refresh = Task { await fixture.catalog.fetchModels(apiKey: "new-key") }
        await CatalogGateProtocol.gate.waitForRequests(3)
        CatalogGateProtocol.gate.complete(index: 2, json: #"{"data":[{"id":"vendor/next","name":"Next"}]}"#)
        await refresh.value
        #expect(fixture.catalog.groups(matching: "New").isEmpty)
        #expect(fixture.catalog.displayName(for: "vendor/new") == "vendor/new")
    }

    @Test
    func exactMetadataSharesWaitersAndFailureAllowsRetry() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        async let first = fixture.catalog.resolveModel(for: "vendor/vision", apiKey: "key")
        async let second = fixture.catalog.resolveModel(for: "vendor/vision", apiKey: "key")
        await CatalogGateProtocol.gate.waitForRequests(1)
        CatalogGateProtocol.gate.complete(index: 0, json: "{}", status: 500)
        let failures = await (first, second)
        #expect(failures.0 == nil && failures.1 == nil)
        #expect(CatalogGateProtocol.gate.count == 1)
        let retry = Task { await fixture.catalog.resolveModel(for: "vendor/vision", apiKey: "key") }
        await CatalogGateProtocol.gate.waitForRequests(2)
        CatalogGateProtocol.gate.complete(index: 1, json: #"{"data":{"id":"vendor/vision","name":"Vision","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}}}"#)
        #expect(await retry.value?.supportsImageInput == true)
        #expect(fixture.catalog.models.isEmpty)
    }

    @Test
    func failedRefreshRetainsOfflineCache() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(Data(#"{"data":[{"id":"vendor/offline","name":"Offline"}]}"#.utf8), for: .cachedModelList)
        let savedCache = fixture.defaults.data(for: .cachedModelList)
        await fixture.catalog.loadCached()
        #expect(fixture.catalog.groups(matching: "OFFLINE").flatMap(\.models).map(\.id) == ["vendor/offline"])
        let refresh = Task { await fixture.catalog.fetchModels(apiKey: "key") }
        await CatalogGateProtocol.gate.waitForRequests(1)
        CatalogGateProtocol.gate.complete(index: 0, json: "{}", status: 500)
        await refresh.value
        #expect(fixture.catalog.model(for: "vendor/offline") != nil)
        #expect(fixture.catalog.groups(matching: "OFFLINE").flatMap(\.models).map(\.id) == ["vendor/offline"])
        #expect(fixture.defaults.data(for: .cachedModelList) == savedCache)
        #expect(fixture.catalog.error != nil)
        #expect(!fixture.catalog.isLoading)
    }

    @Test
    func metadataSeparatesCredentialsAndCancelledWaiterDoesNotCancelSharedWork() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let older = Task { await fixture.catalog.resolveModel(for: "vendor/model", apiKey: "old") }
        await CatalogGateProtocol.gate.waitForRequests(1)
        let newer = Task { await fixture.catalog.resolveModel(for: "vendor/model", apiKey: "new") }
        await CatalogGateProtocol.gate.waitForRequests(2)
        older.cancel()
        CatalogGateProtocol.gate.complete(index: 1, json: #"{"data":{"id":"vendor/model","name":"New","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}}}"#)
        #expect(await newer.value?.name == "New")
        CatalogGateProtocol.gate.complete(index: 0, json: #"{"data":{"id":"vendor/model","name":"Old","architecture":{"input_modalities":["text"],"output_modalities":["text"]}}}"#)
        #expect(await older.value?.name == "Old")
        #expect(fixture.catalog.model(for: "vendor/model")?.name == "New")
        #expect(CatalogGateProtocol.gate.count == 2)
    }

    @Test
    func returningToEarlierCredentialContextPromotesItsSharedRefresh() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let first = Task { await fixture.catalog.fetchModels(apiKey: "A") }
        await CatalogGateProtocol.gate.waitForRequests(1)
        let second = Task { await fixture.catalog.fetchModels(apiKey: "B") }
        await CatalogGateProtocol.gate.waitForRequests(2)
        let joined = Task { await fixture.catalog.fetchModels(apiKey: "A") }
        await Task.yield()
        CatalogGateProtocol.gate.complete(index: 1, json: #"{"data":[{"id":"vendor/b","name":"B"}]}"#)
        await second.value
        #expect(fixture.catalog.models.isEmpty)
        CatalogGateProtocol.gate.complete(index: 0, json: #"{"data":[{"id":"vendor/a","name":"A"}]}"#)
        await first.value
        await joined.value
        #expect(fixture.catalog.models.map(\.id) == ["vendor/a"])
        #expect(CatalogGateProtocol.gate.count == 2)
    }

    @Test
    func returningToEarlierCredentialContextPromotesItsSharedMetadata() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.cleanUp() }
        let first = Task { await fixture.catalog.resolveModel(for: "vendor/model", apiKey: "A") }
        await CatalogGateProtocol.gate.waitForRequests(1)
        let second = Task { await fixture.catalog.resolveModel(for: "vendor/model", apiKey: "B") }
        await CatalogGateProtocol.gate.waitForRequests(2)
        let joined = Task { await fixture.catalog.resolveModel(for: "vendor/model", apiKey: "A") }
        await Task.yield()
        CatalogGateProtocol.gate.complete(index: 1, json: #"{"data":{"id":"vendor/model","name":"B"}}"#)
        _ = await second.value
        #expect(fixture.catalog.model(for: "vendor/model") == nil)
        CatalogGateProtocol.gate.complete(index: 0, json: #"{"data":{"id":"vendor/model","name":"A"}}"#)
        _ = await first.value
        #expect(await joined.value?.name == "A")
        #expect(fixture.catalog.model(for: "vendor/model")?.name == "A")
        #expect(CatalogGateProtocol.gate.count == 2)
    }
}

@MainActor
private struct CatalogFixture {
    let suiteName = "CatalogConcurrency.\(UUID().uuidString)"
    let defaults: UserDefaults
    let catalog: ModelCatalogService

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        CatalogGateProtocol.gate = CatalogRequestGate()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogGateProtocol.self]
        catalog = ModelCatalogService(session: URLSession(configuration: config), userDefaults: defaults)
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suiteName) }
}

private final class CatalogRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CatalogGateProtocol] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var count: Int { lock.withLock { requests.count } }

    func authorization(at index: Int) -> String? {
        lock.withLock { requests[index].request.value(forHTTPHeaderField: "Authorization") }
    }

    func add(_ request: CatalogGateProtocol) {
        let ready = lock.withLock {
            requests.append(request)
            let ready = waiters.filter { requests.count >= $0.0 }
            waiters.removeAll { requests.count >= $0.0 }
            return ready
        }
        ready.forEach { $0.1.resume() }
    }

    func waitForRequests(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if requests.count >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func complete(index: Int, json: String, status: Int = 200) {
        let request = lock.withLock { requests[index] }
        let response = HTTPURLResponse(url: request.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: Data(json.utf8))
        request.client?.urlProtocolDidFinishLoading(request)
    }
}

private final class CatalogGateProtocol: URLProtocol, @unchecked Sendable {
    // This protocol is private to the serialized suite; assignment precedes all requests.
    nonisolated(unsafe) static var gate = CatalogRequestGate()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.gate.add(self) }
    override func stopLoading() {}
}
