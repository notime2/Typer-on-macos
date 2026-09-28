// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI

enum ChatMessageCopyFeedbackState: Equatable {
    case idle
    case copied
}

@MainActor
@Observable
final class ChatViewModel {
    private let environment: AppEnvironment
    private let historyStore: ChatHistoryStore
    private let chatModule: ContentGenerationModule
    private let aiServiceProvider: () -> (any AIService)?
    private let resolvedAIConfigProvider: (ContentGenerationModule) -> ResolvedAIConfig
    private let moduleAIConfigProvider: (String) -> ModuleAIConfig?
    private let defaultTargetLanguageProvider: () -> String
    private let screenshotCapturer: any ScreenshotCapturing
    private let screenshotWindowProvider: () -> (any ScreenshotCaptureWindow)?
    private let captureCleanupBarrierObserver: (() -> Void)?
    private let cachedModelProvider: (String) -> OpenRouterModel?
    private let modelResolver: (String, String) async -> OpenRouterModel?
    private let configuredModelIDProvider: () -> String
    private let streamingText: StreamingTextBuffer

    var messages: [ChatConversationMessage] = []
    var inputText: String = ""
    var isStreaming: Bool = false
    var isPreparingSend: Bool = false
    var isCapturingScreenshot: Bool = false
    var isModelCapabilityLoading: Bool = false
    var error: String?
    var captureError: String?
    var isErrorRetryable: Bool = false
    var inputFocusRequestID = UUID()
    var pendingSelectionText: String?
    var conversationContextText: String?
    var pendingScreenshot: ChatImageAttachment?
    private(set) var configuredModelID: String?
    private(set) var activeModelID: String?
    private(set) var activeModel: OpenRouterModel?
    private(set) var copiedMessageID: UUID?
    /// The saved conversation this window continues; nil for an unsaved draft.
    private(set) var currentConversation: StoredChatConversation?

    private var streamTask: Task<Void, Never>?
    private var sendPreparationTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private let feedbackScheduler: any StreamingTextScheduler
    private var cancelCopyFeedback: (() -> Void)?
    private var copyFeedbackGeneration = UUID()
    private var currentRequestID = UUID()
    private var currentCaptureID = UUID()
    private var capabilityRefreshID = UUID()
    var onDismiss: (() -> Void)?

    init(
        environment: AppEnvironment,
        chatModule: ContentGenerationModule = ContentGenerationModule(),
        aiServiceProvider: (() -> (any AIService)?)? = nil,
        resolvedAIConfigProvider: ((ContentGenerationModule) -> ResolvedAIConfig)? = nil,
        moduleAIConfigProvider: ((String) -> ModuleAIConfig?)? = nil,
        defaultTargetLanguageProvider: (() -> String)? = nil,
        screenshotCapturer: (any ScreenshotCapturing)? = nil,
        screenshotWindowProvider: (() -> (any ScreenshotCaptureWindow)?)? = nil,
        captureCleanupBarrierObserver: (() -> Void)? = nil,
        cachedModelProvider: ((String) -> OpenRouterModel?)? = nil,
        modelResolver: ((String, String) async -> OpenRouterModel?)? = nil,
        configuredModelIDProvider: (() -> String)? = nil,
        streamingTextScheduler: any StreamingTextScheduler = MainQueueStreamingTextScheduler(),
        feedbackScheduler: any StreamingTextScheduler = MainQueueStreamingTextScheduler()
    ) {
        self.environment = environment
        self.historyStore = environment.chatHistoryStore
        self.feedbackScheduler = feedbackScheduler
        self.streamingText = StreamingTextBuffer(scheduler: streamingTextScheduler)
        self.chatModule = chatModule
        self.aiServiceProvider = aiServiceProvider ?? { environment.aiService }
        self.resolvedAIConfigProvider = resolvedAIConfigProvider ?? { environment.resolveAIConfig(for: $0) }
        self.moduleAIConfigProvider = moduleAIConfigProvider ?? { environment.moduleAIConfig(for: $0) }
        self.defaultTargetLanguageProvider = defaultTargetLanguageProvider ?? {
            UserDefaults.standard.defaultTargetLanguage
        }
        self.screenshotCapturer = screenshotCapturer ?? ScreenshotCaptureService()
        self.screenshotWindowProvider = screenshotWindowProvider ?? {
            NSApp.keyWindow ?? NSApp.mainWindow
        }
        self.captureCleanupBarrierObserver = captureCleanupBarrierObserver
        self.cachedModelProvider = cachedModelProvider ?? { environment.modelCatalog.model(for: $0) }
        self.modelResolver = modelResolver ?? { modelID, apiKey in
            await environment.modelCatalog.resolveModel(for: modelID, apiKey: apiKey)
        }
        self.configuredModelIDProvider = configuredModelIDProvider ?? {
            environment.resolveAIModelID(for: chatModule)
        }
    }

