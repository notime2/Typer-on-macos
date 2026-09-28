// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Testing
@testable import Typer_On

@Suite("Chat scroll position")
@MainActor
struct ChatScrollPositionObserverTests {
    @Test func userScrollingChangesFollowStateButContentGrowthDoesNot() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = FlippedChatDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))
        scroll.documentView = document
        let observer = ChatScrollPositionObserver.ObserverView()
        document.addSubview(observer)
        observer.observeEnclosingScrollView()
        var states: [Bool] = []
        observer.onUserScroll = { states.append($0) }

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(states == [true])

        document.setFrameSize(NSSize(width: 400, height: 1600))
        #expect(states == [true])
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(states == [true, false])

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1260))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(states == [true, false, true])
        observer.stopObserving()
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(states.count == 3)
    }
}

@MainActor
private final class FlippedChatDocument: NSView {
    override var isFlipped: Bool { true }
}
