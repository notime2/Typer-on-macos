// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

@MainActor
protocol SelectionScheduledWork: AnyObject {
    func cancel()
}

@MainActor
protocol SelectionScheduler {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any SelectionScheduledWork
}

@MainActor
final class DispatchSelectionScheduler: SelectionScheduler {
    private final class Work: SelectionScheduledWork {
        var item: DispatchWorkItem?
        func cancel() { item?.cancel(); item = nil }
    }

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> any SelectionScheduledWork {
        let work = Work()
        let item = DispatchWorkItem { action() }
        work.item = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return work
    }
}
