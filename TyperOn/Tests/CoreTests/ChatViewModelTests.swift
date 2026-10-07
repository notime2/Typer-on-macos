// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Observation
import Testing
@testable import Typer_On

@Test
@MainActor
func testSelectionContextDoesNotAutoSendAndFirstSubmitUsesHiddenContext() async throws {
    let service = FakeAIService(responses: [.success(["Answer"])])
    let viewModel = makeChatViewModel(service: service)

    viewModel.setPendingSelectionText("Selected context")

    #expect(viewModel.messages.isEmpty)
    #expect(service.recordedRequests().isEmpty)

    viewModel.inputText = "Explain it"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let request = try #require(service.recordedRequests().first)
    #expect(request.messages.count == 3)
    #expect(request.messages[1].role == "system")
    #expect(request.messages[1].content.contains("Selected context"))
    #expect(request.messages[2].role == "user")
    #expect(request.messages[2].content == "Explain it")
    #expect(viewModel.pendingSelectionText == nil)
    #expect(viewModel.conversationContextText == "Selected context")
}

@Test
@MainActor
func testFirstSubmitWithoutSelectionSendsOnlyUserMessage() async throws {
    let service = FakeAIService(responses: [.success(["Answer"])])
    let viewModel = makeChatViewModel(service: service)

    viewModel.inputText = "Hello"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let request = try #require(service.recordedRequests().first)
    #expect(request.messages.count == 2)
    #expect(request.messages[0].role == "system")
    #expect(request.messages[1].role == "user")
    #expect(request.messages[1].content == "Hello")
}

@Test
@MainActor
func testClearingPendingSelectionRemovesContextFromFirstRequest() async throws {
    let service = FakeAIService(responses: [.success(["Answer"])])
    let viewModel = makeChatViewModel(service: service)

    viewModel.setPendingSelectionText("Selected context")
    viewModel.clearPendingSelectionText()
    viewModel.inputText = "Hello"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let request = try #require(service.recordedRequests().first)
    #expect(request.messages.count == 2)
    #expect(viewModel.conversationContextText == nil)
}

@Test
@MainActor
func testFollowUpMessageReusesHiddenContextOnlyOnce() async throws {
    let service = FakeAIService(responses: [.success(["First"]), .success(["Second"])])
    let viewModel = makeChatViewModel(service: service)

    viewModel.setPendingSelectionText("Selected context")
    viewModel.inputText = "Explain it"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    viewModel.inputText = "Add details"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let requests = service.recordedRequests()
    let followUpRequest = try #require(requests.last)
    let contextMessages = followUpRequest.messages.filter { $0.role == "system" && $0.content.contains("Selected context") }

    #expect(requests.count == 2)
    #expect(contextMessages.count == 1)
}

@Test
@MainActor
func testRetryReusesHiddenContextOnlyOnce() async {
    let service = FakeAIService(
        responses: [
            .failure(FakeAIService.TestError.failed),
            .success(["Recovered"])
        ]
    )
    let viewModel = makeChatViewModel(service: service)

    viewModel.setPendingSelectionText("Selected context")
    viewModel.inputText = "Explain it"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    viewModel.retry()
    await viewModel.waitForPendingWorkForTesting()

    let requests = service.recordedRequests()
    #expect(requests.count == 2)

    for request in requests {
        let contextMessages = request.messages.filter { $0.role == "system" && $0.content.contains("Selected context") }
        #expect(contextMessages.count == 1)
    }
}

@Test
@MainActor
func testChatViewModelUsesChatModeSettingsAndPromptOverride() async throws {
    let service = FakeAIService(responses: [.success(["Answer"])])
    let config = ResolvedAIConfig(
        apiKey: "key",
        model: "custom-chat-model",
        temperature: 0.2,
        maxTokens: 4096
    )
    let moduleConfig = ModuleAIConfig(
        useGlobal: false,
        customModel: "custom-chat-model",
        customSystemPrompt: "OVERRIDE PROMPT",
        outputLanguageMode: .sourceLanguage
    )
    let viewModel = makeChatViewModel(
        service: service,
        resolvedAIConfig: config,
        moduleConfig: moduleConfig
    )

    viewModel.inputText = "Hola"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let request = try #require(service.recordedRequests().first)
    #expect(request.model == "custom-chat-model")
    #expect(request.messages.first?.content == "OVERRIDE PROMPT")
}

@Test
@MainActor
func testCopyMessageFeedbackTransitionsFromIdleToCopiedAndBack() {
    let scheduler = ManualStreamingTextScheduler()
    let viewModel = makeChatViewModel(service: FakeAIService(responses: []), feedbackScheduler: scheduler)
    let message = ChatConversationMessage(role: .assistant, text: "Answer")
    #expect(viewModel.copyFeedbackState(for: message) == .idle)
    viewModel.copyMessage(message)
    #expect(viewModel.copyFeedbackState(for: message) == .copied)
    #expect(scheduler.delays == [1])
    scheduler.advance()
    #expect(viewModel.copyFeedbackState(for: message) == .idle)
}

@Test
@MainActor
func testCopyingAnotherMessageMovesCopiedStateToLatestMessage() {
    let scheduler = ManualStreamingTextScheduler()
    let viewModel = makeChatViewModel(service: FakeAIService(responses: []), feedbackScheduler: scheduler)
    let first = ChatConversationMessage(role: .assistant, text: "First")
    let second = ChatConversationMessage(role: .assistant, text: "Second")
    viewModel.copyMessage(first)
    viewModel.copyMessage(second)
    #expect(viewModel.copyFeedbackState(for: first) == .idle)
    #expect(viewModel.copyFeedbackState(for: second) == .copied)
    scheduler.advanceNext(includingCancelled: true)
    #expect(viewModel.copyFeedbackState(for: second) == .copied)
    scheduler.advanceNext()
    #expect(viewModel.copyFeedbackState(for: second) == .idle)
}

@Test
@MainActor
func testRepeatedCopyAndResetRejectCancelledFeedbackCallbacks() {
    let scheduler = ManualStreamingTextScheduler()
    let viewModel = makeChatViewModel(service: FakeAIService(responses: []), feedbackScheduler: scheduler)
    let message = ChatConversationMessage(role: .assistant, text: "Answer")
    viewModel.copyMessage(message)
    viewModel.copyMessage(message)
    scheduler.advanceNext(includingCancelled: true)
    #expect(viewModel.copyFeedbackState(for: message) == .copied)
    viewModel.reset()
    viewModel.copyMessage(message)
    scheduler.advanceNext(includingCancelled: true)
    #expect(viewModel.copyFeedbackState(for: message) == .copied)
    scheduler.advanceNext()
    #expect(viewModel.copyFeedbackState(for: message) == .idle)
}

@Test
@MainActor
func testScreenshotCapabilityGateRequiresExplicitImageInput() async {
    let service = FakeAIService(responses: [])
    let visionModel = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let textModel = makeTestModel(id: "vendor/text", input: ["text"])

    let visionViewModel = makeChatViewModel(
        service: service,
        resolvedAIConfig: makeResolvedConfig(model: visionModel.id),
        models: [visionModel.id: visionModel]
    )
    await visionViewModel.refreshActiveModelCapabilities()

    let textCapturer = FakeScreenshotCapturer(outcomes: [.success(testCapturedScreenshot)])
    let textViewModel = makeChatViewModel(
        service: service,
        resolvedAIConfig: makeResolvedConfig(model: textModel.id),
        screenshotCapturer: textCapturer,
        models: [textModel.id: textModel]
    )
    await textViewModel.refreshActiveModelCapabilities()
    textViewModel.captureScreenshot(mode: .area)

    let unknownViewModel = makeChatViewModel(
        service: service,
        resolvedAIConfig: makeResolvedConfig(model: "vendor/unknown")
    )
    await unknownViewModel.refreshActiveModelCapabilities()

    #expect(visionViewModel.canCaptureScreenshot)
    #expect(!textViewModel.canCaptureScreenshot)
    #expect(textCapturer.captureCallCount == 0)
    #expect(!unknownViewModel.canCaptureScreenshot)
}

