// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Darwin

struct SubscriptionConnectionResult: Sendable {
    let isReady: Bool
    let message: String
    let executablePath: String?
    let models: [OpenRouterModel]
    let accountLabel: String?
    let accountDetail: String?

    init(isReady: Bool, message: String, executablePath: String?, models: [OpenRouterModel],
         accountLabel: String? = nil, accountDetail: String? = nil) {
        self.isReady = isReady
        self.message = message
        self.executablePath = executablePath
        self.models = models
        self.accountLabel = accountLabel
        self.accountDetail = accountDetail
    }
}

struct SubscriptionAccount: Sendable {
    let label: String
    let detail: String
}

enum SubscriptionCLIError: LocalizedError, Sendable {
    case missingExecutable(String)
    case launchFailed, timedOut, closed, malformed, failed, emptyResponse, toolsRejected
    case signedOut(String), apiKeyAccount(String), imageInputUnsupported

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let name): "Cannot run \(name). Choose the installed CLI executable in API \\ Models."
        case .launchFailed: "The AI CLI could not start. Check its executable in API \\ Models."
        case .timedOut: "The AI CLI timed out. Check the connection and try again."
        case .closed: "The AI CLI stopped before completing its response."
        case .malformed: "The AI CLI returned an unexpected response. Update the CLI and try again."
        case .failed: "The AI CLI could not complete this request. Check sign-in, model access and subscription usage limits."
        case .emptyResponse: "The AI CLI completed without a text response."
        case .toolsRejected: "The AI CLI requested a tool. Typer On allows text and image input only."
        case .signedOut(let name): "Sign in to \(name) with your subscription in API \\ Models."
        case .apiKeyAccount(let name): "\(name) is using API credentials. Sign in with your subscription in API \\ Models."
        case .imageInputUnsupported: "This CLI model has no confirmed image-input support. Choose a supported model in API \\ Models."
        }
    }
}

