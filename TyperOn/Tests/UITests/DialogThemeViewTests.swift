// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Observation
import SwiftUI
import Testing
@testable import Typer_On

@MainActor
@Suite("Live dialog theme state")
struct DialogThemeViewTests {
    @Test func chatKeepsDraftContextAttachmentsAndStreamAcrossPreferenceChanges() async throws {
        let service = DialogHeldAIService()
        defer { service.chatContinuation.finish() }
        let scheduler = ManualStreamingTextScheduler()
        let model = ChatViewModel(
            environment: AppEnvironment(),
            aiServiceProvider: { service },
            resolvedAIConfigProvider: { _ in
                ResolvedAIConfig(apiKey: "synthetic", model: "synthetic/text", temperature: 0.7, maxTokens: 2048)
            },
            moduleAIConfigProvider: { _ in nil },
            defaultTargetLanguageProvider: { "English" },
            cachedModelProvider: { _ in nil },
            modelResolver: { _, _ in nil },
            configuredModelIDProvider: { "synthetic/text" },
            streamingTextScheduler: scheduler
        )
        let attachment = ChatImageAttachment(
            data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!,
            mimeType: "image/png", pixelWidth: 1, pixelHeight: 1
        )
        model.messages = [ChatConversationMessage(role: .assistant, text: "Prior **answer**", images: [attachment])]
        model.setPendingSelectionText("Submitted synthetic context")
        model.inputText = "Explain the synthetic sample"
        service.chatContinuation.yield(.text(Self.longMarkdown))
        service.chatContinuation.yield(.text(" Buffered continuation."))
        service.chatContinuation.yield(.image(data: attachment.data, mimeType: attachment.mimeType))
        model.sendMessage()
        // The image follows both text events and acknowledges their consumption.
        // Scheduling alone is insufficient: the first immediate text schedules too.
        await waitForDialogObservation { model.messages.last?.images.count == 1 }
        #expect(model.isStreaming)
        model.inputText = "Unsent follow-up draft"
        model.pendingSelectionText = "Pending synthetic context"
        model.pendingScreenshot = attachment
        let messageIDs = model.messages.map(\.id)
        let receivedImageID = try #require(model.messages.last?.images.first?.id)
        let renderedAnswer = model.messages.last?.text
        let conversationContext = model.conversationContextText

        let fixture = try DialogHostingFixture { ChatView(viewModel: model) }
        defer { fixture.close() }
        await fixture.settleLayout()
        let editor = try #require(dialogDescendants(of: NSTextView.self, in: fixture.host).first)
        let selection = NSRange(location: 2, length: 6)
        editor.setSelectedRange(selection)
        let scroll = try await fixture.scrollAwayFromBottom()
        let scrollOrigin = scroll.contentView.bounds.origin

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            fixture.setAppearance(appearance)
            for style in SelectionTriggerStyle.allCases {
                await fixture.setStyle(style)
                #expect(dialogDescendants(of: NSTextView.self, in: fixture.host).contains { $0 === editor })
                #expect(editor.selectedRange() == selection)
                #expect(editor.string == "Unsent follow-up draft")
                #expect(model.inputText == "Unsent follow-up draft")
                #expect(model.messages.map(\.id) == messageIDs)
                #expect(model.messages.first?.images.first?.id == attachment.id)
                #expect(model.messages.last?.images.first?.id == receivedImageID)
                #expect(model.pendingScreenshot?.id == attachment.id)
                #expect(model.pendingSelectionText == "Pending synthetic context")
                #expect(model.conversationContextText == conversationContext)
                #expect(model.messages.last?.text == renderedAnswer)
                #expect(model.isStreaming)
                #expect(scroll.contentView.bounds.origin == scrollOrigin)
                try await fixture.captureIfRequested(name: "chat-streaming-\(appearance.rawValue)-\(style.rawValue)")
            }
        }
        scheduler.advance()
        #expect(model.messages.last?.text == Self.longMarkdown + " Buffered continuation.")
        service.chatContinuation.yield(.text(" Finished."))
        service.chatContinuation.finish()
        await model.waitForPendingWorkForTesting()
        #expect(model.messages.last?.text == Self.longMarkdown + " Buffered continuation. Finished.")
        #expect(!model.isStreaming)
        #expect(model.inputText == "Unsent follow-up draft")
        #expect(model.pendingScreenshot?.id == attachment.id)
        #expect(model.messages.map(\.id) == messageIDs)
    }

    @Test func processingKeepsEditorAndStreamThenShowsAutomaticReplacementFailure() async throws {
        let service = DialogHeldAIService()
        defer { service.continuation.finish() }
        let scheduler = ManualStreamingTextScheduler()
        let buffered = DialogSignal()
        scheduler.onSchedule = { buffered.signal() }
        var replacementCount = 0
        var events: [AutomaticProcessingEvent] = []
        let model = ProcessingViewModel(
            environment: AppEnvironment(),
            aiServiceProvider: { service },
            replaceAction: { _, _ in
                replacementCount += 1
                return .failed
            },
            streamingTextScheduler: scheduler
        )
        model.onAutomaticProcessingEvent = { events.append($0) }
        service.continuation.yield(Self.longMarkdown)
        service.continuation.yield(" Buffered continuation.")
        model.process(
            module: TranslationModule(),
            selection: TextSelection(text: "Synthetic original", cursorPosition: .zero, sourceAppPID: 123),
            mode: .automaticReplacement
        )
        await buffered.wait()
        model.userComment = "Unsent refinement"
        let fixture = try DialogHostingFixture { ProcessingView(viewModel: model) }
        defer { fixture.close() }
        await fixture.settleLayout()
        let editor = try #require(dialogDescendants(of: NSTextView.self, in: fixture.host).first)
        let selection = NSRange(location: 1, length: 5)
        editor.setSelectedRange(selection)
        let scroll = try await fixture.scrollAwayFromBottom()
        let scrollOrigin = scroll.contentView.bounds.origin
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            fixture.setAppearance(appearance)
            for style in SelectionTriggerStyle.allCases {
                await fixture.setStyle(style)
                #expect(dialogDescendants(of: NSTextView.self, in: fixture.host).contains { $0 === editor })
                #expect(editor.selectedRange() == selection)
                #expect(model.userComment == "Unsent refinement")
                #expect(model.originalText == "Synthetic original")
                #expect(model.resultText == Self.longMarkdown)
                #expect(model.isStreaming)
                #expect(replacementCount == 0)
                #expect(scroll.contentView.bounds.origin == scrollOrigin)
                try await fixture.captureIfRequested(name: "processing-streaming-\(appearance.rawValue)-\(style.rawValue)")
            }
        }
        service.continuation.finish()
        await model.waitForPendingWorkForTesting()
        #expect(replacementCount == 1)
        #expect(events == [.replaceStarted, .requiresPresentation])
        let failure = try #require(model.error)
        let finalResult = model.resultText
        #expect(finalResult == Self.longMarkdown + " Buffered continuation.")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            fixture.setAppearance(appearance)
            for style in SelectionTriggerStyle.allCases {
                await fixture.setStyle(style)
                #expect(model.error == failure)
                #expect(model.resultText == finalResult)
                #expect(model.userComment == "Unsent refinement")
                #expect(!model.isStreaming)
                #expect(!model.isErrorRetryable)
                try await fixture.captureIfRequested(name: "processing-replacement-failure-\(appearance.rawValue)-\(style.rawValue)")
            }
        }
        #expect(replacementCount == 1)
    }

    @Test func processingEmptyLoadingUsesAllThemesAndAppearances() async throws {
        let service = DialogHeldAIService()
        let model = ProcessingViewModel(environment: AppEnvironment(), aiServiceProvider: { service })
        defer {
            model.cancel()
            service.continuation.finish()
        }
        model.process(
            module: TranslationModule(),
            selection: TextSelection(
                text: "Synthetic input waiting for its first response fragment.",
                cursorPosition: .zero,
                sourceAppPID: 123
            )
        )
        let fixture = try DialogHostingFixture { ProcessingView(viewModel: model) }
        defer { fixture.close() }
        await fixture.settleLayout()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            fixture.setAppearance(appearance)
            for style in SelectionTriggerStyle.allCases {
                await fixture.setStyle(style)
                #expect(model.isStreaming)
                #expect(model.resultText.isEmpty)
                try await fixture.captureIfRequested(name: "processing-loading-\(appearance.rawValue)-\(style.rawValue)")
            }
        }
    }

    private static var longMarkdown: String {
        (0..<24).map { "Paragraph \($0): **Synthetic answer** with `inline code`.\n\n" }.joined()
            + "```swift\nlet synthetic = true\n```\n"
    }
}