@Test
@MainActor
func testLocalEndpointModelWithoutModalityMetadataHidesCaptureAndStaysOnChatCompletions() async {
    // A local OpenAI-compatible server lists IDs only, so the catalog entry has no architecture.
    let localModel = OpenRouterModel(id: "gemma4:e2b-mlx", name: "gemma4:e2b-mlx", context_length: nil)
    #expect(!localModel.hasCompleteModalityMetadata)

    let service = FakeAIService(responses: [.success(["OK"])])
    let capturer = FakeScreenshotCapturer(outcomes: [.success(testCapturedScreenshot)])
    let viewModel = makeChatViewModel(
        service: service,
        resolvedAIConfig: makeResolvedConfig(model: localModel.id),
        screenshotCapturer: capturer,
        models: [localModel.id: localModel]
    )
    await viewModel.refreshActiveModelCapabilities()

    #expect(!viewModel.canCaptureScreenshot)
    viewModel.captureScreenshot(mode: .area)
    #expect(capturer.captureCallCount == 0)
    #expect(viewModel.pendingScreenshot == nil)

    viewModel.inputText = "hello"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    #expect(viewModel.messages.last?.text == "OK")
    #expect(service.recordedRequests().count == 1)
    #expect(service.recordedImageRequests().isEmpty)
}

@Test
@MainActor
func testBothCaptureModesRevalidateImageCapabilityBeforeStarting() async {
    let modelID = "vendor/changing"
    let visionModel = makeTestModel(id: modelID, input: ["text", "image"])
    let textModel = makeTestModel(id: modelID, input: ["text"])

    for mode in [ScreenshotCaptureMode.area, .windowOrDisplay] {
        let resolver = SequencedModelResolver(responses: [
            .init(delayMilliseconds: 0, model: visionModel),
            .init(delayMilliseconds: 0, model: textModel)
        ])
        let capturer = FakeScreenshotCapturer(outcomes: [.success(testCapturedScreenshot)])
        let viewModel = makeChatViewModel(
            service: FakeAIService(responses: []),
            resolvedAIConfig: makeResolvedConfig(model: modelID),
            screenshotCapturer: capturer,
            modelResolver: { _, _ in await resolver.resolve() }
        )
        await viewModel.refreshActiveModelCapabilities()
        #expect(viewModel.canCaptureScreenshot)

        viewModel.captureScreenshot(mode: mode)
        await viewModel.waitForPendingCaptureForTesting()

        #expect(capturer.captureCallCount == 0)
        #expect(viewModel.pendingScreenshot == nil)
        #expect(viewModel.captureError?.contains("does not support image input") == true)
    }
}

@Test
@MainActor
func testScreenshotCaptureKeepsInitiatingWindowDuringModelRevalidation() async {
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let resolver = ControlledSecondModelResolver(model: model)
    let initiatingWindow = FakeChatCaptureWindow(
        windowNumber: 101,
        isVisible: true,
        isKey: true
    )
    let laterKeyWindow = FakeChatCaptureWindow(
        windowNumber: 202,
        isVisible: true,
        isKey: false
    )
    let windowBox = ScreenshotWindowBox(initiatingWindow)
    let windowEnvironment = MutableScreenshotCaptureWindowEnvironment(windowBox: windowBox)
    var capturedWindowNumber: Int?
    let capturer = ScreenshotCaptureService(
        windowEnvironment: windowEnvironment,
        captureImageOverride: { _, windowNumber in
            capturedWindowNumber = windowNumber
            return nil
        }
    )
    let viewModel = makeChatViewModel(
        service: FakeAIService(responses: []),
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        screenshotCapturer: capturer,
        screenshotWindowProvider: { windowBox.window },
        modelResolver: { _, _ in await resolver.resolve() }
    )
    await viewModel.refreshActiveModelCapabilities()
    #expect(viewModel.canCaptureScreenshot)

    viewModel.captureScreenshot(mode: .area)
    await resolver.waitUntilSecondCallStarts()

    initiatingWindow.screenshotIsKeyWindow = false
    laterKeyWindow.screenshotIsKeyWindow = true
    windowBox.window = laterKeyWindow
    await resolver.releaseSecond()
    await viewModel.waitForPendingCaptureForTesting()

    #expect(capturedWindowNumber == initiatingWindow.screenshotWindowNumber)
    #expect(initiatingWindow.hideCount == 1)
    #expect(initiatingWindow.makeKeyAndOrderFrontCount == 1)
    #expect(laterKeyWindow.hideCount == 0)
    #expect(laterKeyWindow.makeKeyAndOrderFrontCount == 0)
}

@Test
@MainActor
func testScreenshotCaptureSuccessCreatesPNGAttachmentAndBlocksParallelCapture() async throws {
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let capturer = FakeScreenshotCapturer(
        outcomes: [.success(testCapturedScreenshot)],
        delayMilliseconds: 80
    )
    let viewModel = makeChatViewModel(
        service: FakeAIService(responses: []),
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        screenshotCapturer: capturer,
        models: [model.id: model]
    )
    await viewModel.refreshActiveModelCapabilities()
    let focusRequestID = viewModel.inputFocusRequestID

    viewModel.captureScreenshot(mode: .area)
    viewModel.captureScreenshot(mode: .area)
    await viewModel.waitForPendingCaptureForTesting()

    let attachment = try #require(viewModel.pendingScreenshot)
    #expect(capturer.captureCallCount == 1)
    #expect(capturer.capturedModes == [.area])
    #expect(attachment.data == testCapturedScreenshot.pngData)
    #expect(attachment.mimeType == "image/png")
    #expect(attachment.pixelWidth == 320)
    #expect(attachment.pixelHeight == 180)
    #expect(viewModel.inputFocusRequestID != focusRequestID)
}

@Test
@MainActor
func testWindowOrDisplayCaptureModeIsForwarded() async {
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let capturer = FakeScreenshotCapturer(outcomes: [.success(nil)])
    let viewModel = makeChatViewModel(
        service: FakeAIService(responses: []),
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        screenshotCapturer: capturer,
        models: [model.id: model]
    )
    await viewModel.refreshActiveModelCapabilities()

    viewModel.captureScreenshot(mode: .windowOrDisplay)
    await viewModel.waitForPendingCaptureForTesting()

    #expect(capturer.capturedModes == [.windowOrDisplay])
}

@Test
@MainActor
func testScreenshotReplacementCancelAndFailurePreserveExistingState() async throws {
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let replacementScreenshot = CapturedScreenshot(
        pngData: Data([1, 2, 3, 4]),
        pixelWidth: 640,
        pixelHeight: 360
    )
    let capturer = FakeScreenshotCapturer(outcomes: [
        .success(testCapturedScreenshot),
        .success(replacementScreenshot),
        .success(nil),
        .failure(.captureFailed("Picker failed"))
    ])
    let viewModel = makeChatViewModel(
        service: FakeAIService(responses: []),
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        screenshotCapturer: capturer,
        models: [model.id: model]
    )
    await viewModel.refreshActiveModelCapabilities()

    viewModel.captureScreenshot(mode: .area)
    await viewModel.waitForPendingCaptureForTesting()

    viewModel.captureScreenshot(mode: .area)
    await viewModel.waitForPendingCaptureForTesting()
    let replacementAttachment = try #require(viewModel.pendingScreenshot)
    #expect(replacementAttachment.data == replacementScreenshot.pngData)
    #expect(replacementAttachment.pixelWidth == 640)
    #expect(replacementAttachment.pixelHeight == 360)

    viewModel.inputText = "Keep this prompt"
    viewModel.setPendingSelectionText("Keep this selection")
    viewModel.conversationContextText = "Keep conversation context"
    let existingMessages = [
        ChatConversationMessage(role: .user, text: "Keep user message"),
        ChatConversationMessage(role: .assistant, text: "Keep assistant message")
    ]
    viewModel.messages = existingMessages

    viewModel.captureScreenshot(mode: .area)
    await viewModel.waitForPendingCaptureForTesting()

    #expect(viewModel.pendingScreenshot == replacementAttachment)
    #expect(viewModel.captureError == nil)
    #expect(viewModel.messages.map(\.id) == existingMessages.map(\.id))
    #expect(viewModel.messages.map(\.text) == existingMessages.map(\.text))
    #expect(viewModel.conversationContextText == "Keep conversation context")

    viewModel.captureScreenshot(mode: .area)
    await viewModel.waitForPendingCaptureForTesting()

    #expect(viewModel.pendingScreenshot == replacementAttachment)
    #expect(viewModel.inputText == "Keep this prompt")
    #expect(viewModel.pendingSelectionText == "Keep this selection")
    #expect(viewModel.conversationContextText == "Keep conversation context")
    #expect(viewModel.messages.map(\.id) == existingMessages.map(\.id))
    #expect(viewModel.messages.map(\.text) == existingMessages.map(\.text))
    #expect(viewModel.captureError?.contains("Picker failed") == true)
}

