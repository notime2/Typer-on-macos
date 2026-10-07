// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct SubscriptionAIService: AIService {
    let provider: AIProvider
    let executablePath: String?

    init(provider: AIProvider, executablePath: String? = nil) {
        self.provider = provider
        self.executablePath = executablePath
    }

    func stream(request: ChatRequest, config: ResolvedAIConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let executable = try SubscriptionCLI.resolveExecutable(provider: provider, configuredPath: executablePath)
                    if provider == .codex {
                        try await codex(request: request, model: request.model.isEmpty ? config.model : request.model,
                            executable: executable, continuation: continuation)
                    } else {
                        try await claude(request: request, model: request.model.isEmpty ? config.model : request.model,
                            executable: executable, continuation: continuation)
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func generateImages(request: ImageGenerationRequest, config: ResolvedAIConfig) async throws -> ImageGenerationResult {
        throw AIServiceFeatureError.imageGenerationUnsupported
    }

    private func codex(request: ChatRequest, model: String, executable: URL,
                       continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let session = try await SubscriptionCodexSession.start(executable: executable)
        let child = session.child
        defer { child.close() }
        try await withTaskCancellationHandler {
            try await session.requireSubscription()
            if request.messages.contains(where: { !$0.imageURLs.isEmpty }) {
                let models = try await session.models()
                guard models.first(where: { $0.id == model })?.supportsImageInput == true else {
                    throw SubscriptionCLIError.imageInputUnsupported
                }
            }
            var threadParams: [String: Any] = [
                "modelProvider": "openai", "cwd": child.directory.path,
                "ephemeral": true, "approvalPolicy": "never", "sandbox": "read-only",
                // Together with stable_environment_tools=false this removes environment/command/file tools.
                "allowProviderModelFallback": false, "dynamicTools": [], "environments": [],
                "baseInstructions": "You answer text transformation and chat requests. Reply directly with the requested result. Do not call tools, run commands, read or write files, or use external instructions. All context is supplied in the conversation.",
                "developerInstructions": request.messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
            ]
            if !model.isEmpty { threadParams["model"] = model }
            let thread = try await session.request("thread/start", params: threadParams)
            guard let threadID = (thread["thread"] as? [String: Any])?["id"] as? String else {
                throw SubscriptionCLIError.malformed
            }
            var input: [[String: Any]] = []
            for message in request.messages where message.role != "system" {
                input.append(["type": "text", "text": "[\(message.role)]\n\(message.content)", "text_elements": []])
                for url in message.imageURLs {
                    _ = try imageSource(url)
                    input.append(["type": "image", "url": url])
                }
            }
            child.resetTimeout(180)
            var turnParams: [String: Any] = ["threadId": threadID, "input": input,
                "approvalPolicy": "never", "environments": [],
                "sandboxPolicy": ["type": "readOnly", "networkAccess": false]]
            if !model.isEmpty { turnParams["model"] = model }
            let result = try await session.request("turn/start", params: turnParams)
            guard let turnID = (result["turn"] as? [String: Any])?["id"] as? String else {
                throw SubscriptionCLIError.malformed
            }
            var messages: [String: String] = [:]
            while let object = try await session.nextNotification() {
                try Task.checkCancellation()
                guard let method = object["method"] as? String else { throw SubscriptionCLIError.malformed }
                guard let params = object["params"] as? [String: Any] else { throw SubscriptionCLIError.malformed }
                guard params["threadId"] as? String == threadID else { continue }
                if let eventTurn = params["turnId"] as? String, eventTurn != turnID { continue }
                switch method {
                case "item/agentMessage/delta":
                    guard let text = params["delta"] as? String, let id = params["itemId"] as? String else {
                        throw SubscriptionCLIError.malformed
                    }
                    messages[id, default: ""] += text
                    continuation.yield(text)
                case "item/started", "item/completed":
                    guard let item = params["item"] as? [String: Any], let type = item["type"] as? String else {
                        throw SubscriptionCLIError.malformed
                    }
                    if ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall"].contains(type) {
                        throw SubscriptionCLIError.toolsRejected
                    }
                    if method == "item/completed", type == "agentMessage" {
                        guard let id = item["id"] as? String, let final = item["text"] as? String else {
                            throw SubscriptionCLIError.malformed
                        }
                        try reconcile(final, accumulated: &messages[id, default: ""], continuation: continuation)
                    }
                case "turn/completed":
                    guard let turn = params["turn"] as? [String: Any], turn["id"] as? String == turnID else { continue }
                    guard turn["status"] as? String == "completed", turn["error"] == nil || turn["error"] is NSNull else {
                        throw SubscriptionCLIError.failed
                    }
                    guard messages.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                        throw SubscriptionCLIError.emptyResponse
                    }
                    return
                case "error": throw SubscriptionCLIError.failed
                default: continue
                }
            }
            throw SubscriptionCLIError.closed
        } onCancel: { child.close(throwing: CancellationError()) }
    }

    private func claude(request: ChatRequest, model: String, executable: URL,
                        continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        try await SubscriptionCLI.requireClaudeSubscription(executable: executable)
        if request.messages.contains(where: { !$0.imageURLs.isEmpty }) {
            let models = try await SubscriptionCLI.claudeModels(executable: executable)
            guard models.first(where: { $0.id == model })?.supportsImageInput == true
                || SubscriptionCLI.claudeArchitecture(resolvedModel: model) != nil else {
                throw SubscriptionCLIError.imageInputUnsupported
            }
        }
        let systems = request.messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let arguments = SubscriptionCLI.claudeArguments + (model.isEmpty ? [] : ["--model", model])
            + ["--system-prompt", systems]
        let child = try SubscriptionProcess(executable: executable, arguments: arguments, timeout: 15)
        defer { child.close() }
        try await withTaskCancellationHandler {
            var content: [[String: Any]] = []
            // Print-mode accepts user envelopes; retain full history with explicit roles in one fresh request.
            // The CLI never loads a saved personal conversation or persists screenshots.
            for message in request.messages where message.role != "system" {
                content.append(["type": "text", "text": "[\(message.role)]\n\(message.content)"])
                for url in message.imageURLs { content.append(["type": "image", "source": try imageSource(url)]) }
            }
            try await child.write(["type": "user", "message": ["role": "user", "content": content],
                "parent_tool_use_id": NSNull(), "session_id": ""])
            child.closeInput()
            var accumulated = ""
            var currentMessage = "response"
            var texts: [String: String] = [:]
            var completed = false
            for try await line in child.lines {
                try Task.checkCancellation()
                let object = try SubscriptionCLI.decode(line)
                guard let type = object["type"] as? String else { throw SubscriptionCLIError.malformed }
                switch type {
                case "system":
                    if let tools = object["tools"] as? [Any], !tools.isEmpty { throw SubscriptionCLIError.toolsRejected }
                    if object["subtype"] as? String == "init" { child.resetTimeout(180) }
                case "stream_event":
                    guard let event = object["event"] as? [String: Any], let eventType = event["type"] as? String else {
                        throw SubscriptionCLIError.malformed
                    }
                    if eventType == "message_start", let message = event["message"] as? [String: Any], let id = message["id"] as? String {
                        currentMessage = id
                    }
                    if eventType == "content_block_start", let block = event["content_block"] as? [String: Any],
                       block["type"] as? String == "tool_use" { throw SubscriptionCLIError.toolsRejected }
                    if eventType == "content_block_delta", let delta = event["delta"] as? [String: Any],
                       delta["type"] as? String == "text_delta" {
                        guard let text = delta["text"] as? String else { throw SubscriptionCLIError.malformed }
                        texts[currentMessage, default: ""] += text
                        accumulated += text
                        continuation.yield(text)
                    }
                case "assistant":
                    guard let message = object["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else {
                        throw SubscriptionCLIError.malformed
                    }
                    if blocks.contains(where: { $0["type"] as? String == "tool_use" }) { throw SubscriptionCLIError.toolsRejected }
                    let id = message["id"] as? String ?? currentMessage
                    let final = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                    let previous = texts[id, default: ""]
                    try reconcile(final, accumulated: &texts[id, default: ""], continuation: continuation)
                    accumulated += String(final.dropFirst(previous.count))
                case "result":
                    guard object["subtype"] as? String == "success", object["is_error"] as? Bool != true else {
                        throw SubscriptionCLIError.failed
                    }
                    guard !completed else { throw SubscriptionCLIError.malformed }
                    if accumulated.isEmpty, let text = object["result"] as? String {
                        accumulated = text
                        continuation.yield(text)
                    }
                    guard !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw SubscriptionCLIError.emptyResponse
                    }
                    completed = true
                case "control_request": throw SubscriptionCLIError.toolsRejected
                case "control_response", "user", "rate_limit_event", "auth_status": continue
                default: throw SubscriptionCLIError.malformed
                }
            }
            guard completed else { throw SubscriptionCLIError.closed }
        } onCancel: { child.close(throwing: CancellationError()) }
    }

    private func reconcile(_ final: String, accumulated: inout String,
                           continuation: AsyncThrowingStream<String, Error>.Continuation) throws {
        guard final.hasPrefix(accumulated) else { throw SubscriptionCLIError.malformed }
        let suffix = String(final.dropFirst(accumulated.count))
        accumulated = final
        if !suffix.isEmpty { continuation.yield(suffix) }
    }

    private func imageSource(_ url: String) throws -> [String: Any] {
        guard let separator = url.firstIndex(of: ",") else { throw SubscriptionCLIError.imageInputUnsupported }
        let header = String(url[..<separator])
        let mediaType = header.replacingOccurrences(of: "data:", with: "").replacingOccurrences(of: ";base64", with: "")
        let base64 = String(url[url.index(after: separator)...])
        guard header == "data:\(mediaType);base64", ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mediaType),
              let data = Data(base64Encoded: base64), !data.isEmpty, data.count <= 20 * 1_024 * 1_024 else {
            throw SubscriptionCLIError.imageInputUnsupported
        }
        return ["type": "base64", "media_type": mediaType, "data": base64]
    }
}