/// The consumer stays suspended until the test explicitly yields or finishes.
private final class DialogHeldAIService: AIService, Sendable {
    let chunks: AsyncThrowingStream<String, Error>
    let continuation: AsyncThrowingStream<String, Error>.Continuation
    let chatEvents: AsyncThrowingStream<ChatStreamEvent, Error>
    let chatContinuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation

    init() {
        (chunks, continuation) = AsyncThrowingStream.makeStream()
        (chatEvents, chatContinuation) = AsyncThrowingStream.makeStream()
    }

    func stream(request: ChatRequest, config: ResolvedAIConfig) -> AsyncThrowingStream<String, Error> { chunks }
    func streamChat(request: ChatRequest, config: ResolvedAIConfig) -> AsyncThrowingStream<ChatStreamEvent, Error> { chatEvents }
}

@MainActor
private final class DialogSignal {
    private var signalled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func signal() {
        signalled = true
        continuation?.resume()
        continuation = nil
    }
    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor
private final class DialogThemeProbeState {
    var style: SelectionTriggerStyle?
    private var expected: SelectionTriggerStyle?
    private var continuation: CheckedContinuation<Void, Never>?
    func update(_ style: SelectionTriggerStyle) {
        self.style = style
        if expected == style {
            continuation?.resume()
            continuation = nil
        }
    }
    func wait(for style: SelectionTriggerStyle) async {
        guard self.style != style else { return }
        expected = style
        await withCheckedContinuation { continuation = $0 }
    }
}

private struct DialogThemeProbe: NSViewRepresentable {
    @Environment(\.dialogTheme) private var theme
    let state: DialogThemeProbeState
    func makeNSView(context: Context) -> NSView {
        state.update(theme.style)
        return NSView()
    }
    func updateNSView(_ view: NSView, context: Context) { state.update(theme.style) }
}

@MainActor
private final class DialogHostingFixture {
    let host: NSView
    private let window: NSWindow
    private let defaults: UserDefaults
    private let suite = "DialogThemeViewTests.\(UUID().uuidString)"
    private let probe = DialogThemeProbeState()