@Test
@MainActor
func testScreenshotAloneCannotSendWithoutNonWhitespacePrompt() async {
    let service = FakeAIService(responses: [.success(["Unused"])])
    let viewModel = makeChatViewModel(service: service)
    let attachment = makeTestAttachment()
    viewModel.pendingScreenshot = attachment
    viewModel.inputText = "  \n  "

    viewModel.sendMessage()
    await Task.yield()

    #expect(viewModel.messages.isEmpty)
    #expect(viewModel.pendingScreenshot == attachment)
    #expect(viewModel.inputText == "  \n  ")
    #expect(service.recordedRequests().isEmpty)
    #expect(!viewModel.isPreparingSend)
}

@Test
@MainActor
func testSendMovesScreenshotIntoUserMessageAndKeepsSelectionContext() async throws {
    let service = FakeAIService(responses: [.success(["Answer"])])
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let capturer = FakeScreenshotCapturer(outcomes: [.success(testCapturedScreenshot)])
    let viewModel = makeChatViewModel(
        service: service,
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        screenshotCapturer: capturer,
        models: [model.id: model]
    )
    await viewModel.refreshActiveModelCapabilities()
    viewModel.captureScreenshot(mode: .area)
    await viewModel.waitForPendingCaptureForTesting()
    let submittedAttachment = try #require(viewModel.pendingScreenshot)

    viewModel.setPendingSelectionText("Selected context")
    viewModel.inputText = "Describe the screenshot"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let userMessage = try #require(viewModel.messages.first)
    let request = try #require(service.recordedRequests().first)
    let apiUserMessage = try #require(request.messages.first(where: { $0.role == "user" }))

    #expect(userMessage.role == .user)
    #expect(userMessage.text == "Describe the screenshot")
    #expect(userMessage.images == [submittedAttachment])
    #expect(viewModel.pendingScreenshot == nil)
    #expect(viewModel.pendingSelectionText == nil)
    #expect(viewModel.conversationContextText == "Selected context")
    #expect(apiUserMessage.content == "Describe the screenshot")
    #expect(apiUserMessage.imageURLs == [submittedAttachment.dataURL])
    #expect(request.messages.contains {
        $0.role == "system" && $0.content.contains("Selected context")
    })
}

@Test
@MainActor
func testClearPendingScreenshotDoesNotClearPromptOrSelection() {
    let viewModel = makeChatViewModel(service: FakeAIService(responses: []))
    viewModel.inputText = "Keep prompt"
    viewModel.setPendingSelectionText("Keep context")
    viewModel.pendingScreenshot = makeTestAttachment()
    viewModel.captureError = "Old capture error"
    let focusRequestID = viewModel.inputFocusRequestID

    viewModel.clearPendingScreenshot()

    #expect(viewModel.pendingScreenshot == nil)
    #expect(viewModel.captureError == nil)
    #expect(viewModel.inputText == "Keep prompt")
    #expect(viewModel.pendingSelectionText == "Keep context")
    #expect(viewModel.inputFocusRequestID != focusRequestID)
}

@Test
@MainActor
func testResetClearsPendingAndHistoricalImageStateAndCancelsCapture() async {
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let capturer = FakeScreenshotCapturer(
        outcomes: [.success(testCapturedScreenshot)],
        delayMilliseconds: 5_000
    )
    let viewModel = makeChatViewModel(
        service: FakeAIService(responses: []),
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        screenshotCapturer: capturer,
        models: [model.id: model]
    )
    await viewModel.refreshActiveModelCapabilities()
    viewModel.messages = [
        ChatConversationMessage(role: .user, text: "Old", images: [makeTestAttachment()]),
        ChatConversationMessage(role: .assistant, images: [makeTestAttachment(data: Data([9]))])
    ]
    viewModel.pendingScreenshot = makeTestAttachment(data: Data([8]))
    viewModel.captureScreenshot(mode: .area)
    await capturer.waitUntilCaptureStarts()

    viewModel.reset()
    await viewModel.waitForPendingCaptureForTesting()

    #expect(viewModel.messages.isEmpty)
    #expect(viewModel.pendingScreenshot == nil)
    #expect(!viewModel.isCapturingScreenshot)
    #expect(!viewModel.isStreaming)
    #expect(capturer.cancellationCount == 1)
}

@Test
@MainActor
func testDismissCancelsCaptureAndPreservesSessionState() async {
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let capturer = FakeScreenshotCapturer(
        outcomes: [.success(testCapturedScreenshot)],
        delayMilliseconds: 5_000
    )
    let viewModel = makeChatViewModel(
        service: FakeAIService(responses: []),
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        screenshotCapturer: capturer,
        models: [model.id: model]
    )
    await viewModel.refreshActiveModelCapabilities()
    let existingAttachment = makeTestAttachment(data: Data([7]))
    viewModel.pendingScreenshot = existingAttachment
    viewModel.inputText = "Keep prompt"
    viewModel.pendingSelectionText = "Keep pending selection"
    viewModel.conversationContextText = "Keep conversation context"
    let existingMessages = [ChatConversationMessage(role: .assistant, text: "Keep message")]
    viewModel.messages = existingMessages
    var didDismiss = false
    viewModel.onDismiss = { didDismiss = true }

    viewModel.captureScreenshot(mode: .area)
    await capturer.waitUntilCaptureStarts()
    viewModel.dismiss()
    await viewModel.waitForPendingCaptureForTesting()

    #expect(didDismiss)
    #expect(!viewModel.isCapturingScreenshot)
    #expect(viewModel.pendingScreenshot == existingAttachment)
    #expect(viewModel.inputText == "Keep prompt")
    #expect(viewModel.pendingSelectionText == "Keep pending selection")
    #expect(viewModel.conversationContextText == "Keep conversation context")
    #expect(viewModel.messages.map(\.id) == existingMessages.map(\.id))
    #expect(viewModel.messages.map(\.text) == existingMessages.map(\.text))
    #expect(capturer.cancellationCount == 1)
}

@Test
@MainActor
func testResetThenImmediateCaptureWaitsForNonCooperativeCleanup() async throws {
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let capturer = NonCooperativeScreenshotCapturer()
    let cleanupProbe = CaptureCleanupBarrierProbe()
    let viewModel = makeChatViewModel(
        service: FakeAIService(responses: []),
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        screenshotCapturer: capturer,
        captureCleanupBarrierObserver: { cleanupProbe.enter() },
        models: [model.id: model]
    )
    await viewModel.refreshActiveModelCapabilities()
    viewModel.pendingScreenshot = makeTestAttachment(data: Data([8]))

    viewModel.captureScreenshot(mode: .area)
    await capturer.waitUntilFirstCaptureStarts()
    viewModel.reset()

    #expect(!viewModel.isCapturingScreenshot)
    #expect(viewModel.pendingScreenshot == nil)

    viewModel.captureScreenshot(mode: .area)
    await cleanupProbe.waitUntilEntered()

    #expect(viewModel.isCapturingScreenshot)
    #expect(capturer.captureCallCount == 1)
    #expect(capturer.prematureOverlapCount == 0)
    #expect(viewModel.captureError == nil)

    capturer.releaseFirstCapture()
    await capturer.waitUntilSecondCaptureStarts()
    await waitUntilScreenshotCaptureFinishes(viewModel)

    let attachment = try #require(viewModel.pendingScreenshot)
    #expect(attachment.data == testCapturedScreenshot.pngData)
    #expect(capturer.captureCallCount == 2)
    #expect(capturer.prematureOverlapCount == 0)
    #expect(viewModel.captureError == nil)
}

