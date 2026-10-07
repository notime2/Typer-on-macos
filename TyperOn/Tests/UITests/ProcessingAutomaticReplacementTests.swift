// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Foundation
import Testing
@testable import Typer_On

@Test
@MainActor
func testAutomaticProcessingReplacesPostProcessedResultOnce() async {
    let scheduler = ManualStreamingTextScheduler()
    let service = ProcessingTestAIService(responses: [.chunks(["Pro", "ces", "sed"])])
    var replacements: [String] = []
    var events: [AutomaticProcessingEvent] = []
    let viewModel = ProcessingViewModel(
        environment: AppEnvironment(),
        aiServiceProvider: { service },
        replaceAction: { text, _ in
            replacements.append(text)
            return .replaced(.accessibility)
        },
        streamingTextScheduler: scheduler
    )
    viewModel.onAutomaticProcessingEvent = { events.append($0) }

    viewModel.process(
        module: TranslationModule(),
        selection: makeProcessingSelection(),
        mode: .automaticReplacement
    )

    await viewModel.waitForPendingWorkForTesting()

    #expect(events.contains(.succeeded))
    scheduler.advance(includingCancelled: true)
    #expect(replacements == ["Processed"])
    #expect(events == [.replaceStarted, .succeeded])
}

@Test
@MainActor
func testAutomaticClipboardReplacementCompletesWithoutManualReplacementState() async {
    let service = ProcessingTestAIService(responses: [.success("Pasted")])
    var replacements: [String] = []
    var events: [AutomaticProcessingEvent] = []
    let viewModel = ProcessingViewModel(
        environment: AppEnvironment(),
        aiServiceProvider: { service },
        replaceAction: { text, _ in
            replacements.append(text)
            return .replaced(.clipboard)
        }
    )
    viewModel.onAutomaticProcessingEvent = { events.append($0) }

    viewModel.process(
        module: TranslationModule(),
        selection: makeProcessingSelection(),
        mode: .automaticReplacement
    )

    await viewModel.waitForPendingWorkForTesting()

    #expect(events.contains(.succeeded))
    #expect(replacements == ["Pasted"])
    #expect(viewModel.lastReplacement == nil)
}

@Test
@MainActor
func testAutomaticReplacementFailureRequiresProcessingPresentation() async {
    let service = ProcessingTestAIService(responses: [.success("Cannot replace")])
    var events: [AutomaticProcessingEvent] = []
    let viewModel = ProcessingViewModel(
        environment: AppEnvironment(),
        aiServiceProvider: { service },
        replaceAction: { _, _ in .failed }
    )
    viewModel.onAutomaticProcessingEvent = { events.append($0) }

    viewModel.process(
        module: TranslationModule(),
        selection: makeProcessingSelection(),
        mode: .automaticReplacement
    )

    await viewModel.waitForPendingWorkForTesting()

    #expect(events.contains(.requiresPresentation))
    #expect(events == [.replaceStarted, .requiresPresentation])
    #expect(viewModel.isErrorRetryable == false)
}

@Test
@MainActor
func testFailedRepeatReplacementClearsPreviousUndoState() async {
    let service = ProcessingTestAIService(responses: [.success("Updated")])
    var replacementCalls = 0
    let viewModel = ProcessingViewModel(
        environment: AppEnvironment(),
        aiServiceProvider: { service },
        replaceAction: { _, _ in
            replacementCalls += 1
            return replacementCalls == 1 ? .replaced(.clipboard) : .failed
        }
    )
    viewModel.process(module: TranslationModule(), selection: makeProcessingSelection())
    await viewModel.waitForPendingWorkForTesting()
    await viewModel.replaceOriginal()
    #expect(viewModel.lastReplacement != nil)

    await viewModel.replaceOriginal()

    #expect(viewModel.lastReplacement == nil)
    #expect(viewModel.replaceStatusMessage == nil)
    #expect(viewModel.error != nil)
}

