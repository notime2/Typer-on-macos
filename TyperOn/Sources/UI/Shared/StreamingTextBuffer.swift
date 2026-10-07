// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

@MainActor
protocol StreamingTextScheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void
}

@MainActor
struct MainQueueStreamingTextScheduler: StreamingTextScheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return { work.cancel() }
    }
}

/// Owns only unpublished text for one response. The first fragment is immediate;
/// subsequent fragments publish at most once per frame-sized interval.
@MainActor
final class StreamingTextBuffer {
    private let scheduler: any StreamingTextScheduler
    private var cancelScheduled: (() -> Void)?
    private var pending = ""
    private var publish: ((String) -> Void)?
    private var hasPublished = false
    private var generation = UUID()

    init(scheduler: any StreamingTextScheduler = MainQueueStreamingTextScheduler()) {
        self.scheduler = scheduler
    }

    func begin(publish: @escaping (String) -> Void) {
        cancel()
        self.publish = publish
    }

    func append(_ text: String) {
        guard !text.isEmpty, let publish else { return }
        if !hasPublished {
            hasPublished = true
            publish(text)
        } else {
            pending += text
        }
        guard cancelScheduled == nil else { return }
        let scheduledGeneration = generation
        cancelScheduled = scheduler.schedule(after: 0.033) { [weak self] in
            guard let self, self.generation == scheduledGeneration else { return }
            self.cancelScheduled = nil
            self.flush()
        }
    }

    func finish() {
        flush()
        cancel()
    }

    func cancel() {
        cancelScheduled?()
        cancelScheduled = nil
        generation = UUID()
        pending = ""
        publish = nil
        hasPublished = false
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let text = pending
        pending = ""
        publish?(text)
    }
}