@Test
@MainActor
func testDismissThenImmediateCaptureWaitsForNonCooperativeCleanup() async throws {
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let capturer = NonCooperativeScreenshotCapturer()
    let cleanupProbe = CaptureCleanupBarrierProbe()
    let viewModel = makeChatViewModel(
        service: FakeAIService(responses: []),
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        screenshotCapturer: capturer,
        captureCleanupBarrierObserver: { cleanupProbe.enter() },
        models: [model.id: model]
    )
    await viewModel.refreshActiveModelCapabilities()
    let existingAttachment = makeTestAttachment(data: Data([7]))
    let existingMessages = [ChatConversationMessage(role: .assistant, text: "Keep message")]
    viewModel.pendingScreenshot = existingAttachment
    viewModel.inputText = "Keep prompt"
    viewModel.pendingSelectionText = "Keep pending selection"
    viewModel.messages = existingMessages
    var didDismiss = false
    viewModel.onDismiss = { didDismiss = true }

    viewModel.captureScreenshot(mode: .area)
    await capturer.waitUntilFirstCaptureStarts()
    viewModel.dismiss()

    #expect(didDismiss)
    #expect(!viewModel.isCapturingScreenshot)
    #expect(viewModel.pendingScreenshot == existingAttachment)

    viewModel.captureScreenshot(mode: .windowOrDisplay)
    await cleanupProbe.waitUntilEntered()

    #expect(viewModel.isCapturingScreenshot)
    #expect(capturer.captureCallCount == 1)
    #expect(capturer.prematureOverlapCount == 0)
    #expect(viewModel.captureError == nil)

    capturer.releaseFirstCapture()
    await capturer.waitUntilSecondCaptureStarts()
    await waitUntilScreenshotCaptureFinishes(viewModel)

    let attachment = try #require(viewModel.pendingScreenshot)
    #expect(attachment.data == testCapturedScreenshot.pngData)
    #expect(viewModel.inputText == "Keep prompt")
    #expect(viewModel.pendingSelectionText == "Keep pending selection")
    #expect(viewModel.messages.map(\.id) == existingMessages.map(\.id))
    #expect(capturer.capturedModes == [.area, .windowOrDisplay])
    #expect(capturer.captureCallCount == 2)
    #expect(capturer.prematureOverlapCount == 0)
    #expect(viewModel.captureError == nil)
}

@Test
@MainActor
func testChatStreamKeepsMixedImagePartsAndDeduplicatesPayloads() async throws {
    let imageData = Data([1, 2, 3])
    let service = FakeAIService(responses: [
        .events([
            .text("Caption"),
            .image(data: imageData, mimeType: "image/png"),
            .image(data: imageData, mimeType: "image/png"),
            .invalidImage
        ])
    ])
    let viewModel = makeChatViewModel(service: service)
    viewModel.inputText = "Generate"

    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let assistantMessage = try #require(viewModel.messages.last)
    #expect(assistantMessage.role == .assistant)
    #expect(assistantMessage.text == "Caption")
    #expect(assistantMessage.images.count == 1)
    #expect(assistantMessage.images.first?.data == imageData)
    #expect(assistantMessage.invalidImageCount == 1)
    #expect(service.recordedImageRequests().isEmpty)
}

@Test
@MainActor
func testImageOnlyChatCompletionClearsStreamingState() async throws {
    let imageData = Data([4, 5, 6])
    let service = FakeAIService(responses: [
        .events([.image(data: imageData, mimeType: "image/webp")])
    ])
    let viewModel = makeChatViewModel(service: service)
    viewModel.inputText = "Show an image"

    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let assistantMessage = try #require(viewModel.messages.last)
    #expect(assistantMessage.text.isEmpty)
    #expect(assistantMessage.images.count == 1)
    #expect(assistantMessage.images.first?.data == imageData)
    #expect(!viewModel.isStreaming)
}

@Test
@MainActor
func testImageOutputModelRoutesToImagesAPIAndReusesLatestScreenshot() async throws {
    let service = FakeAIService(
        responses: [.success(["Chat fallback must not run"])],
        imageResponses: [
            .success(ImageGenerationResult(images: [
                GeneratedImage(data: Data([7, 8]), mimeType: "image/png")
            ], invalidImageCount: 2)),
            .success(ImageGenerationResult(images: [
                GeneratedImage(data: Data([9, 10]), mimeType: "image/jpeg")
            ]))
        ]
    )
    let model = makeTestModel(
        id: "vendor/image-output",
        input: ["text", "image"],
        output: ["text", "image"]
    )
    let viewModel = makeChatViewModel(
        service: service,
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        models: [model.id: model]
    )
    let screenshot = makeTestAttachment()
    viewModel.pendingScreenshot = screenshot
    viewModel.inputText = "Generate a variation"

    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    viewModel.inputText = "Make it brighter"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let imageRequests = service.recordedImageRequests()
    let firstRequest = try #require(imageRequests.first)
    let secondRequest = try #require(imageRequests.last)
    let firstAssistant = try #require(viewModel.messages.first(where: { $0.role == .assistant }))
    #expect(service.recordedRequests().isEmpty)
    #expect(firstRequest.model == model.id)
    #expect(firstRequest.prompt.contains("Generate a variation"))
    #expect(firstRequest.inputReferences?.map(\.imageURL) == [screenshot.dataURL])
    #expect(secondRequest.prompt.contains("Make it brighter"))
    #expect(secondRequest.inputReferences?.map(\.imageURL) == [screenshot.dataURL])
    #expect(firstAssistant.invalidImageCount == 2)
    #expect(viewModel.messages.last?.images.first?.data == Data([9, 10]))
}

@Test
@MainActor
func testImagesAPIErrorDoesNotFallBackToChatOrRemoveSentScreenshot() async throws {
    let service = FakeAIService(
        responses: [.success(["Unexpected fallback"])],
        imageResponses: [.failure(FakeAIService.TestError.failed)]
    )
    let model = makeTestModel(
        id: "vendor/image-output",
        input: ["text", "image"],
        output: ["image"]
    )
    let viewModel = makeChatViewModel(
        service: service,
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        models: [model.id: model]
    )
    let screenshot = makeTestAttachment()
    viewModel.pendingScreenshot = screenshot
    viewModel.inputText = "Generate"

    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let userMessage = try #require(viewModel.messages.first)
    #expect(service.recordedRequests().isEmpty)
    #expect(userMessage.images == [screenshot])
    #expect(viewModel.error != nil)
    #expect(viewModel.isErrorRetryable)
}

@Test
@MainActor
func testRetryReusesOriginalScreenshotWithoutDuplicatingUserMessage() async throws {
    let service = FakeAIService(responses: [
        .failure(FakeAIService.TestError.failed),
        .success(["Recovered"])
    ])
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let screenshot = makeTestAttachment()
    let viewModel = makeChatViewModel(
        service: service,
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        models: [model.id: model]
    )
    viewModel.pendingScreenshot = screenshot
    viewModel.inputText = "Describe"

    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()
    viewModel.retry()
    await viewModel.waitForPendingWorkForTesting()

    let requests = service.recordedRequests()
    #expect(requests.allSatisfy {
        $0.messages.filter { $0.role == "user" }.flatMap(\.imageURLs) == [screenshot.dataURL]
    })
    #expect(viewModel.messages.filter { $0.role == .user }.count == 1)
    #expect(viewModel.messages.filter { $0.role == .user }.flatMap(\.images) == [screenshot])
    #expect(viewModel.messages.last?.text == "Recovered")
}

@Test
@MainActor
func testStreamErrorPreservesPartialResponseAndSentScreenshot() async throws {
    let responseImageData = Data([7, 8, 9])
    let service = FakeAIService(responses: [
        .eventsThenFailure(
            [
                .text("Partial"),
                .image(data: responseImageData, mimeType: "image/png")
            ],
            FakeAIService.TestError.failed
        )
    ])
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let screenshot = makeTestAttachment()
    let viewModel = makeChatViewModel(
        service: service,
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        models: [model.id: model]
    )
    viewModel.pendingScreenshot = screenshot
    viewModel.inputText = "Inspect"

    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let userMessage = try #require(viewModel.messages.first)
    let assistantMessage = try #require(viewModel.messages.last)
    #expect(viewModel.messages.filter { $0.role == .user }.count == 1)
    #expect(userMessage.images == [screenshot])
    #expect(assistantMessage.text == "Partial")
    #expect(assistantMessage.images.first?.data == responseImageData)
    #expect(viewModel.isErrorRetryable)
}