    var canCaptureScreenshot: Bool {
        let currentModelID = configuredModelIDProvider()
        return configuredModelID == currentModelID
            && activeModelID == currentModelID
            && activeModel?.id == currentModelID
            && activeModel?.supportsImageInput == true
    }

    var modelCatalogSnapshot: [OpenRouterModel] {
        environment.modelCatalog.models
    }

    var currentConversationID: UUID? { currentConversation?.id }

    var historyConversations: [StoredChatConversation] { historyStore.conversations }

    func presentConversation(_ target: ChatConversationTarget) {
        switch target {
        case .continueCurrentOrMostRecent:
            if !hasSessionState, let mostRecent = historyStore.conversations.first {
                load(mostRecent)
            }
        case .newDraft(let pendingSelectionText):
            reset()
            setPendingSelectionText(pendingSelectionText)
        case .existing(let id):
            if id != currentConversationID, let conversation = historyStore.conversation(id: id) {
                load(conversation)
            }
        }
        requestInputFocus()
    }

    func startNewChat() {
        presentConversation(.newDraft(pendingSelectionText: nil))
    }

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !isStreaming,
              !isPreparingSend,
              !isCapturingScreenshot else { return }

        let config = resolvedAIConfigProvider(chatModule)
        let requestContainsScreenshot = pendingScreenshot != nil
            || messages.contains { $0.role == .user && !$0.images.isEmpty }

        guard requestContainsScreenshot else {
            synchronizeActiveModelWithCache(for: config)
            commitMessage(text, config: config, resolvedModel: activeModelForConfig(config))
            return
        }