@Test
@MainActor
func testProcessingSessionInvalidationCancelsManualReplacementAndIgnoresLateResult() async {
    for action in ["cancel", "dismiss", "new_selection"] {
        for outcome in [ReplaceOutcome.replaced(.clipboard), .failed] {
            let service = ProcessingTestAIService(responses: [.success("Updated A"), .success("Updated B")])
            let started = AsyncStream<Void>.makeStream()
            var resumeReplacement: CheckedContinuation<ReplaceOutcome, Never>?
            var replacementWasCancelled = false
            let viewModel = ProcessingViewModel(
                environment: AppEnvironment(),
                aiServiceProvider: { service },
                replaceAction: { _, _ in
                    let result = await withCheckedContinuation { continuation in
                        resumeReplacement = continuation
                        started.continuation.yield(())
                    }
                    replacementWasCancelled = Task.isCancelled
                    return result
                }
            )
            viewModel.process(module: TranslationModule(), selection: makeProcessingSelection())
            await viewModel.waitForPendingWorkForTesting()
            let pending = Task { await viewModel.replaceOriginal() }
            for await _ in started.stream { break }

            if action == "new_selection" {
                viewModel.process(module: TranslationModule(), selection: makeProcessingSelection())
                await viewModel.waitForPendingWorkForTesting()
                #expect(viewModel.resultText == "Updated B")
            } else if action == "dismiss" {
                viewModel.dismiss()
            } else {
                viewModel.cancel()
            }
            resumeReplacement?.resume(returning: outcome)
            await pending.value
            started.continuation.finish()

            #expect(replacementWasCancelled)
            #expect(viewModel.lastReplacement == nil)
            #expect(viewModel.replaceStatusMessage == nil)
            #expect(viewModel.error == nil)
        }
    }
}

@Test
@MainActor
func testOldReplacementCompletionCannotReleaseNewSessionReplacement() async {
    let service = ProcessingTestAIService(responses: [.success("Updated A"), .success("Updated B")])
    let started = AsyncStream<Void>.makeStream()
    var continuations: [CheckedContinuation<ReplaceOutcome, Never>] = []
    var replacementCalls = 0
    let viewModel = ProcessingViewModel(
        environment: AppEnvironment(),
        aiServiceProvider: { service },
        replaceAction: { _, _ in
            replacementCalls += 1
            guard replacementCalls <= 2 else { return .failed }
            return await withCheckedContinuation { continuation in
                continuations.append(continuation)
                started.continuation.yield(())
            }
        }
    )
    viewModel.process(module: TranslationModule(), selection: makeProcessingSelection())
    await viewModel.waitForPendingWorkForTesting()
    let old = Task { await viewModel.replaceOriginal() }
    for await _ in started.stream { break }
    viewModel.process(module: TranslationModule(), selection: makeProcessingSelection())
    await viewModel.waitForPendingWorkForTesting()
    let current = Task { await viewModel.replaceOriginal() }
    for await _ in started.stream { break }

    continuations[0].resume(returning: .replaced(.clipboard))
    await old.value
    await viewModel.replaceOriginal()
    #expect(replacementCalls == 2)
    #expect(continuations.count == 2)
    #expect(viewModel.lastReplacement == nil)
    continuations[1].resume(returning: .replaced(.clipboard))
    await current.value
    started.continuation.finish()
    #expect(viewModel.lastReplacement?.replacementText == "Updated B")
}

@Test
@MainActor
func testAutomaticProcessingRetryKeepsFirstSuccessEligible() async {
    let service = ProcessingTestAIService(
        responses: [.failure(ProcessingTestError.failed), .success("Recovered")]
    )
    var replacements: [String] = []
    var events: [AutomaticProcessingEvent] = []
    let viewModel = ProcessingViewModel(
        environment: AppEnvironment(),
        aiServiceProvider: { service },
        replaceAction: { text, _ in
            replacements.append(text)
            return .replaced(.accessibility)
        }
    )
    viewModel.onAutomaticProcessingEvent = { events.append($0) }

    viewModel.process(
        module: TranslationModule(),
        selection: makeProcessingSelection(),
        mode: .automaticReplacement
    )
    await viewModel.waitForPendingWorkForTesting()
    #expect(events.contains(.requiresPresentation))

    viewModel.retry()
    await viewModel.waitForPendingWorkForTesting()
    #expect(events.contains(.succeeded))
    #expect(replacements == ["Recovered"])
}