@Test
@MainActor
func testStopPreservesPartialTextImagesAndSentScreenshot() async throws {
    let scheduler = ManualStreamingTextScheduler()
    let responseImageData = Data([4, 5, 6])
    let service = HoldingAIService(events: [
        .text("Par"),
        .text("tial"),
        .image(data: responseImageData, mimeType: "image/png")
    ])
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let screenshot = makeTestAttachment()
    let viewModel = ChatViewModel(
        environment: AppEnvironment(),
        aiServiceProvider: { service },
        resolvedAIConfigProvider: { _ in makeResolvedConfig(model: model.id) },
        moduleAIConfigProvider: { _ in nil },
        defaultTargetLanguageProvider: { "Russian" },
        screenshotCapturer: FakeScreenshotCapturer(outcomes: []),
        cachedModelProvider: { _ in model },
        modelResolver: { _, _ in model },
        configuredModelIDProvider: { model.id },
        streamingTextScheduler: scheduler
    )
    viewModel.pendingScreenshot = screenshot
    viewModel.inputText = "Inspect"

    viewModel.sendMessage()
    await waitUntilObserved {
        viewModel.messages.last?.images.first?.data == responseImageData
            && viewModel.isStreaming
    }
    #expect(viewModel.messages.last?.text == "Par")
    viewModel.stopStreaming()
    scheduler.advance(includingCancelled: true)

    let userMessage = try #require(viewModel.messages.first)
    let assistantMessage = try #require(viewModel.messages.last)
    #expect(!viewModel.isStreaming)
    #expect(userMessage.images == [screenshot])
    #expect(assistantMessage.text == "Partial")
    #expect(assistantMessage.images.first?.data == responseImageData)
}

@Test
@MainActor
func testFollowUpChatRequestPreservesHistoricalScreenshotExactlyOnce() async throws {
    let service = FakeAIService(responses: [
        .success(["First answer"]),
        .success(["Second answer"])
    ])
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let viewModel = makeChatViewModel(
        service: service,
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        models: [model.id: model]
    )
    let screenshot = makeTestAttachment()
    viewModel.pendingScreenshot = screenshot
    viewModel.inputText = "First prompt"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    viewModel.inputText = "Follow-up"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let followUpRequest = try #require(service.recordedRequests().last)
    let userMessages = followUpRequest.messages.filter { $0.role == "user" }
    let firstUserMessage = try #require(userMessages.first)
    let secondUserMessage = try #require(userMessages.last)
    #expect(userMessages.count == 2)
    #expect(firstUserMessage.imageURLs == [screenshot.dataURL])
    #expect(secondUserMessage.imageURLs.isEmpty)
    #expect(userMessages.flatMap(\.imageURLs).count == 1)
    #expect(viewModel.messages.filter { $0.role == .user }.flatMap(\.images).count == 1)
}

@Test
@MainActor
func testFollowUpIsBlockedWhenPriorScreenshotModelChangesToTextOnly() async {
    let service = FakeAIService(responses: [
        .success(["First answer"]),
        .success(["Unexpected follow-up"])
    ])
    let visionModel = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let textModel = makeTestModel(id: "vendor/text", input: ["text"])
    let configBox = TestResolvedConfigBox(makeResolvedConfig(model: visionModel.id))
    let viewModel = makeChatViewModel(
        service: service,
        configProvider: { configBox.value },
        models: [visionModel.id: visionModel, textModel.id: textModel]
    )
    viewModel.pendingScreenshot = makeTestAttachment()
    viewModel.inputText = "First prompt"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()
    let messageCount = viewModel.messages.count

    configBox.value = makeResolvedConfig(model: textModel.id)
    viewModel.inputText = "Follow-up"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    #expect(service.recordedRequests().count == 1)
    #expect(viewModel.messages.count == messageCount)
    #expect(viewModel.inputText == "Follow-up")
    #expect(viewModel.captureError?.contains("screenshot in this conversation") == true)
}

@Test
@MainActor
func testTextOnlySendAndRetryDoNotWaitForModelMetadataResolution() async {
    let service = FakeAIService(responses: [.success(["Answer"]), .success(["Retried"])])
    let resolver = TestModelResolver(
        models: [:],
        delayMilliseconds: ["vendor/unknown": 2_000]
    )
    let viewModel = makeChatViewModel(
        service: service,
        resolvedAIConfig: makeResolvedConfig(model: "vendor/unknown"),
        modelResolver: { modelID, _ in
            await resolver.resolve(modelID)
        }
    )

    viewModel.inputText = "Text only"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let resolverCallCount = await resolver.callCount
    #expect(resolverCallCount == 0)
    #expect(service.recordedImageRequests().isEmpty)

    viewModel.retry()
    await viewModel.waitForPendingWorkForTesting()

    let retryResolverCallCount = await resolver.callCount
    #expect(retryResolverCallCount == 0)
}

@Test
@MainActor
func testCapabilityInvalidationHidesScreenshotActionImmediately() async {
    let model = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let viewModel = makeChatViewModel(
        service: FakeAIService(responses: []),
        resolvedAIConfig: makeResolvedConfig(model: model.id),
        models: [model.id: model]
    )
    await viewModel.refreshActiveModelCapabilities()
    #expect(viewModel.canCaptureScreenshot)

    viewModel.invalidateActiveModelCapabilities()

    #expect(!viewModel.canCaptureScreenshot)
    #expect(viewModel.configuredModelID == nil)
}

@Test
@MainActor
func testScreenshotCapabilityRejectsStaleConfiguredModelWithoutFullResolution() async {
    let visionModel = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let configuredModelBox = TestModelIDBox(visionModel.id)
    let resolver = TestModelResolver(models: [visionModel.id: visionModel], delayMilliseconds: [:])
    let viewModel = makeChatViewModel(
        service: FakeAIService(responses: []),
        resolvedAIConfig: makeResolvedConfig(model: visionModel.id),
        models: [visionModel.id: visionModel],
        modelResolver: { modelID, _ in
            await resolver.resolve(modelID)
        },
        configuredModelIDProvider: { configuredModelBox.value }
    )
    await viewModel.refreshActiveModelCapabilities()
    #expect(viewModel.canCaptureScreenshot)
    let resolutionCount = await resolver.callCount

    configuredModelBox.value = "vendor/text"

    let unchangedResolutionCount = await resolver.callCount
    #expect(!viewModel.canCaptureScreenshot)
    #expect(unchangedResolutionCount == resolutionCount)
}

@Test
@MainActor
func testLateCapabilityRefreshCannotOverwriteCurrentModel() async {
    let visionModel = makeTestModel(id: "vendor/vision", input: ["text", "image"])
    let textModel = makeTestModel(id: "vendor/text", input: ["text"])
    let configBox = TestResolvedConfigBox(makeResolvedConfig(model: visionModel.id))
    let resolver = TestModelResolver(
        models: [visionModel.id: visionModel, textModel.id: textModel],
        delayMilliseconds: [visionModel.id: 150, textModel.id: 10]
    )
    let viewModel = makeChatViewModel(
        service: FakeAIService(responses: []),
        configProvider: { configBox.value },
        modelResolver: { modelID, _ in
            await resolver.resolve(modelID)
        }
    )

    let firstRefresh = Task { await viewModel.refreshActiveModelCapabilities() }
    try? await Task.sleep(for: .milliseconds(25))
    configBox.value = makeResolvedConfig(model: textModel.id)
    let secondRefresh = Task { await viewModel.refreshActiveModelCapabilities() }

    _ = await secondRefresh.value
    _ = await firstRefresh.value

    #expect(viewModel.configuredModelID == textModel.id)
    #expect(viewModel.activeModelID == textModel.id)
    #expect(viewModel.activeModel?.id == textModel.id)
    #expect(!viewModel.canCaptureScreenshot)
}

