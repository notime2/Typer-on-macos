// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Darwin
import Foundation

/// Which backend the app talks to. OpenRouter stays the default for every existing install.
enum AIProvider: String, Codable, CaseIterable, Sendable {
    case openRouter
    case openAICompatible
    case codex
    case claudeCode

    var isSubscription: Bool { self == .codex || self == .claudeCode }

    static let fallback: AIProvider = .openRouter

    /// Unknown or missing stored values resolve to the OpenRouter default.
    static func resolve(rawValue: String?) -> AIProvider {
        guard let rawValue, let provider = AIProvider(rawValue: rawValue) else { return .fallback }
        return provider
    }

    var displayName: String {
        switch self {
        case .openRouter:
            return "OpenRouter"
        case .openAICompatible:
            return "OpenAI-compatible (local)"
        case .codex:
            return "Codex (ChatGPT)"
        case .claudeCode:
            return "Claude Code"
        }
    }
}

enum AIEndpointError: LocalizedError, Equatable, Sendable {
    case emptyBaseURL
    case malformedBaseURL
    case unsupportedScheme(String)
    case missingHost
    case insecureRemoteHost(String)

    var errorDescription: String? {
        switch self {
        case .emptyBaseURL:
            return "Enter a base URL, for example \(AIEndpointURL.ollamaExample)"
        case .malformedBaseURL:
            return "This is not a valid URL. Include the scheme, for example \(AIEndpointURL.ollamaExample)"
        case .unsupportedScheme(let scheme):
            return "Unsupported scheme \"\(scheme)\". Use http for a local endpoint or https."
        case .missingHost:
            return "The base URL needs a host, for example \(AIEndpointURL.ollamaExample)"
        case .insecureRemoteHost(let host):
            return "Plain http is allowed only for local and private-network addresses. Use https for \(host)."
        }
    }
}

/// Base-URL normalization and transport-security rules for user-configured endpoints.
enum AIEndpointURL {
    static let ollamaExample = "http://localhost:11434/v1"
    static let lmStudioExample = "http://localhost:1234/v1"

    /// Trims trailing slashes and a pasted `/chat/completions` or `/models` suffix so joins never duplicate segments.
    static func normalize(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIEndpointError.emptyBaseURL }
        guard var components = URLComponents(string: trimmed) else { throw AIEndpointError.malformedBaseURL }
        guard let scheme = components.scheme?.lowercased(), !scheme.isEmpty else {
            throw AIEndpointError.malformedBaseURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw AIEndpointError.unsupportedScheme(scheme)
        }
        guard let host = components.host, !host.isEmpty else { throw AIEndpointError.missingHost }
        if scheme == "http", !isPrivateNetworkHost(host) {
            throw AIEndpointError.insecureRemoteHost(canonicalHost(host))
        }

        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        components.path = normalizedPath(components.path)

