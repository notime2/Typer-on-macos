// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

@MainActor
final class ManualStreamingTextScheduler: StreamingTextScheduler {
    struct Work {
        let id: UUID
        let action: @MainActor () -> Void
    }
    private var work: [Work] = []
    private var cancelled: Set<UUID> = []
    private(set) var delays: [TimeInterval] = []
    var onSchedule: (() -> Void)?

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let id = UUID()
        work.append(Work(id: id, action: action))
        delays.append(delay)
        onSchedule?()
        return { [weak self] in self?.cancelled.insert(id) }
    }

    func advanceNext(includingCancelled: Bool = false) {
        guard !work.isEmpty else { return }
        let next = work.removeFirst()
        if includingCancelled || !cancelled.contains(next.id) { next.action() }
    }

    func advance(includingCancelled: Bool = false) {
        let pending = work
        work.removeAll()
        for item in pending where includingCancelled || !cancelled.contains(item.id) {
            item.action()
        }
    }
}

@Suite("Streaming publication")
@MainActor
struct StreamingTextBufferTests {
    @Test func firstFragmentIsImmediateAndLaterFragmentsAreCoalesced() {
        let scheduler = ManualStreamingTextScheduler()
        let buffer = StreamingTextBuffer(scheduler: scheduler)
        var publications: [String] = []
        buffer.begin { publications.append($0) }
        buffer.append("")
        #expect(scheduler.delays.isEmpty)
        buffer.append("First")
        buffer.append(" second")
        buffer.append(" third")
        #expect(publications == ["First"])
        #expect(scheduler.delays == [0.033])
        scheduler.advance()
        #expect(publications == ["First", " second third"])
        buffer.append(" fourth")
        buffer.append(" fifth")
        #expect(publications.count == 2)
        scheduler.advance()
        #expect(publications == ["First", " second third", " fourth fifth"])
    }

    @Test func finishFlushesOnceAndCancelledCallbacksCannotPublishAgain() {
        let scheduler = ManualStreamingTextScheduler()
        let buffer = StreamingTextBuffer(scheduler: scheduler)
        var text = ""
        buffer.begin { text += $0 }
        buffer.append("Hello")
        buffer.append(" 🌍")
        buffer.append("e\u{301}")
        buffer.finish()
        buffer.finish()
        scheduler.advance(includingCancelled: true)
        #expect(text == "Hello 🌍e\u{301}")
    }

    @Test func newResponseDiscardsPendingTextAndRejectsOldCallbacks() {
        let scheduler = ManualStreamingTextScheduler()
        let buffer = StreamingTextBuffer(scheduler: scheduler)
        var oldText = ""
        var newText = ""
        buffer.begin { oldText += $0 }
        buffer.append("Old")
        buffer.append(" discarded")
        buffer.begin { newText += $0 }
        buffer.append("New")
        buffer.append(" response")
        scheduler.advance(includingCancelled: true)
        #expect(oldText == "Old")
        #expect(newText == "New response")
        buffer.cancel()
        buffer.append(" ignored")
        #expect(newText == "New response")
    }
}