@Test
@MainActor
func testOlderSameModelCapabilityRefreshCannotOverrideNewerResult() async {
    let modelID = "vendor/changing"
    let staleVisionModel = makeTestModel(id: modelID, input: ["text", "image"])
    let currentTextModel = makeTestModel(id: modelID, input: ["text"])
    let resolver = ControlledFirstModelResolver(
        firstModel: staleVisionModel,
        secondModel: currentTextModel
    )
    let viewModel = makeChatViewModel(
        service: FakeAIService(responses: []),
        resolvedAIConfig: makeResolvedConfig(model: modelID),
        modelResolver: { _, _ in
            await resolver.resolve()
        }
    )

    let firstRefresh = Task { await viewModel.refreshActiveModelCapabilities() }
    let firstStartDeadline = ContinuousClock.now + .seconds(1)
    while await resolver.callCount == 0, ContinuousClock.now < firstStartDeadline {
        await Task.yield()
    }
    let startedCallCount = await resolver.callCount
    #expect(startedCallCount == 1)
    let secondRefresh = Task { await viewModel.refreshActiveModelCapabilities() }

    let secondResult = await secondRefresh.value
    await resolver.releaseFirst()
    let firstResult = await firstRefresh.value

    #expect(secondResult?.supportsImageInput == false)
    #expect(firstResult == nil)
    #expect(viewModel.activeModel?.supportsImageInput == false)
    #expect(!viewModel.canCaptureScreenshot)
}

// MARK: - Chat history

@Test
@MainActor
func testSentConversationIsSavedWithAnswerAndHiddenContext() async throws {
    let service = FakeAIService(responses: [.success(["Answer"])])
    let viewModel = makeChatViewModel(service: service)

    viewModel.setPendingSelectionText("Selected context")
    viewModel.inputText = "Hello"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let saved = try #require(viewModel.historyConversations.first)
    #expect(viewModel.historyConversations.count == 1)
    #expect(saved.id == viewModel.currentConversationID)
    #expect(saved.messages.map(\.text) == ["Hello", "Answer"])
    #expect(saved.conversationContextText == "Selected context")
    #expect(saved.title == "Hello")
}

@Test
@MainActor
func testNewChatStartsUnsavedDraftAndExistingTargetRestoresConversation() async throws {
    let service = FakeAIService(responses: [.success(["Answer"])])
    let viewModel = makeChatViewModel(service: service)
    viewModel.setPendingSelectionText("Selected context")
    viewModel.inputText = "Hello"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()
    let savedID = try #require(viewModel.currentConversationID)

    viewModel.startNewChat()

    #expect(viewModel.messages.isEmpty)
    #expect(viewModel.currentConversationID == nil)
    #expect(viewModel.conversationContextText == nil)
    #expect(viewModel.historyConversations.count == 1)

    viewModel.presentConversation(.existing(savedID))

    #expect(viewModel.currentConversationID == savedID)
    #expect(viewModel.messages.map(\.text) == ["Hello", "Answer"])
    #expect(viewModel.conversationContextText == "Selected context")
}

@Test
@MainActor
func testFollowUpInLoadedConversationUpdatesTheSameHistoryEntry() async throws {
    let environment = AppEnvironment()
    let stored = StoredChatConversation(
        updatedAt: Date(timeIntervalSince1970: 1_000),
        messages: [
            ChatConversationMessage(role: .user, text: "Earlier"),
            ChatConversationMessage(role: .assistant, text: "Reply")
        ]
    )
    environment.chatHistoryStore.upsert(stored)
    let service = FakeAIService(responses: [.success(["Second reply"])])
    let viewModel = makeChatViewModel(service: service, environment: environment)

    viewModel.presentConversation(.existing(stored.id))
    viewModel.inputText = "Follow-up"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    let request = try #require(service.recordedRequests().first)
    #expect(request.messages.map(\.content).suffix(3) == ["Earlier", "Reply", "Follow-up"])
    #expect(viewModel.historyConversations.count == 1)
    #expect(viewModel.historyConversations.first?.id == stored.id)
    #expect(
        viewModel.historyConversations.first?.messages.map(\.text)
            == ["Earlier", "Reply", "Follow-up", "Second reply"]
    )
}

@Test
@MainActor
func testContinueCurrentKeepsAnyDraftAndOtherwiseRestoresMostRecent() {
    let environment = AppEnvironment()
    let older = StoredChatConversation(
        updatedAt: Date(timeIntervalSince1970: 1_000),
        messages: [ChatConversationMessage(role: .user, text: "Older")]
    )
    let newer = StoredChatConversation(
        updatedAt: Date(timeIntervalSince1970: 2_000),
        messages: [ChatConversationMessage(role: .user, text: "Newer")]
    )
    environment.chatHistoryStore.upsert(older)
    environment.chatHistoryStore.upsert(newer)
    let viewModel = makeChatViewModel(service: FakeAIService(responses: []), environment: environment)

    viewModel.inputText = "Unsent draft"
    viewModel.presentConversation(.continueCurrentOrMostRecent)
    #expect(viewModel.messages.isEmpty)
    #expect(viewModel.inputText == "Unsent draft")

    viewModel.inputText = ""
    viewModel.pendingScreenshot = makeTestAttachment()
    viewModel.presentConversation(.continueCurrentOrMostRecent)
    #expect(viewModel.messages.isEmpty)
    #expect(viewModel.pendingScreenshot != nil)

    viewModel.pendingScreenshot = nil
    viewModel.setPendingSelectionText("Pending context")
    viewModel.presentConversation(.continueCurrentOrMostRecent)
    #expect(viewModel.messages.isEmpty)
    #expect(viewModel.pendingSelectionText == "Pending context")

    viewModel.clearPendingSelectionText()
    viewModel.presentConversation(.continueCurrentOrMostRecent)
    #expect(viewModel.currentConversationID == newer.id)
    #expect(viewModel.messages.map(\.text) == ["Newer"])
}

@Test
@MainActor
func testStopSavesPartialResponseWithImagesAsPlaceholders() async throws {
    let scheduler = ManualStreamingTextScheduler()
    let service = HoldingAIService(events: [
        .text("Par"),
        .text("tial"),
        .image(data: Data([7, 8, 9]), mimeType: "image/png")
    ])
    let viewModel = makeChatViewModel(service: service, streamingTextScheduler: scheduler)
    viewModel.inputText = "Question"

    viewModel.sendMessage()
    await waitUntilObserved { viewModel.messages.last?.images.count == 1 && viewModel.isStreaming }
    viewModel.stopStreaming()

    let saved = try #require(viewModel.historyConversations.first)
    #expect(saved.messages.map(\.text) == ["Question", "Partial"])
    #expect(saved.messages.last?.images.isEmpty == true)
    #expect(saved.messages.last?.invalidImageCount == 1)
    #expect(viewModel.messages.last?.images.count == 1)
}

@Test
@MainActor
func testFailedResponseSavesQuestionWithoutEmptyAnswer() async throws {
    let service = FakeAIService(responses: [.failure(FakeAIService.TestError.failed)])
    let viewModel = makeChatViewModel(service: service)
    viewModel.inputText = "Question"

    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()

    #expect(viewModel.error != nil)
    let saved = try #require(viewModel.historyConversations.first)
    #expect(saved.messages.map(\.role) == [.user])
    #expect(saved.messages.map(\.text) == ["Question"])
}

@Test
@MainActor
func testIdleResetDoesNotRecreateConversationDeletedFromHistory() async throws {
    let environment = AppEnvironment()
    let service = FakeAIService(responses: [.success(["Answer"])])
    let viewModel = makeChatViewModel(service: service, environment: environment)
    viewModel.inputText = "Hello"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()
    let savedID = try #require(viewModel.currentConversationID)

    environment.chatHistoryStore.delete(id: savedID)
    viewModel.reset()
    viewModel.dismiss()

    #expect(environment.chatHistoryStore.conversations.isEmpty)
}

