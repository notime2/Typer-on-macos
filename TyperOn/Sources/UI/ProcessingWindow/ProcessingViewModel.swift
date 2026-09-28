// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

enum ProcessingMode: Equatable {
    case review
    case automaticReplacement
}

enum AutomaticProcessingEvent: Equatable {
    case replaceStarted
    case succeeded
    case requiresPresentation
}

@MainActor
@Observable
final class ProcessingViewModel {
    enum CopyFeedbackState: Equatable {
        case idle
        case copied
    }

    private let environment: AppEnvironment
    private let historyStore: ChatHistoryStore
    private let streamingText: StreamingTextBuffer
    private let aiServiceProvider: () -> (any AIService)?
    private let replaceAction: (String, TextSelection) async -> ReplaceOutcome

    var originalText: String = ""
    var resultText: String = ""
    var userComment: String = ""
    var isStreaming: Bool = false
    var error: String?
    var isErrorRetryable: Bool = false
    var copyFeedbackState: CopyFeedbackState = .idle
    var replaceStatusMessage: String?

    private(set) var currentModule: (any TextModule)?
    private(set) var currentSelection: TextSelection?
    private(set) var lastReplacement: LastReplacement?
    /// This run as a saved conversation: the selection, each result and each refinement.
    private(set) var historyConversation: StoredChatConversation?
    private var streamTask: Task<Void, Never>?
    private var replacementTask: Task<ReplaceOutcome, Never>?
    private var lastComment: String?
    private let feedbackScheduler: any StreamingTextScheduler
    private var cancelCopyFeedback: (() -> Void)?
    private var copyFeedbackGeneration = UUID()
    private var currentRequestID = UUID()
    private var processingMode: ProcessingMode = .review
    private var autoReplaceOnNextSuccess = false

    var onDismiss: (() -> Void)?
    var onAutomaticProcessingEvent: ((AutomaticProcessingEvent) -> Void)?
    var onOpenChat: ((ChatConversationTarget) -> Void)?

    init(
        environment: AppEnvironment,
        aiServiceProvider: (() -> (any AIService)?)? = nil,
        replaceAction: ((String, TextSelection) async -> ReplaceOutcome)? = nil,
        streamingTextScheduler: any StreamingTextScheduler = MainQueueStreamingTextScheduler(),
        feedbackScheduler: any StreamingTextScheduler = MainQueueStreamingTextScheduler()
    ) {
        self.environment = environment
        self.historyStore = environment.chatHistoryStore
        self.feedbackScheduler = feedbackScheduler
        self.streamingText = StreamingTextBuffer(scheduler: streamingTextScheduler)
        self.aiServiceProvider = aiServiceProvider ?? { environment.aiService }
        self.replaceAction = replaceAction ?? { text, selection in
            guard let textReplacer = environment.textReplacer else { return .failed }
            return await textReplacer.replace(
                with: text,
                selection: selection,
                using: environment.accessibilityManager
            )
        }
    }

    func process(
        module: any TextModule,
        selection: TextSelection,
        mode: ProcessingMode = .review
    ) {
        // Saves a partial result of a run still in flight before this run replaces it.
        cancel()
        processingMode = mode
        autoReplaceOnNextSuccess = mode == .automaticReplacement
        self.currentModule = module
        self.currentSelection = selection
        self.originalText = selection.text
        self.resultText = ""
        self.error = nil
        replaceStatusMessage = nil
        lastReplacement = nil
        resetCopyFeedback()
        historyConversation = StoredChatConversation(
            moduleName: module.name,
            messages: [ChatConversationMessage(role: .user, text: selection.text)]
        )

        startStreaming(module: module, inputText: selection.text, comment: nil)
    }

    func refine() {
        guard let module = currentModule, !userComment.isEmpty else { return }
        cancel()
        let comment = userComment
        historyConversation?.messages.append(ChatConversationMessage(role: .user, text: comment))
        userComment = ""
        resultText = ""
        lastComment = comment
        autoReplaceOnNextSuccess = false
        startStreaming(module: module, inputText: originalText, comment: comment)
    }

    func retry() {
        guard let module = currentModule else { return }
        resultText = ""
        error = nil
        isErrorRetryable = false
        startStreaming(module: module, inputText: originalText, comment: lastComment)
    }

    func replaceOriginal() async {
        autoReplaceOnNextSuccess = false
        await performReplacement(automatic: false)
    }

    private func performReplacement(automatic: Bool) async {
        guard !Task.isCancelled, replacementTask == nil else { return }
        guard let selection = currentSelection else {
            error = "Cannot replace text: original selection is no longer available."
            isErrorRetryable = false
            if automatic {
                onAutomaticProcessingEvent?(.requiresPresentation)
            }
            return
        }

        error = nil
        isErrorRetryable = false
        replaceStatusMessage = nil

        let requestID = currentRequestID
        let replacementText = resultText
        let action = replaceAction
        let task = Task { await action(replacementText, selection) }
        replacementTask = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard currentRequestID == requestID else { return }
        replacementTask = nil
        guard !task.isCancelled, !Task.isCancelled else { return }
        switch outcome {
        case .replaced(let method):
            if automatic {
                lastReplacement = nil
                replaceStatusMessage = nil
                onAutomaticProcessingEvent?(.succeeded)
            } else {
                let replacement = LastReplacement(
                    originalText: selection.text,
                    replacementText: replacementText,
                    sourceAppPID: selection.sourceAppPID,
                    timestamp: Date(),
                    method: method
                )
                lastReplacement = replacement
                replaceStatusMessage = method == .clipboard
                    ? "Paste sent to the source app. Verify the result or undo the last replace."
                    : nil

                if method == .accessibility {
                    dismiss()
                }
            }
        case .failed:
            lastReplacement = nil
            error = "Could not replace text in the source app. Return focus to the original app and try Replace again."
            isErrorRetryable = false
            if automatic {
                onAutomaticProcessingEvent?(.requiresPresentation)
            }
        }
    }