@Test
@MainActor
func testAutomaticProcessingRefineDoesNotTriggerReplacement() async {
    let service = ProcessingTestAIService(
        responses: [.success("Processed"), .success("Refined")]
    )
    var replacements: [String] = []
    var events: [AutomaticProcessingEvent] = []
    let viewModel = ProcessingViewModel(
        environment: AppEnvironment(),
        aiServiceProvider: { service },
        replaceAction: { text, _ in
            replacements.append(text)
            return .replaced(.accessibility)
        }
    )
    viewModel.onAutomaticProcessingEvent = { events.append($0) }
    viewModel.process(
        module: TranslationModule(),
        selection: makeProcessingSelection(),
        mode: .automaticReplacement
    )
    await viewModel.waitForPendingWorkForTesting()
    #expect(events.contains(.succeeded))

    viewModel.userComment = "Make it shorter"
    viewModel.refine()
    await viewModel.waitForPendingWorkForTesting()
    #expect(viewModel.isStreaming == false && viewModel.resultText == "Refined")
    #expect(replacements == ["Processed"])
    #expect(events.filter { $0 == .succeeded }.count == 1)
}

@Test
@MainActor
func testCancellingAutomaticProcessingPreventsReplacement() async {
    let service = ProcessingTestAIService(
        responses: [.success("Too late")],
        delay: .milliseconds(200)
    )
    var replacements: [String] = []
    let viewModel = ProcessingViewModel(
        environment: AppEnvironment(),
        aiServiceProvider: { service },
        replaceAction: { text, _ in
            replacements.append(text)
            return .replaced(.accessibility)
        }
    )

    viewModel.process(
        module: TranslationModule(),
        selection: makeProcessingSelection(),
        mode: .automaticReplacement
    )
    viewModel.dismiss()

    try? await Task.sleep(for: .milliseconds(300))
    #expect(replacements.isEmpty)
}

@Test
@MainActor
func testReviewProcessingDoesNotReplaceUntilManualAction() async {
    let service = ProcessingTestAIService(responses: [.success("Review me")])
    var replacements: [String] = []
    let viewModel = ProcessingViewModel(
        environment: AppEnvironment(),
        aiServiceProvider: { service },
        replaceAction: { text, _ in
            replacements.append(text)
            return .replaced(.clipboard)
        }
    )

    viewModel.process(
        module: TranslationModule(),
        selection: makeProcessingSelection(),
        mode: .review
    )
    await viewModel.waitForPendingWorkForTesting()
    #expect(viewModel.isStreaming == false && viewModel.resultText == "Review me")
    #expect(replacements.isEmpty)

    await viewModel.replaceOriginal()
    #expect(replacements == ["Review me"])
}

@MainActor
private func makeProcessingSelection() -> TextSelection {
    TextSelection(
        text: "Original",
        cursorPosition: NSPoint(x: 20, y: 20),
        sourceAppPID: 123
    )
}

private enum ProcessingTestError: Error {
    case failed
}