enum SubscriptionCLI {
    static func resolveExecutable(provider: AIProvider, configuredPath: String?) throws -> URL {
        let name = provider == .codex ? "codex" : "claude"
        if let chosen = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines), !chosen.isEmpty {
            let path = (chosen as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), isExecutable(path) else {
                throw SubscriptionCLIError.missingExecutable(name)
            }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        for directory in directories where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if isExecutable(candidate.path) { return candidate }
        }
        throw SubscriptionCLIError.missingExecutable(name)
    }

    static func checkConnection(provider: AIProvider, executablePath: String?) async -> SubscriptionConnectionResult {
        let task = Task.detached(priority: .utility) {
            var path: String?
            do {
                let executable = try resolveExecutable(provider: provider, configuredPath: executablePath)
                path = executable.path
                let models: [OpenRouterModel]
                let account: SubscriptionAccount
                if provider == .codex {
                    let session = try await SubscriptionCodexSession.start(executable: executable)
                    defer { session.child.close() }
                    account = try await session.requireSubscription()
                    models = try await session.models()
                } else {
                    account = try await requireClaudeSubscription(executable: executable)
                    models = try await claudeModels(executable: executable)
                }
                return SubscriptionConnectionResult(isReady: true,
                    message: "Signed in with \(provider == .codex ? "ChatGPT" : "Claude") subscription.",
                    executablePath: path, models: models, accountLabel: account.label, accountDetail: account.detail)
            } catch {
                return SubscriptionConnectionResult(isReady: false, message: error.localizedDescription,
                    executablePath: path, models: [])
            }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    static func environment(executable: URL, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        // Keep the CLI's existing OAuth storage. Never let inherited API/router credentials select a paid API.
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL", "ANTHROPIC_API_KEY",
                    "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_USE_BEDROCK",
                    "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_SUBAGENT_MODEL",
                    "NODE_OPTIONS", "BASH_ENV", "ENV"] {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = ([executable.deletingLastPathComponent().path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        environment.removeValue(forKey: "FORCE_COLOR")
        environment["NO_COLOR"] = "1"
        return environment
    }

    static let claudeArguments = ["--safe-mode", "--restricted", "--print", "--input-format", "stream-json",
        "--output-format", "stream-json", "--include-partial-messages", "--verbose", "--tools", "",
        "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--no-session-persistence",
        "--disable-slash-commands", "--no-chrome", "--permission-prompts", "none"]

    @discardableResult
    static func requireClaudeSubscription(executable: URL) async throws -> SubscriptionAccount {
        let child = try SubscriptionProcess(executable: executable,
            arguments: ["--safe-mode", "--restricted", "auth", "status", "--json"], timeout: 15)
        defer { child.close() }
        return try await withTaskCancellationHandler {
            child.closeInput()
            var data = Data()
            do {
                for try await line in child.lines { data.append(line); data.append(0x0A) }
            } catch SubscriptionCLIError.failed {
                // auth status reports loggedIn:false as JSON and exits 1. Parse that actionable state.
            }
            try Task.checkCancellation()
            guard let status = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SubscriptionCLIError.malformed
            }
            guard status["loggedIn"] as? Bool == true else { throw SubscriptionCLIError.signedOut("Claude Code") }
            guard status["authMethod"] as? String == "claude.ai",
                  status["apiProvider"] as? String == "firstParty",
                  let plan = status["subscriptionType"] as? String, !plan.isEmpty, plan.lowercased() != "free" else {
                throw SubscriptionCLIError.apiKeyAccount("Claude Code")
            }
            try await requireClaudeLoginNotExpired(executable: executable)
            let email = (status["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SubscriptionAccount(label: email.flatMap { $0.isEmpty ? nil : $0 } ?? "Claude",
                                       detail: "Claude \(plan.capitalized)")
        } onCancel: { child.close(throwing: CancellationError()) }
    }

    private static func requireClaudeLoginNotExpired(executable: URL) async throws {
        // JSON status reports cached credential presence. The official text status also checks
        // for a stored login that cannot be refreshed, distinct from normal access-token renewal.
        let child = try SubscriptionProcess(executable: executable,
            arguments: ["--safe-mode", "--restricted", "auth", "status", "--text"], timeout: 15)
        defer { child.close() }
        try await withTaskCancellationHandler {
            child.closeInput()
            for try await line in child.lines {
                let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasPrefix("Login: Expired") {
                    throw SubscriptionCLIError.signedOut("Claude Code")
                }
            }
        } onCancel: { child.close(throwing: CancellationError()) }
    }

    static func claudeModels(executable: URL) async throws -> [OpenRouterModel] {
        let child = try SubscriptionProcess(executable: executable, arguments: claudeArguments, timeout: 15)
        defer { child.close() }
        return try await withTaskCancellationHandler {
            // Official SDK initialization returns aliases AND resolved snapshot IDs, without running a turn.
            try await child.write(["type": "control_request", "request_id": "typer-models",
                "request": ["subtype": "initialize", "sdkMcpServers": []]])
            for try await line in child.lines {
                let object = try decode(line)
                guard object["type"] as? String == "control_response",
                      let envelope = object["response"] as? [String: Any],
                      envelope["request_id"] as? String == "typer-models" else { continue }
                guard envelope["subtype"] as? String == "success",
                      let response = envelope["response"] as? [String: Any],
                      let models = response["models"] as? [[String: Any]] else { throw SubscriptionCLIError.malformed }
                return models.compactMap { entry in
                    guard let id = entry["value"] as? String, !id.isEmpty else { return nil }
                    let efforts = entry["supportsEffort"] as? Bool == true
                        ? (entry["supportedEffortLevels"] as? [String])?.filter { !$0.isEmpty }.map {
                            ReasoningEffortOption(id: $0, detail: "")
                        } : nil
                    return OpenRouterModel(id: id, name: entry["displayName"] as? String ?? id,
                        context_length: nil, architecture: claudeArchitecture(resolvedModel: entry["resolvedModel"] as? String),
                        reasoningEfforts: efforts)
                }
            }
            throw SubscriptionCLIError.closed
        } onCancel: { child.close(throwing: CancellationError()) }
    }

    static func claudeArchitecture(resolvedModel: String?) -> OpenRouterModel.Architecture? {
        // Explicit snapshot metadata: https://platform.claude.com/docs/en/models/overview (2026-10-07).
        // Unknown snapshots and user-entered aliases remain unknown rather than guessing by model name.
        let documented = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1",
                          "claude-haiku-4-5-20251001"]
        guard let resolvedModel, documented.contains(resolvedModel) else { return nil }
        return .init(input_modalities: ["text", "image"], output_modalities: ["text"])
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SubscriptionCLIError.malformed
        }
        return object
    }

    private static func isExecutable(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}

/// Shared stdio lifecycle. Blocking reads/writes live on utility queues, never the UI actor.
final class SubscriptionProcess: @unchecked Sendable {
    let lines: AsyncThrowingStream<Data, Error>
    let directory: URL
    private let process: Process
    private let input: FileHandle
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private let writes = DispatchQueue(label: "TyperOn.SubscriptionCLI.stdin", qos: .utility)
    private var closed = false
    private var timeoutTask: Task<Void, Never>?

    init(executable: URL, arguments: [String], timeout: TimeInterval) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TyperOn-AI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        input = stdin.fileHandleForWriting
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        lines = pair.stream
        continuation = pair.continuation
        process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = SubscriptionCLI.environment(executable: executable)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let directory = self.directory
        process.terminationHandler = { _ in try? FileManager.default.removeItem(at: directory) }
        do { try process.run() } catch {
            try? FileManager.default.removeItem(at: directory)
            throw SubscriptionCLIError.launchFailed
        }
        readOutput(stdout.fileHandleForReading)
        DispatchQueue.global(qos: .utility).async {
            // Drain stderr to avoid pipe backpressure; retain no user content or credentials.
            while !stderr.fileHandleForReading.availableData.isEmpty {}
            try? stderr.fileHandleForReading.close()
        }
        resetTimeout(timeout)
    }

    func write(_ object: [String: Any]) async throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        let payload = data
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            writes.async { [self] in
                do {
                    guard !lock.withLock({ closed }) else { throw SubscriptionCLIError.closed }
                    try input.write(contentsOf: payload)
                    reply.resume()
                } catch { reply.resume(throwing: SubscriptionCLIError.closed) }
            }
        }
        try Task.checkCancellation()
    }

    func closeInput() { try? input.close() }

    func resetTimeout(_ seconds: TimeInterval) {
        lock.withLock {
            timeoutTask?.cancel()
            timeoutTask = Task.detached { [weak self] in
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                self?.close(throwing: SubscriptionCLIError.timedOut)
            }
        }
    }

    func close(throwing error: (any Error)? = nil) {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            timeoutTask?.cancel()
            timeoutTask = nil
            return true
        }
        guard shouldClose else { return }
        continuation.finish(throwing: error)
        closeInput()
        if process.isRunning { process.terminate() }
        let process = self.process
        Task.detached {
            try? await Task.sleep(for: .milliseconds(500))
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func readOutput(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { try? handle.close() }
            do {
                var buffer = Data()
                var received = 0
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    received += chunk.count
                    guard received <= 32 * 1_024 * 1_024 else { throw SubscriptionCLIError.malformed }
                    buffer.append(chunk)
                    while let end = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[..<end])
                        buffer.removeSubrange(...end)
                        if !line.isEmpty { continuation.yield(line) }
                    }
                }
                if !buffer.isEmpty { continuation.yield(buffer) }
                process.waitUntilExit()
                close(throwing: process.terminationStatus == 0 ? nil : SubscriptionCLIError.failed)
            } catch { close(throwing: SubscriptionCLIError.closed) }
        }
    }
}