    init<Content: View>(@ViewBuilder content: () -> Content) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(SelectionTriggerStyle.glassDot.rawValue, forKey: SettingsKey.selectionTriggerStyle.rawValue)
        let view = content()
        let probe = self.probe
        host = NSHostingView(rootView: DialogThemeRoot {
            view.overlay(DialogThemeProbe(state: probe).frame(width: 0, height: 0))
        }
        .defaultAppStorage(defaults)
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
    }

    func setStyle(_ style: SelectionTriggerStyle) async {
        defaults.set(style.rawValue, forKey: SettingsKey.selectionTriggerStyle.rawValue)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        await probe.wait(for: style)
        await settleLayout()
    }

    func setAppearance(_ name: NSAppearance.Name) {
        window.appearance = NSAppearance(named: name)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
    }

    func settleLayout() async {
        // First layout schedules the native height update; the following turns apply
        // SwiftUI state and then lay out the resulting editor size. No timed sleeps.
        for _ in 0..<3 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        host.layoutSubtreeIfNeeded()
    }

    func captureIfRequested(name: String) async throws {
        let directory = URL(fileURLWithPath: "/tmp/TyperOnDialogVisuals", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        // Synthetic Debug/test-host content; separate from Release/live evidence.
        await settleLayout()
        for editor in dialogDescendants(of: NSTextView.self, in: host) {
            guard let container = editor.textContainer,
                  let manager = editor.layoutManager,
                  let scroll = editor.enclosingScrollView else { continue }
            manager.ensureLayout(for: container)
            let metrics = AutoGrowingTextInputMetrics()
            let expectedHeight = AutoGrowingTextInputMetrics.resolvedHeight(
                for: manager.usedRect(for: container).height + editor.textContainerInset.height * 2,
                minHeight: metrics.minHeight, maxHeight: metrics.maxHeight
            )
            #expect(scroll.frame.height >= expectedHeight - 0.5)
        }
        host.needsDisplay = true
        window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }

    func scrollAwayFromBottom() async throws -> NSScrollView {
        let scroll = try #require(dialogDescendants(of: NSScrollView.self, in: host).first {
            !($0.documentView is NSTextView) && ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 80
        })
        let target = NSPoint(x: 0, y: 40)
        scroll.contentView.scroll(to: target)
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        await settleLayout()
        try #require(scroll.contentView.bounds.origin == target, "The test must establish a stable user scroll before changing themes")
        return scroll
    }

    func close() {
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private func dialogDescendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { dialogDescendants(of: type, in: $0) }
}


@MainActor
private func waitForDialogObservation(_ condition: @escaping () -> Bool) async {
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