    func undoLastReplace() async {
        guard let textReplacer = environment.textReplacer,
              let lastReplacement else { return }

        error = nil
        isErrorRetryable = false

        let success = await textReplacer.undoLastReplacement(lastReplacement)
        if success {
            replaceStatusMessage = "Undo sent to the source app."
            self.lastReplacement = nil
        } else {
            error = "Could not undo the last replace. Return focus to the original app and try again."
            isErrorRetryable = false
        }
    }

    func copyResult() {
        guard !resultText.isEmpty else { return }
        environment.clipboardManager.write(resultText)

        cancelCopyFeedbackWork()
        copyFeedbackState = .copied
        let generation = copyFeedbackGeneration
        cancelCopyFeedback = feedbackScheduler.schedule(after: 1) { [weak self] in
            guard let self, self.copyFeedbackGeneration == generation else { return }
            self.cancelCopyFeedback = nil
            self.copyFeedbackState = .idle
        }
    }

    func cancel() {
        let wasStreaming = isStreaming
        streamingText.finish()
        currentRequestID = UUID()
        replacementTask?.cancel()
        replacementTask = nil
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        cancelCopyFeedbackWork()
        // The response task no longer reaches its own save once the request ID changed.
        if wasStreaming { saveHistory(result: resultText) }
    }

    func dismiss() {
        autoReplaceOnNextSuccess = false
        cancel()
        onDismiss?()
    }

    /// Chat owns stored conversations, so history items and New Chat leave Processing.
    func openChat(_ target: ChatConversationTarget) {
        dismiss()
        onOpenChat?(target)
    }

    var historyConversations: [StoredChatConversation] { historyStore.conversations }

    private func saveHistory(result: String?) {
        guard var conversation = historyConversation else { return }
        if let result, !result.isEmpty {
            conversation.messages.append(ChatConversationMessage(role: .assistant, text: result))
        }
        conversation.updatedAt = Date()
        historyConversation = conversation
        historyStore.upsert(conversation)
    }

    private func startStreaming(module: any TextModule, inputText: String, comment: String?) {
        streamingText.cancel()
        cancel()
        resetCopyFeedback()

        guard let aiService = aiServiceProvider() else {
            error = "AI service not configured. Open Settings (Cmd+,) to add your API key."
            isErrorRetryable = false
            if processingMode == .automaticReplacement {
                onAutomaticProcessingEvent?(.requiresPresentation)
            }
            return
        }

        isStreaming = true
        error = nil
        isErrorRetryable = false
        lastComment = comment
        replaceStatusMessage = nil
        let requestID = UUID()
        currentRequestID = requestID

        let moduleConfig = environment.moduleAIConfig(for: module.id)
        var context = ModuleContext.default
        context.targetLanguage = UserDefaults.standard.defaultTargetLanguage
        context.fallbackTargetLanguage = UserDefaults.standard.translationFallbackLanguage
        context.outputLanguageMode = moduleConfig?.resolvedOutputLanguageMode(for: module.id)
            ?? ModuleOutputLanguageMode.defaultMode(for: module.id)
        context.sourceLanguageName = inputText.detectedLanguageDisplayName
        context.userComment = comment
        context.customSystemPrompt = moduleConfig?.customSystemPrompt

        let messages = module.buildPrompt(for: inputText, context: context)
        let config = environment.resolveAIConfig(for: module)

        let request = ChatRequest(
            model: config.model,
            messages: messages,
            temperature: config.temperature,
            maxTokens: config.maxTokens,
            stream: true
        )

        streamingText.begin { [weak self] chunk in
            guard let self, self.currentRequestID == requestID else { return }
            self.resultText += chunk
        }

        streamTask = Task {
            do {
                let stream = aiService.stream(request: request, config: config)
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    guard currentRequestID == requestID else { return }
                    streamingText.append(chunk)
                }
                guard currentRequestID == requestID else { return }
                guard !Task.isCancelled else { return }
                streamingText.finish()
                resultText = module.postProcess(response: resultText, originalText: inputText)
                isStreaming = false
                saveHistory(result: resultText)

                guard !Task.isCancelled,
                      currentRequestID == requestID else { return }

                if autoReplaceOnNextSuccess {
                    guard !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        error = "The module returned an empty result."
                        isErrorRetryable = true
                        isStreaming = false
                        onAutomaticProcessingEvent?(.requiresPresentation)
                        return
                    }

                    autoReplaceOnNextSuccess = false
                    onAutomaticProcessingEvent?(.replaceStarted)
                    await performReplacement(automatic: true)
                }
            } catch is CancellationError {
                guard currentRequestID == requestID else { return }
                streamingText.finish()
                isStreaming = false
            } catch {
                guard currentRequestID == requestID else { return }
                streamingText.finish()
                self.error = error.localizedDescription
                self.isErrorRetryable = (error as? AIError)?.isRetryable ?? true
                isStreaming = false
                saveHistory(result: nil)
                if processingMode == .automaticReplacement {
                    onAutomaticProcessingEvent?(.requiresPresentation)
                }
                Log.ai.error("AI request failed: \(error)")
            }
        }
    }

    private func cancelCopyFeedbackWork() {
        copyFeedbackGeneration = UUID()
        cancelCopyFeedback?()
        cancelCopyFeedback = nil
    }

    private func resetCopyFeedback() {
        cancelCopyFeedbackWork()
        copyFeedbackState = .idle
    }

#if DEBUG
    func waitForPendingWorkForTesting() async {
        await streamTask?.value
    }
#endif
}