        isPreparingSend = true
        sendPreparationTask?.cancel()
        sendPreparationTask = Task { [weak self] in
            guard let self else { return }
            let resolvedModel = await self.refreshActiveModelCapabilities()
            guard !Task.isCancelled else { return }

            let currentConfig = self.resolvedAIConfigProvider(self.chatModule)
            if currentConfig.model != config.model
                || resolvedModel?.id != config.model
                || resolvedModel?.supportsImageInput != true {
                self.captureError = "The selected Chat model does not support the screenshot in this conversation."
                self.isPreparingSend = false
                self.sendPreparationTask = nil
                self.requestInputFocus()
                return
            }

            self.commitMessage(text, config: config, resolvedModel: resolvedModel)
        }
    }

    func retry() {
        guard !messages.isEmpty,
              !isStreaming,
              !isPreparingSend,
              !isCapturingScreenshot else { return }

        let config = resolvedAIConfigProvider(chatModule)
        let requestContainsScreenshot = messages.contains {
            $0.role == .user && !$0.images.isEmpty
        }

        guard requestContainsScreenshot else {
            synchronizeActiveModelWithCache(for: config)
            commitRetry(config: config, resolvedModel: activeModelForConfig(config))
            return
        }

        isPreparingSend = true
        sendPreparationTask?.cancel()
        sendPreparationTask = Task { [weak self] in
            guard let self else { return }
            let resolvedModel = await self.refreshActiveModelCapabilities()
            guard !Task.isCancelled else { return }

            let currentConfig = self.resolvedAIConfigProvider(self.chatModule)
            if currentConfig.model != config.model
                || resolvedModel?.id != config.model
                || resolvedModel?.supportsImageInput != true {
                self.captureError = "The selected Chat model does not support the attached screenshot."
                self.isPreparingSend = false
                self.sendPreparationTask = nil
                self.requestInputFocus()
                return
            }

            self.commitRetry(config: config, resolvedModel: resolvedModel)
        }
    }

    func stopStreaming() {
        let wasResponding = isStreaming
        streamingText.finish()
        streamTask?.cancel()
        streamTask = nil
        currentRequestID = UUID()
        isStreaming = false
        // The response task no longer reaches its own save once the request ID changed.
        if wasResponding { saveConversation() }
    }

    func copyMessage(_ message: ChatConversationMessage) {
        guard !message.text.isEmpty else { return }
        environment.clipboardManager.write(message.text)

        resetCopyFeedback()
        copiedMessageID = message.id
        let generation = copyFeedbackGeneration
        cancelCopyFeedback = feedbackScheduler.schedule(after: 1) { [weak self] in
            guard let self, self.copyFeedbackGeneration == generation else { return }
            self.cancelCopyFeedback = nil
            self.copiedMessageID = nil
        }
    }

    func copyFeedbackState(for message: ChatConversationMessage) -> ChatMessageCopyFeedbackState {
        copiedMessageID == message.id ? .copied : .idle
    }

    func reset() {
        streamingText.cancel()
        stopStreaming()
        sendPreparationTask?.cancel()
        sendPreparationTask = nil
        captureTask?.cancel()
        currentCaptureID = UUID()
        resetCopyFeedback()
        messages.removeAll()
        inputText = ""
        isPreparingSend = false
        isCapturingScreenshot = false
        error = nil
        captureError = nil
        isErrorRetryable = false
        pendingSelectionText = nil
        conversationContextText = nil
        pendingScreenshot = nil
        currentConversation = nil
    }

    func dismiss() {
        stopStreaming()
        sendPreparationTask?.cancel()
        sendPreparationTask = nil
        captureTask?.cancel()
        currentCaptureID = UUID()
        isPreparingSend = false
        isCapturingScreenshot = false
        resetCopyFeedback()
        onDismiss?()
    }

    func requestInputFocus() {
        inputFocusRequestID = UUID()
    }

    func setPendingSelectionText(_ text: String?) {
        pendingSelectionText = normalizedSelectionText(from: text)
        if pendingSelectionText != nil {
            conversationContextText = nil
        }
    }

    func clearPendingSelectionText() {
        guard !isPreparingSend else { return }
        pendingSelectionText = nil
        requestInputFocus()
    }

    func clearPendingScreenshot() {
        guard !isPreparingSend else { return }
        pendingScreenshot = nil
        captureError = nil
        requestInputFocus()
    }

    func captureScreenshot(mode: ScreenshotCaptureMode) {
        guard canCaptureScreenshot,
              !isCapturingScreenshot,
              !isStreaming,
              !isPreparingSend else { return }

        let windowSnapshot = ScreenshotCaptureWindowSnapshot(window: screenshotWindowProvider())
        isCapturingScreenshot = true
        captureError = nil
        let captureID = UUID()
        currentCaptureID = captureID
        let previousCaptureTask = captureTask
        let captureCleanupBarrierObserver = self.captureCleanupBarrierObserver
        previousCaptureTask?.cancel()
        captureTask = ScreenshotCaptureContext.$initiatingWindow.withValue(windowSnapshot) {
            Task { [weak self, previousCaptureTask, captureCleanupBarrierObserver] in
                if let previousCaptureTask {
                    captureCleanupBarrierObserver?()
                    await previousCaptureTask.value
                }
                guard !Task.isCancelled,
                      let self,
                      self.currentCaptureID == captureID else { return }
                let resolvedModel = await self.refreshActiveModelCapabilities()
                guard !Task.isCancelled, self.currentCaptureID == captureID else { return }

                let config = self.resolvedAIConfigProvider(self.chatModule)
                guard resolvedModel?.id == config.model,
                      resolvedModel?.supportsImageInput == true else {
                    self.captureError = "The selected Chat model does not support image input."
                    self.finishCapture(id: captureID)
                    return
                }

                do {
                    if let screenshot = try await self.screenshotCapturer.captureScreenshot(mode: mode),
                       self.currentCaptureID == captureID,
                       !Task.isCancelled {
                        self.pendingScreenshot = ChatImageAttachment(
                            data: screenshot.pngData,
                            mimeType: "image/png",
                            pixelWidth: screenshot.pixelWidth,
                            pixelHeight: screenshot.pixelHeight
                        )
                        self.captureError = nil
                    }
                } catch is CancellationError {
                    // User dismissal and task cancellation leave existing state unchanged.
                } catch {
                    guard self.currentCaptureID == captureID else { return }
                    self.captureError = error.localizedDescription
                }

                self.finishCapture(id: captureID)
            }
        }
    }

    @discardableResult
    func refreshActiveModelCapabilities() async -> OpenRouterModel? {
        let config = resolvedAIConfigProvider(chatModule)
        let modelID = config.model
        let refreshID = UUID()
        capabilityRefreshID = refreshID
        configuredModelID = modelID
        activeModelID = modelID
        if let cachedModel = cachedModelProvider(modelID) {
            activeModel = cachedModel
        } else if activeModel?.id != modelID {
            activeModel = nil
        }
        isModelCapabilityLoading = true

        let resolvedModel = await modelResolver(modelID, config.apiKey)
        guard !Task.isCancelled else {
            if capabilityRefreshID == refreshID {
                isModelCapabilityLoading = false
            }
            return nil
        }
        guard capabilityRefreshID == refreshID else { return nil }

        let currentModelID = resolvedAIConfigProvider(chatModule).model
        guard currentModelID == modelID else {
            if capabilityRefreshID == refreshID {
                configuredModelID = currentModelID
                activeModelID = currentModelID
                activeModel = cachedModelProvider(currentModelID)
                isModelCapabilityLoading = false
            }
            return nil
        }

        let exactModel = resolvedModel?.id == modelID
            ? resolvedModel
            : cachedModelProvider(modelID)
        if capabilityRefreshID == refreshID {
            activeModel = exactModel ?? activeModel
            isModelCapabilityLoading = false
        }
        return exactModel
    }

    func invalidateActiveModelCapabilities() {
        capabilityRefreshID = UUID()
        configuredModelID = nil
        activeModelID = nil
        activeModel = nil
        isModelCapabilityLoading = false
    }

    // MARK: - Private

    private func synchronizeActiveModelWithCache(for config: ResolvedAIConfig) {
        configuredModelID = config.model
        activeModelID = config.model
        if let cachedModel = cachedModelProvider(config.model) {
            activeModel = cachedModel
        } else if activeModel?.id != config.model {
            activeModel = nil
        }
    }

    private func activeModelForConfig(_ config: ResolvedAIConfig) -> OpenRouterModel? {
        guard configuredModelID == config.model,
              activeModelID == config.model,
              activeModel?.id == config.model else {
            return nil
        }
        return activeModel
    }

    private func commitMessage(
        _ text: String,
        config: ResolvedAIConfig,
        resolvedModel: OpenRouterModel?
    ) {
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            inputText = ""
        }
        error = nil
        captureError = nil
        isErrorRetryable = false

        if let pendingContext = normalizedSelectionText(from: pendingSelectionText) {
            conversationContextText = pendingContext
            pendingSelectionText = nil
        }

        let submittedImages = pendingScreenshot.map { [$0] } ?? []
        pendingScreenshot = nil
        messages.append(ChatConversationMessage(role: .user, text: text, images: submittedImages))
        messages.append(ChatConversationMessage(role: .assistant))
        saveConversation()
        isPreparingSend = false
        sendPreparationTask = nil
        startResponse(config: config, resolvedModel: resolvedModel)
    }

    private func commitRetry(config: ResolvedAIConfig, resolvedModel: OpenRouterModel?) {
        if let last = messages.last, last.role == .assistant {
            messages.removeLast()
        }

        resetCopyFeedback()
        error = nil
        captureError = nil
        isErrorRetryable = false
        messages.append(ChatConversationMessage(role: .assistant))
        isPreparingSend = false
        sendPreparationTask = nil
        startResponse(config: config, resolvedModel: resolvedModel)
    }

    private func startResponse(config: ResolvedAIConfig, resolvedModel: OpenRouterModel?) {
        if resolvedModel?.id == config.model, resolvedModel?.supportsImageOutput == true {
            startImageGeneration(config: config)
        } else {
            startChatStreaming(config: config)
        }
    }

    private func startChatStreaming(config: ResolvedAIConfig) {
        stopStreaming()

        guard let aiService = aiServiceProvider() else {
            error = "AI service not configured. Open Settings (Cmd+,) to add your API key."
            isErrorRetryable = false
            return
        }

        isStreaming = true
        error = nil
        isErrorRetryable = false
        let requestID = UUID()
        currentRequestID = requestID

        let assistantID = messages.last?.id
        streamingText.begin { [weak self] chunk in
            guard let self, self.currentRequestID == requestID,
                  self.messages.last?.id == assistantID, !self.messages.isEmpty else { return }
            self.messages[self.messages.count - 1].text += chunk
        }

        streamTask = Task { [weak self] in
            guard let self else { return }
            let apiMessages: [ChatMessage]
            do {
                apiMessages = try await self.buildAPIMessages()
            } catch {
                return
            }
            guard !Task.isCancelled, self.currentRequestID == requestID else { return }

            let request = ChatRequest(
                model: config.model,
                messages: apiMessages,
                temperature: config.temperature,
                maxTokens: config.maxTokens,
                stream: true
            )

            do {
                let stream = aiService.streamChat(request: request, config: config)
                for try await event in stream {
                    if Task.isCancelled { break }
                    guard currentRequestID == requestID else { return }
                    guard !self.messages.isEmpty else { break }

                    switch event {
                    case .text(let chunk):
                        self.streamingText.append(chunk)
                    case .image(let data, let mimeType):
                        let attachment = ChatImageAttachment(data: data, mimeType: mimeType)
                        if !self.messages[self.messages.count - 1].images.contains(where: {
                            $0.data == data && $0.mimeType == mimeType
                        }) {
                            self.messages[self.messages.count - 1].images.append(attachment)
                        }
                    case .invalidImage:
                        self.messages[self.messages.count - 1].invalidImageCount += 1
                    }
                }
                guard currentRequestID == requestID else { return }
                self.streamingText.finish()
                self.endResponse()
            } catch is CancellationError {
                guard currentRequestID == requestID else { return }
                self.streamingText.finish()
                self.endResponse()
            } catch {
                guard currentRequestID == requestID else { return }
                self.error = error.localizedDescription
                self.isErrorRetryable = (error as? AIError)?.isRetryable ?? true
                self.streamingText.finish()
                self.endResponse()
                Log.ai.error("Chat AI request failed: \(error)")
            }
        }
    }

    private func startImageGeneration(config: ResolvedAIConfig) {
        stopStreaming()

        guard let aiService = aiServiceProvider() else {
            error = "AI service not configured. Open Settings (Cmd+,) to add your API key."
            isErrorRetryable = false
            return
        }

        isStreaming = true
        error = nil
        isErrorRetryable = false
        let requestID = UUID()
        currentRequestID = requestID

        let referenceScreenshot = latestSubmittedScreenshot
        let prompt = imageGenerationPrompt()

        streamTask = Task { [weak self] in
            guard let self else { return }
            let reference: [ImageGenerationInputReference]?
            do {
                reference = try await Self.encodeImageReference(referenceScreenshot)
            } catch {
                return
            }
            guard !Task.isCancelled, self.currentRequestID == requestID else { return }

            let request = ImageGenerationRequest(
                model: config.model,
                prompt: prompt,
                inputReferences: reference
            )

            do {
                let result = try await aiService.generateImages(request: request, config: config)
                guard !Task.isCancelled, currentRequestID == requestID else { return }
                guard !self.messages.isEmpty else { return }

                for image in result.images {
                    if !self.messages[self.messages.count - 1].images.contains(where: {
                        $0.data == image.data && $0.mimeType == image.mimeType
                    }) {
                        self.messages[self.messages.count - 1].images.append(
                            ChatImageAttachment(data: image.data, mimeType: image.mimeType)
                        )
                    }
                }
                self.messages[self.messages.count - 1].invalidImageCount += result.invalidImageCount
                self.endResponse()
            } catch is CancellationError {
                guard currentRequestID == requestID else { return }
                self.endResponse()
            } catch {
                guard currentRequestID == requestID else { return }
                self.error = error.localizedDescription
                self.isErrorRetryable = (error as? AIError)?.isRetryable ?? true
                self.endResponse()
                Log.ai.error("Chat image request failed: \(error)")
            }
        }
    }

    private func buildContextMessages() -> [ChatMessage] {
        var context = ModuleContext.default
        context.targetLanguage = defaultTargetLanguageProvider()
        context.outputLanguageMode = moduleAIConfigProvider(chatModule.id)?.resolvedOutputLanguageMode(for: chatModule.id)
            ?? ModuleOutputLanguageMode.defaultMode(for: chatModule.id)
        context.sourceLanguageName = sourceLanguageNameForCurrentRequest()
        context.customSystemPrompt = moduleAIConfigProvider(chatModule.id)?.customSystemPrompt

        var apiMessages: [ChatMessage] = [.system(ContentGenerationModule.buildSystemPrompt(context: context))]

        if let conversationContextText = normalizedSelectionText(from: conversationContextText) {
            apiMessages.append(.system(Self.selectionContextSystemMessage(for: conversationContextText)))
        }

        return apiMessages
    }

    private func buildAPIMessages() async throws -> [ChatMessage] {
        let contextMessages = buildContextMessages()
        let messageSnapshot = messages
        let historyMessages = try await Self.encodeHistoryMessages(messageSnapshot)

        return contextMessages + historyMessages
    }

    private nonisolated static func encodeHistoryMessages(
        _ messages: [ChatConversationMessage]
    ) async throws -> [ChatMessage] {
        var apiMessages: [ChatMessage] = []

        for message in messages {
            try Task.checkCancellation()
            switch message.role {
            case .user:
                var imageURLs: [String] = []
                for image in message.images {
                    try Task.checkCancellation()
                    imageURLs.append(image.dataURL)
                }
                apiMessages.append(.user(message.text, imageURLs: imageURLs))
            case .assistant:
                if !message.text.isEmpty {
                    apiMessages.append(.assistant(message.text))
                }
            }
        }
        return apiMessages
    }

    private nonisolated static func encodeImageReference(
        _ screenshot: ChatImageAttachment?
    ) async throws -> [ImageGenerationInputReference]? {
        try Task.checkCancellation()
        guard let screenshot else { return nil }
        let dataURL = screenshot.dataURL
        try Task.checkCancellation()
        return [ImageGenerationInputReference(imageURL: dataURL)]
    }

    private func imageGenerationPrompt() -> String {
        var promptMessages = buildContextMessages()
        for message in messages {
            switch message.role {
            case .user:
                promptMessages.append(.user(message.text))
            case .assistant:
                if !message.text.isEmpty {
                    promptMessages.append(.assistant(message.text))
                }
            }
        }

        return promptMessages
            .map { message in
                "\(message.role.uppercased()):\n\(message.content)"
            }
            .joined(separator: "\n\n")
    }

    private var latestSubmittedScreenshot: ChatImageAttachment? {
        for message in messages.reversed() where message.role == .user {
            if let image = message.images.last {
                return image
            }
        }
        return nil
    }

    private func sourceLanguageNameForCurrentRequest() -> String? {
        if let selectionText = normalizedSelectionText(from: pendingSelectionText ?? conversationContextText) {
            return selectionText.detectedLanguageDisplayName
        }

        return latestSubmittedUserText?.detectedLanguageDisplayName
    }

    private var latestSubmittedUserText: String? {
        messages.reversed().first(where: { $0.role == .user })?.text
    }

    private func normalizedSelectionText(from text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resetCopyFeedback() {
        copyFeedbackGeneration = UUID()
        cancelCopyFeedback?()
        cancelCopyFeedback = nil
        copiedMessageID = nil
    }

    private var hasSessionState: Bool {
        !messages.isEmpty
            || !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || pendingSelectionText != nil
            || conversationContextText != nil
            || pendingScreenshot != nil
            || isCapturingScreenshot
    }

    private func load(_ conversation: StoredChatConversation) {
        reset()
        messages = conversation.messages
        conversationContextText = conversation.conversationContextText
        currentConversation = conversation
    }

    private func endResponse() {
        isStreaming = false
        saveConversation()
    }

    /// Saves the current conversation to history. Empty drafts and empty assistant
    /// placeholders (a failed or not-yet-started response) are not saved.
    private func saveConversation() {
        let savedMessages = messages.filter {
            $0.role == .user || !$0.text.isEmpty || !$0.images.isEmpty || $0.invalidImageCount > 0
        }
        guard !savedMessages.isEmpty else { return }

        var conversation = currentConversation ?? StoredChatConversation()
        conversation.messages = savedMessages
        conversation.conversationContextText = conversationContextText
        conversation.updatedAt = Date()
        currentConversation = conversation
        historyStore.upsert(conversation)
    }

    private func finishCapture(id: UUID) {
        guard currentCaptureID == id else { return }
        isCapturingScreenshot = false
        captureTask = nil
        requestInputFocus()
    }

    private static func selectionContextSystemMessage(for text: String) -> String {
        """
        Use the following selected text as context for this conversation. Refer to it when it is relevant to the user's request.

        \(text)
        """
    }

#if DEBUG
    func waitForPendingWorkForTesting() async {
        await sendPreparationTask?.value
        await streamTask?.value
    }

    func waitForPendingCaptureForTesting() async {
        await captureTask?.value
    }
#endif
}
