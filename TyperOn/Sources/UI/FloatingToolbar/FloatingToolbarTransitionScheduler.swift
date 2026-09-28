// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

/// Cancellable handle for one scheduled floating toolbar transition step.
@MainActor
final class FloatingToolbarScheduledWork {
    private var cancelAction: (@MainActor () -> Void)?

    init(cancelAction: @escaping @MainActor () -> Void) {
        self.cancelAction = cancelAction
    }

    func cancel() {
        cancelAction?()
        cancelAction = nil
    }
}

/// Timing source for the staged compact/expanded morph. Production uses the
/// main queue; tests inject a scheduler they advance explicitly.
@MainActor
protocol FloatingToolbarTransitionScheduler {
    func schedule(
        after delay: TimeInterval,
        perform work: @escaping @MainActor () -> Void
    ) -> FloatingToolbarScheduledWork
}

@MainActor
final class MainQueueFloatingToolbarTransitionScheduler: FloatingToolbarTransitionScheduler {
    func schedule(
        after delay: TimeInterval,
        perform work: @escaping @MainActor () -> Void
    ) -> FloatingToolbarScheduledWork {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                work()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return FloatingToolbarScheduledWork { item.cancel() }
    }
}