final class SubscriptionCodexSession {
    let child: SubscriptionProcess
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator
    private var nextID = 1
    private var buffered: [[String: Any]] = []

    private init(child: SubscriptionProcess) {
        self.child = child
        iterator = child.lines.makeAsyncIterator()
    }

    static func start(executable: URL) async throws -> SubscriptionCodexSession {
        let disabled = ["shell_tool", "unified_exec", "apply_patch_freeform", "view_image", "code_mode",
            "code_mode_host", "multi_agent", "multi_agent_v2", "js_repl", "apps", "connectors", "plugins",
            "hooks", "codex_hooks", "plugin_hooks", "computer_use", "browser_use", "in_app_browser",
            "memories", "memory_tool", "skill_search", "image_generation", "imagegenext",
            "stable_environment_tools", "search_tool", "tool_search"]
        let overrides = ["model_provider=\"openai\"", "mcp_servers={}", "plugins={}", "hooks={}",
            "notify=[]", "project_doc_max_bytes=0", "web_search=\"disabled\"",
            "features.skip_host_skill_discovery=true", "history.persistence=\"none\""]
            + disabled.map { "features.\($0)=false" }
        func connect(_ configuration: [String]) async throws -> SubscriptionCodexSession {
            let arguments = configuration.flatMap { ["-c", $0] } + ["app-server", "--stdio"]
            let child = try SubscriptionProcess(executable: executable, arguments: arguments, timeout: 15)
            let session = SubscriptionCodexSession(child: child)
            do {
                return try await withTaskCancellationHandler {
                    _ = try await session.request("initialize", params: ["clientInfo": ["name": "typer_on", "title": "Typer On", "version": "1"],
                        "capabilities": ["experimentalApi": true]])
                    try await child.write(["method": "initialized"])
                    return session
                } onCancel: { child.close(throwing: CancellationError()) }
            } catch { child.close(); throw error }
        }
        var session = try await connect(overrides)
        do {
            // Empty tables MERGE with user config. Inspect names only, then disable every entry before starting a thread.
            var configuration = try await session.configuration()
            let mcp = configuration["mcp_servers"] as? [String: Any] ?? [:]
            let plugins = configuration["plugins"] as? [String: Any] ?? [:]
            if !mcp.isEmpty || !plugins.isEmpty {
                // CLI dotted paths do not parse quoted keys. Set a TOML table of explicit disabled entries instead.
                let entries = try [("mcp_servers", Array(mcp.keys)), ("plugins", Array(plugins.keys))].map { table, keys in
                    let values = try keys.sorted().map { "\(try quotedKey($0))={enabled=false}" }.joined(separator: ",")
                    return "\(table)={\(values)}"
                }
                session.child.close()
                session = try await connect(overrides + entries)
                configuration = try await session.configuration()
            }
            for table in ["mcp_servers", "plugins"] {
                let entries = configuration[table] as? [String: [String: Any]] ?? [:]
                guard entries.values.allSatisfy({ $0["enabled"] as? Bool == false }) else {
                    throw SubscriptionCLIError.toolsRejected
                }
            }
            let features = configuration["features"] as? [String: Any] ?? [:]
            guard disabled.allSatisfy({ key in
                features[key] as? Bool != true && (features[key] as? [String: Any])?["enabled"] as? Bool != true
            }) else { throw SubscriptionCLIError.toolsRejected }
            return session
        } catch { session.child.close(); throw error }
    }