        guard let url = components.url else { throw AIEndpointError.malformedBaseURL }
        return url
    }

    /// `http` is accepted only for loopback and private-network addresses; `https` is always accepted.
    static func isPrivateNetworkHost(_ rawHost: String) -> Bool {
        let host = canonicalHost(rawHost)
        guard !host.isEmpty else { return false }
        if host == "localhost" { return true }
        if host.hasSuffix(".local") { return true }
        if let address = ipv4Address(host) { return isPrivateIPv4(address) }
        if let bytes = ipv6Bytes(host) { return isLoopbackIPv6(bytes) }
        return false
    }

    private static func canonicalHost(_ rawHost: String) -> String {
        var host = rawHost.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if let zone = host.firstIndex(of: "%") {
            host = String(host[..<zone])
        }
        return host
    }

    private static func normalizedPath(_ path: String) -> String {
        var segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if segments.count >= 2, Array(segments.suffix(2)) == ["chat", "completions"] {
            segments.removeLast(2)
        }
        if segments.last == "models" {
            segments.removeLast()
        }
        guard !segments.isEmpty else { return "" }
        return "/" + segments.joined(separator: "/")
    }

    private static func ipv4Address(_ host: String) -> UInt32? {
        var address = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func isPrivateIPv4(_ address: UInt32) -> Bool {
        let first = UInt8((address >> 24) & 0xFF)
        let second = UInt8((address >> 16) & 0xFF)
        switch first {
        case 127, 10:
            return true
        case 172:
            return (16...31).contains(second)
        case 192:
            return second == 168
        default:
            return false
        }
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func isLoopbackIPv6(_ bytes: [UInt8]) -> Bool {
        bytes.count == 16 && bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }
}

/// One resolved transport: request URLs plus the header and credential rules for that provider.
struct AIEndpointConfiguration: Sendable, Equatable, Hashable {
    let provider: AIProvider
    let baseURL: URL
    let chatCompletionsURL: URL
    let modelsURL: URL
    let imagesURL: URL?

    var sendsOpenRouterHeaders: Bool { provider == .openRouter }
    var requiresAPIKey: Bool { provider == .openRouter }

    /// OpenRouter app attribution. `HTTP-Referer` creates the public app page and ranking entry,
    /// `X-Title` names it. Both are fixed for every install; local endpoints get neither.
    func addAttributionHeaders(to request: inout URLRequest) {
        guard sendsOpenRouterHeaders else { return }
        request.addValue("https://github.com/notime2/Typer-on-macos", forHTTPHeaderField: "HTTP-Referer")
        request.addValue("Typer On", forHTTPHeaderField: "X-Title")
    }

    /// Host and port as shown in settings, the status bar, and module inheritance hints.
    var displayHost: String {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host else {
            return baseURL.absoluteString
        }
        guard let port = components.port else { return host }
        return "\(host):\(port)"
    }

    static let openRouter = AIEndpointConfiguration(
        provider: .openRouter,
        baseURL: URL(string: "https://openrouter.ai/api/v1")!,
        chatCompletionsURL: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        modelsURL: URL(string: "https://openrouter.ai/api/v1/models")!,
        imagesURL: URL(string: "https://openrouter.ai/api/v1/images")!
    )

    static func openAICompatible(baseURL: URL) -> AIEndpointConfiguration {
        AIEndpointConfiguration(
            provider: .openAICompatible,
            baseURL: baseURL,
            chatCompletionsURL: baseURL.appendingPathComponent("chat").appendingPathComponent("completions"),
            modelsURL: baseURL.appendingPathComponent("models"),
            imagesURL: nil
        )
    }
}

/// The catalog list a picker shows. Cached lists are separated by provider and base URL.
enum ModelCatalogSource: Equatable, Hashable, Sendable {
    case openRouter
    case openAICompatible(baseURL: URL)
    case subscription(provider: AIProvider, executablePath: String?)
    /// The local provider is selected but its base URL is missing or invalid.
    case unconfigured

    var provider: AIProvider {
        switch self {
        case .openRouter:
            return .openRouter
        case .openAICompatible, .unconfigured:
            return .openAICompatible
        case .subscription(let provider, _):
            return provider
        }
    }

    var endpoint: AIEndpointConfiguration? {
        switch self {
        case .openRouter:
            return .openRouter
        case .openAICompatible(let baseURL):
            return .openAICompatible(baseURL: baseURL)
        case .unconfigured, .subscription:
            return nil
        }
    }
}

/// The persisted provider selection resolved into a usable transport.
struct AIProviderSettings: Equatable, Sendable {
    let provider: AIProvider
    let localBaseURLText: String
    let localBaseURL: URL?
    var subscriptionExecutablePath: String? = nil

    static func resolve(provider rawProvider: String?, localBaseURL rawBaseURL: String?, subscriptionExecutablePath: String? = nil) -> AIProviderSettings {
        let provider = AIProvider.resolve(rawValue: rawProvider)
        let text = rawBaseURL ?? ""
        return AIProviderSettings(
            provider: provider,
            localBaseURLText: text,
            localBaseURL: try? AIEndpointURL.normalize(text),
            subscriptionExecutablePath: subscriptionExecutablePath
        )
    }

    /// `nil` means the local provider is selected without a usable base URL, so no request may be built.
    var endpoint: AIEndpointConfiguration? {
        switch provider {
        case .openRouter:
            return .openRouter
        case .openAICompatible:
            return localBaseURL.map { AIEndpointConfiguration.openAICompatible(baseURL: $0) }
        case .codex, .claudeCode:
            return nil
        }
    }

    var catalogSource: ModelCatalogSource {
        switch provider {
        case .openRouter:
            return .openRouter
        case .openAICompatible:
            guard let localBaseURL else { return .unconfigured }
            return .openAICompatible(baseURL: localBaseURL)
        case .codex, .claudeCode:
            return .subscription(provider: provider, executablePath: subscriptionExecutablePath)
        }
    }
}

/// Whether the onboarding API row and the status bar can treat credentials as configured.
enum AIProviderReadiness {
    static func isConfigured(provider: AIProvider, hasOpenRouterKey: Bool, localBaseURL: URL?, subscriptionIsReady: Bool = false) -> Bool {
        switch provider {
        case .openRouter:
            return hasOpenRouterKey
        case .openAICompatible:
            return localBaseURL != nil
        case .codex, .claudeCode:
            return subscriptionIsReady
        }
    }
}

/// Provider-aware labels for the module settings inheritance rows.
enum ModuleProviderHint {
    static func credentialLabel(provider: AIProvider, host: String?) -> String {
        switch provider {
        case .openRouter:
            return "Using global OpenRouter key"
        case .openAICompatible:
            guard let host, !host.isEmpty else { return "Using local endpoint (not configured)" }
            return "Using local endpoint (\(host))"
        case .codex, .claudeCode:
            return "Using the signed-in \(provider.displayName) account"
        }
    }

    static func modelLabel(provider: AIProvider, host: String?) -> String {
        switch provider {
        case .openRouter:
            return "Using global model (OpenRouter)"
        case .openAICompatible:
            guard let host, !host.isEmpty else { return "Using global model (local endpoint)" }
            return "Using global model (\(host))"
        case .codex, .claudeCode:
            return "Using global model (\(provider.displayName))"
        }
    }
}