@MainActor
private func makeChatViewModel(
    service: any AIService,
    environment: AppEnvironment = AppEnvironment(),
    resolvedAIConfig: ResolvedAIConfig = ResolvedAIConfig(
        apiKey: "key",
        model: "chat-model",
        temperature: 0.7,
        maxTokens: 2048
    ),
    moduleConfig: ModuleAIConfig? = nil,
    configProvider: (() -> ResolvedAIConfig)? = nil,
    screenshotCapturer: (any ScreenshotCapturing)? = nil,
    screenshotWindowProvider: (() -> (any ScreenshotCaptureWindow)?)? = nil,
    captureCleanupBarrierObserver: (() -> Void)? = nil,
    models: [String: OpenRouterModel] = [:],
    modelResolver: ((String, String) async -> OpenRouterModel?)? = nil,
    configuredModelIDProvider: (() -> String)? = nil,
    streamingTextScheduler: any StreamingTextScheduler = MainQueueStreamingTextScheduler(),
    feedbackScheduler: any StreamingTextScheduler = MainQueueStreamingTextScheduler()
) -> ChatViewModel {
    ChatViewModel(
        environment: environment,
        aiServiceProvider: { service },
        resolvedAIConfigProvider: { _ in configProvider?() ?? resolvedAIConfig },
        moduleAIConfigProvider: { _ in moduleConfig },
        defaultTargetLanguageProvider: { "Russian" },
        screenshotCapturer: screenshotCapturer ?? FakeScreenshotCapturer(outcomes: []),
        screenshotWindowProvider: screenshotWindowProvider,
        captureCleanupBarrierObserver: captureCleanupBarrierObserver,
        cachedModelProvider: { models[$0] },
        modelResolver: modelResolver ?? { modelID, _ in models[modelID] },
        configuredModelIDProvider: configuredModelIDProvider ?? {
            configProvider?().model ?? resolvedAIConfig.model
        },
        streamingTextScheduler: streamingTextScheduler,
        feedbackScheduler: feedbackScheduler
    )
}

private func makeResolvedConfig(model: String) -> ResolvedAIConfig {
    ResolvedAIConfig(
        apiKey: "key",
        model: model,
        temperature: 0.7,
        maxTokens: 2048
    )
}

private func makeTestModel(
    id: String,
    input: [String] = ["text"],
    output: [String] = ["text"]
) -> OpenRouterModel {
    OpenRouterModel(
        id: id,
        name: id,
        context_length: 32_000,
        architecture: OpenRouterModel.Architecture(
            input_modalities: input,
            output_modalities: output
        )
    )
}

private func makeTestAttachment(data: Data = testPNGData) -> ChatImageAttachment {
    ChatImageAttachment(
        data: data,
        mimeType: "image/png",
        pixelWidth: 320,
        pixelHeight: 180
    )
}

private let testCapturedScreenshot = CapturedScreenshot(
    pngData: testPNGData,
    pixelWidth: 320,
    pixelHeight: 180
)

private let testPNGData = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)!

@MainActor
private func waitUntilObserved(_ condition: @escaping () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}

@MainActor
private func waitUntilScreenshotCaptureFinishes(_ viewModel: ChatViewModel) async {
    guard viewModel.isCapturingScreenshot else { return }
    await withCheckedContinuation { continuation in
        withObservationTracking {
            _ = viewModel.isCapturingScreenshot
        } onChange: {
            continuation.resume()
        }
    }
}

private final class FakeAIService: AIService, @unchecked Sendable {
    enum Response {
        case success([String])
        case events([ChatStreamEvent])
        case eventsThenFailure([ChatStreamEvent], Error)
        case failure(Error)
    }

    enum ImageResponse {
        case success(ImageGenerationResult)
        case failure(Error)
    }

    enum TestError: Error {
        case failed
    }

    private let lock = NSLock()
    private var responses: [Response]
    private var requests: [ChatRequest] = []
    private var imageResponses: [ImageResponse]
    private var imageRequests: [ImageGenerationRequest] = []

    init(responses: [Response], imageResponses: [ImageResponse] = []) {
        self.responses = responses
        self.imageResponses = imageResponses
    }