    private static func quotedKey(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func configuration() async throws -> [String: Any] {
        let child = self.child
        return try await withTaskCancellationHandler {
            let response = try await request("config/read", params: ["includeLayers": false])
            guard let config = response["config"] as? [String: Any] else { throw SubscriptionCLIError.malformed }
            return config
        } onCancel: { child.close(throwing: CancellationError()) }
    }

    @discardableResult
    func requireSubscription() async throws -> SubscriptionAccount {
        let result = try await request("account/read", params: ["refreshToken": true])
        guard let account = result["account"] as? [String: Any] else { throw SubscriptionCLIError.signedOut("Codex") }
        guard account["type"] as? String == "chatgpt",
              let plan = account["planType"] as? String, !plan.isEmpty, plan.lowercased() != "free" else {
            throw SubscriptionCLIError.apiKeyAccount("Codex")
        }
        let email = (account["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SubscriptionAccount(label: email.flatMap { $0.isEmpty ? nil : $0 } ?? "ChatGPT",
                                   detail: "ChatGPT \(plan.capitalized)")
    }

    func models() async throws -> [OpenRouterModel] {
        var models: [OpenRouterModel] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<20 {
            var params: [String: Any] = ["includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let page = try await request("model/list", params: params)
            guard let entries = page["data"] as? [[String: Any]] else { throw SubscriptionCLIError.malformed }
            for entry in entries where entry["hidden"] as? Bool != true {
                guard let id = entry["model"] as? String, !id.isEmpty, seen.insert(id).inserted else { continue }
                let input = entry["inputModalities"] as? [String]
                let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]])?.compactMap { effort -> ReasoningEffortOption? in
                    guard let id = effort["reasoningEffort"] as? String, !id.isEmpty else { return nil }
                    return ReasoningEffortOption(id: id, detail: effort["description"] as? String ?? "")
                }
                models.append(OpenRouterModel(id: id, name: entry["displayName"] as? String ?? id,
                    context_length: nil, architecture: input.map { .init(input_modalities: $0, output_modalities: ["text"]) },
                    reasoningEfforts: efforts, defaultReasoningEffort: entry["defaultReasoningEffort"] as? String))
            }
            guard let next = page["nextCursor"] as? String, !next.isEmpty else { return models }
            cursor = next
        }
        throw SubscriptionCLIError.malformed
    }

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try await child.write(["id": id, "method": method, "params": params])
        while let line = try await iterator.next() {
            let object = try SubscriptionCLI.decode(line)
            if object["method"] != nil {
                try await rejectToolRequest(object)
                buffered.append(object)
                guard buffered.count <= 1_024 else { throw SubscriptionCLIError.malformed }
                continue
            }
            guard object["id"] as? Int == id else { throw SubscriptionCLIError.malformed }
            if object["error"] != nil { throw SubscriptionCLIError.failed }
            guard let result = object["result"] as? [String: Any] else { throw SubscriptionCLIError.malformed }
            return result
        }
        throw SubscriptionCLIError.closed
    }

    func nextNotification() async throws -> [String: Any]? {
        if !buffered.isEmpty { return buffered.removeFirst() }
        guard let line = try await iterator.next() else { return nil }
        let object = try SubscriptionCLI.decode(line)
        try await rejectToolRequest(object)
        return object
    }

    private func rejectToolRequest(_ object: [String: Any]) async throws {
        guard object["method"] != nil, let id = object["id"] else { return }
        try await child.write(["id": id, "error": ["code": -32601, "message": "Typer On disables tool and approval requests."]])
        throw SubscriptionCLIError.toolsRejected
    }
}