private final class ProcessingTestAIService: AIService, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Response]
    private let delay: Duration

    enum Response {
        case success(String)
        case chunks([String])
        case chunksThenFailure([String])
        case failure(Error)
    }

    init(responses: [Response], delay: Duration = .zero) {
        self.responses = responses
        self.delay = delay
    }

    func stream(request: ChatRequest, config: ResolvedAIConfig) -> AsyncThrowingStream<String, Error> {
        let response = takeResponse()
        let delay = self.delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if delay != .zero {
                        try await Task.sleep(for: delay)
                    }
                    try Task.checkCancellation()
                    switch response {
                    case .success(let text):
                        continuation.yield(text)
                        continuation.finish()
                    case .chunks(let chunks):
                        for chunk in chunks { continuation.yield(chunk) }
                        continuation.finish()
                    case .chunksThenFailure(let chunks):
                        for chunk in chunks { continuation.yield(chunk) }
                        continuation.finish(throwing: ProcessingTestError.failed)
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func takeResponse() -> Response {
        lock.lock()
        defer { lock.unlock() }
        return responses.isEmpty ? .success("") : responses.removeFirst()
    }
}

@Test
@MainActor
func testProcessingFailureFlushesBatchedTextAndRetryStartsFresh() async {
    let scheduler = ManualStreamingTextScheduler()
    let service = ProcessingTestAIService(responses: [
        .chunksThenFailure(["First", " partial"]),
        .chunks(["Second", " response"])
    ])
    let viewModel = ProcessingViewModel(
        environment: AppEnvironment(),
        aiServiceProvider: { service },
        streamingTextScheduler: scheduler
    )
    var firstPublications: [String] = []
    scheduler.onSchedule = { firstPublications.append(viewModel.resultText) }
    viewModel.process(module: TranslationModule(), selection: makeProcessingSelection())
    await viewModel.waitForPendingWorkForTesting()
    #expect(viewModel.resultText == "First partial")
    #expect(viewModel.error != nil)
    viewModel.retry()
    await viewModel.waitForPendingWorkForTesting()
    scheduler.advance(includingCancelled: true)
    #expect(viewModel.resultText == "Second response")
    #expect(firstPublications == ["First", "Second"])
    #expect(viewModel.error == nil)
}

// MARK: - Chat history

@Test
@MainActor
func testProcessingRunIsSavedWithModuleSelectionResultAndRefinement() async throws {
    let service = ProcessingTestAIService(responses: [.success("Processed"), .success("Refined")])
    let viewModel = ProcessingViewModel(environment: AppEnvironment(), aiServiceProvider: { service })

    viewModel.process(module: TranslationModule(), selection: makeProcessingSelection())
    await viewModel.waitForPendingWorkForTesting()
    viewModel.userComment = "Shorter"
    viewModel.refine()
    await viewModel.waitForPendingWorkForTesting()

    #expect(viewModel.historyConversations.count == 1)
    let saved = try #require(viewModel.historyConversations.first)
    #expect(saved.id == viewModel.historyConversation?.id)
    #expect(saved.moduleName == "Translate")
    #expect(saved.title == "Translate: Original")
    #expect(saved.messages.map(\.role) == [.user, .assistant, .user, .assistant])
    #expect(saved.messages.map(\.text) == ["Original", "Processed", "Shorter", "Refined"])
}

@Test
@MainActor
func testAutomaticProcessingRunIsSavedToHistory() async {
    let service = ProcessingTestAIService(responses: [.success("Auto")])
    let viewModel = ProcessingViewModel(
        environment: AppEnvironment(),
        aiServiceProvider: { service },
        replaceAction: { _, _ in .replaced(.accessibility) }
    )

    viewModel.process(module: TranslationModule(), selection: makeProcessingSelection(), mode: .automaticReplacement)
    await viewModel.waitForPendingWorkForTesting()

    #expect(viewModel.historyConversations.first?.messages.map(\.text) == ["Original", "Auto"])
}

@Test
@MainActor
func testDismissingAStreamingRunSavesItOnce() {
    let service = ProcessingTestAIService(responses: [.success("Too late")], delay: .seconds(60))
    let viewModel = ProcessingViewModel(environment: AppEnvironment(), aiServiceProvider: { service })

    viewModel.process(module: TranslationModule(), selection: makeProcessingSelection())
    #expect(viewModel.isStreaming)
    viewModel.dismiss()
    viewModel.dismiss()

    #expect(viewModel.historyConversations.count == 1)
    #expect(viewModel.historyConversations.first?.messages.map(\.text) == ["Original"])
}

@Test
@MainActor
func testFailedProcessingRunSavesTheSelectionOnly() async {
    let service = ProcessingTestAIService(responses: [.failure(ProcessingTestError.failed)])
    let viewModel = ProcessingViewModel(environment: AppEnvironment(), aiServiceProvider: { service })

    viewModel.process(module: TranslationModule(), selection: makeProcessingSelection())
    await viewModel.waitForPendingWorkForTesting()

    #expect(viewModel.error != nil)
    #expect(viewModel.historyConversations.first?.messages.map(\.text) == ["Original"])
}

@Test
@MainActor
func testProcessingOpenChatDismissesBeforeRouting() {
    let viewModel = ProcessingViewModel(environment: AppEnvironment())
    var events: [String] = []
    viewModel.onDismiss = { events.append("dismiss") }
    viewModel.onOpenChat = { target in events.append("route \(target == .newDraft(pendingSelectionText: nil))") }

    viewModel.openChat(.newDraft(pendingSelectionText: nil))

    #expect(events == ["dismiss", "route true"])
}