    func stream(request: ChatRequest, config: ResolvedAIConfig) -> AsyncThrowingStream<String, Error> {
        let response = takeResponse(recording: request)

        return AsyncThrowingStream { continuation in
            switch response {
            case .success(let chunks):
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            case .events(let events):
                for event in events {
                    if case .text(let chunk) = event {
                        continuation.yield(chunk)
                    }
                }
                continuation.finish()
            case .eventsThenFailure(let events, let error):
                for event in events {
                    if case .text(let chunk) = event {
                        continuation.yield(chunk)
                    }
                }
                continuation.finish(throwing: error)
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    func streamChat(
        request: ChatRequest,
        config: ResolvedAIConfig
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let response = takeResponse(recording: request)

        return AsyncThrowingStream { continuation in
            switch response {
            case .success(let chunks):
                for chunk in chunks {
                    continuation.yield(.text(chunk))
                }
                continuation.finish()
            case .events(let events):
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            case .eventsThenFailure(let events, let error):
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish(throwing: error)
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    func generateImages(
        request: ImageGenerationRequest,
        config: ResolvedAIConfig
    ) async throws -> ImageGenerationResult {
        switch takeImageResponse(recording: request) {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    func recordedRequests() -> [ChatRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func recordedImageRequests() -> [ImageGenerationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return imageRequests
    }

    private func takeResponse(recording request: ChatRequest) -> Response {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return responses.isEmpty ? .success([]) : responses.removeFirst()
    }

    private func takeImageResponse(recording request: ImageGenerationRequest) -> ImageResponse {
        lock.lock()
        defer { lock.unlock() }
        imageRequests.append(request)
        return imageResponses.isEmpty
            ? .success(ImageGenerationResult(images: []))
            : imageResponses.removeFirst()
    }
}

private final class HoldingAIService: AIService, @unchecked Sendable {
    private let events: [ChatStreamEvent]
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation?

    init(events: [ChatStreamEvent]) {
        self.events = events
    }

    func stream(request: ChatRequest, config: ResolvedAIConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func streamChat(
        request: ChatRequest,
        config: ResolvedAIConfig
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            for event in events {
                continuation.yield(event)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuation = nil
                self.lock.unlock()
            }
        }
    }
}

@MainActor
private final class FakeChatCaptureWindow: ScreenshotCaptureWindow {
    var screenshotIsVisible: Bool
    var screenshotIsKeyWindow: Bool
    let screenshotWindowNumber: Int
    private(set) var hideCount = 0
    private(set) var orderFrontCount = 0
    private(set) var makeKeyAndOrderFrontCount = 0

    init(windowNumber: Int, isVisible: Bool, isKey: Bool) {
        self.screenshotWindowNumber = windowNumber
        self.screenshotIsVisible = isVisible
        self.screenshotIsKeyWindow = isKey
    }

    func hideForScreenshot() {
        hideCount += 1
        screenshotIsVisible = false
        screenshotIsKeyWindow = false
    }

    func orderFrontAfterScreenshot() {
        orderFrontCount += 1
        screenshotIsVisible = true
    }

    func makeKeyAndOrderFrontAfterScreenshot() {
        makeKeyAndOrderFrontCount += 1
        screenshotIsVisible = true
        screenshotIsKeyWindow = true
    }
}

@MainActor
private final class ScreenshotWindowBox {
    var window: (any ScreenshotCaptureWindow)?

    init(_ window: any ScreenshotCaptureWindow) {
        self.window = window
    }
}

@MainActor
private final class MutableScreenshotCaptureWindowEnvironment:
    ScreenshotCaptureWindowEnvironment
{
    let windowBox: ScreenshotWindowBox
    var isApplicationActive = true
    private(set) var activateCount = 0

    var initiatingWindow: (any ScreenshotCaptureWindow)? {
        windowBox.window
    }

    init(windowBox: ScreenshotWindowBox) {
        self.windowBox = windowBox
    }

    func activateApplication() {
        activateCount += 1
        isApplicationActive = true
    }
}

@MainActor
private final class CaptureCleanupBarrierProbe {
    private var hasEntered = false
    private var entryContinuation: CheckedContinuation<Void, Never>?

    func enter() {
        hasEntered = true
        entryContinuation?.resume()
        entryContinuation = nil
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryContinuation = continuation
        }
    }
}

@MainActor
private final class NonCooperativeScreenshotCapturer: ScreenshotCapturing {
    private(set) var captureCallCount = 0
    private(set) var capturedModes: [ScreenshotCaptureMode] = []
    private(set) var prematureOverlapCount = 0

    private var isFirstCaptureInProgress = false
    private var hasFirstCaptureStarted = false
    private var shouldReleaseFirstCapture = false
    private var hasSecondCaptureStarted = false
    private var firstCaptureContinuation: CheckedContinuation<Void, Never>?
    private var firstCaptureStartedContinuation: CheckedContinuation<Void, Never>?
    private var secondCaptureStartedContinuation: CheckedContinuation<Void, Never>?

    func captureScreenshot(mode: ScreenshotCaptureMode) async throws -> CapturedScreenshot? {
        captureCallCount += 1
        capturedModes.append(mode)

        if captureCallCount == 1 {
            isFirstCaptureInProgress = true
            hasFirstCaptureStarted = true
            firstCaptureStartedContinuation?.resume()
            firstCaptureStartedContinuation = nil
            await withCheckedContinuation { continuation in
                if shouldReleaseFirstCapture {
                    continuation.resume()
                } else {
                    firstCaptureContinuation = continuation
                }
            }
            isFirstCaptureInProgress = false
            return nil
        }

        hasSecondCaptureStarted = true
        secondCaptureStartedContinuation?.resume()
        secondCaptureStartedContinuation = nil
        if isFirstCaptureInProgress {
            prematureOverlapCount += 1
            throw ScreenshotCaptureError.captureAlreadyInProgress
        }
        return testCapturedScreenshot
    }

    func waitUntilFirstCaptureStarts() async {
        guard !hasFirstCaptureStarted else { return }
        await withCheckedContinuation { continuation in
            firstCaptureStartedContinuation = continuation
        }
    }

    func releaseFirstCapture() {
        shouldReleaseFirstCapture = true
        firstCaptureContinuation?.resume()
        firstCaptureContinuation = nil
    }

    func waitUntilSecondCaptureStarts() async {
        guard !hasSecondCaptureStarted else { return }
        await withCheckedContinuation { continuation in
            secondCaptureStartedContinuation = continuation
        }
    }
}

@MainActor
private final class FakeScreenshotCapturer: ScreenshotCapturing {
    enum Outcome {
        case success(CapturedScreenshot?)
        case failure(ScreenshotCaptureError)
    }

    private var outcomes: [Outcome]
    private let delayMilliseconds: Int
    private(set) var captureCallCount = 0
    private(set) var capturedModes: [ScreenshotCaptureMode] = []
    private(set) var cancellationCount = 0
    private var hasCaptureStarted = false
    private var captureStartedContinuation: CheckedContinuation<Void, Never>?

    init(outcomes: [Outcome], delayMilliseconds: Int = 0) {
        self.outcomes = outcomes
        self.delayMilliseconds = delayMilliseconds
    }

    func waitUntilCaptureStarts() async {
        guard !hasCaptureStarted else { return }
        await withCheckedContinuation { continuation in
            captureStartedContinuation = continuation
        }
    }

    func captureScreenshot(mode: ScreenshotCaptureMode) async throws -> CapturedScreenshot? {
        captureCallCount += 1
        capturedModes.append(mode)
        hasCaptureStarted = true
        captureStartedContinuation?.resume()
        captureStartedContinuation = nil
        if delayMilliseconds > 0 {
            do {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            } catch is CancellationError {
                cancellationCount += 1
                throw CancellationError()
            }
        }

        let outcome = outcomes.isEmpty ? Outcome.success(nil) : outcomes.removeFirst()
        switch outcome {
        case .success(let screenshot):
            return screenshot
        case .failure(let error):
            throw error
        }
    }
}

private final class TestResolvedConfigBox {
    var value: ResolvedAIConfig

    init(_ value: ResolvedAIConfig) {
        self.value = value
    }
}

private final class TestModelIDBox {
    var value: String

    init(_ value: String) {
        self.value = value
    }
}

private actor TestModelResolver {
    private let models: [String: OpenRouterModel]
    private let delayMilliseconds: [String: Int]
    private(set) var callCount = 0

    init(models: [String: OpenRouterModel], delayMilliseconds: [String: Int]) {
        self.models = models
        self.delayMilliseconds = delayMilliseconds
    }

    func resolve(_ modelID: String) async -> OpenRouterModel? {
        callCount += 1
        if let delay = delayMilliseconds[modelID] {
            try? await Task.sleep(for: .milliseconds(delay))
        }
        return models[modelID]
    }
}

private actor SequencedModelResolver {
    struct Response: Sendable {
        let delayMilliseconds: Int
        let model: OpenRouterModel?
    }

    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func resolve() async -> OpenRouterModel? {
        guard !responses.isEmpty else { return nil }
        let response = responses.removeFirst()
        try? await Task.sleep(for: .milliseconds(response.delayMilliseconds))
        return response.model
    }
}

private actor ControlledSecondModelResolver {
    let model: OpenRouterModel
    private var callCount = 0
    private var secondCallStarted = false
    private var secondCallStartedContinuation: CheckedContinuation<Void, Never>?
    private var secondCallContinuation: CheckedContinuation<Void, Never>?

    init(model: OpenRouterModel) {
        self.model = model
    }

    func resolve() async -> OpenRouterModel? {
        callCount += 1
        guard callCount == 2 else { return model }

        secondCallStarted = true
        secondCallStartedContinuation?.resume()
        secondCallStartedContinuation = nil
        await withCheckedContinuation { continuation in
            secondCallContinuation = continuation
        }
        return model
    }

    func waitUntilSecondCallStarts() async {
        guard !secondCallStarted else { return }
        await withCheckedContinuation { continuation in
            secondCallStartedContinuation = continuation
        }
    }

    func releaseSecond() {
        secondCallContinuation?.resume()
        secondCallContinuation = nil
    }
}

private actor ControlledFirstModelResolver {
    let firstModel: OpenRouterModel
    let secondModel: OpenRouterModel
    private(set) var callCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var shouldReleaseFirst = false

    init(firstModel: OpenRouterModel, secondModel: OpenRouterModel) {
        self.firstModel = firstModel
        self.secondModel = secondModel
    }

    func resolve() async -> OpenRouterModel? {
        callCount += 1
        guard callCount == 1 else { return secondModel }

        await withCheckedContinuation { continuation in
            if shouldReleaseFirst {
                continuation.resume()
            } else {
                firstContinuation = continuation
            }
        }
        return firstModel
    }

    func releaseFirst() {
        shouldReleaseFirst = true
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

@Test
@MainActor
func testChatFlushesAllBatchedChunksOnCompletionAndFailure() async {
    let scheduler = ManualStreamingTextScheduler()
    let service = FakeAIService(responses: [
        .success(["First", " answer", " complete"]),
        .eventsThenFailure([.text("Second"), .text(" partial")], FakeAIService.TestError.failed)
    ])
    let viewModel = makeChatViewModel(service: service, streamingTextScheduler: scheduler)
    var firstPublications: [String] = []
    scheduler.onSchedule = { firstPublications.append(viewModel.messages.last?.text ?? "") }
    viewModel.inputText = "One"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()
    #expect(viewModel.messages.last?.text == "First answer complete")
    viewModel.inputText = "Two"
    viewModel.sendMessage()
    await viewModel.waitForPendingWorkForTesting()
    #expect(viewModel.messages.last?.text == "Second partial")
    #expect(viewModel.error != nil)
    #expect(!viewModel.isStreaming)
    #expect(firstPublications == ["First", "Second"])
    scheduler.advance(includingCancelled: true)
    #expect(viewModel.messages.last?.text == "Second partial")
}

@Test
@MainActor
func testChatResetDiscardsBufferedTextAndScheduledCallbacks() async {
    let scheduler = ManualStreamingTextScheduler()
    let service = HoldingAIService(events: [.text("First"), .text(" pending"), .invalidImage])
    let viewModel = makeChatViewModel(service: service, streamingTextScheduler: scheduler)
    viewModel.inputText = "One"
    viewModel.sendMessage()
    await waitUntilObserved { viewModel.messages.last?.invalidImageCount == 1 }
    #expect(viewModel.messages.last?.text == "First")
    viewModel.reset()
    scheduler.advance(includingCancelled: true)
    #expect(viewModel.messages.isEmpty)
    #expect(!viewModel.isStreaming)
}
