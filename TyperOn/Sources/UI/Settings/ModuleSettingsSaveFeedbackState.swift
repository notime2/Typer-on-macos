// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

@MainActor
@Observable
final class ModuleSettingsSaveFeedbackState {
    enum Status: Equatable {
        case idle
        case saved
    }

    enum FocusedField: Hashable {
        case customAPIKey
        case customModel
        case systemPrompt
    }

    private(set) var status: Status = .idle
    private(set) var focusedField: FocusedField?

    private let feedbackScheduler: any StreamingTextScheduler
    private var cancelReset: (() -> Void)?
    private var resetGeneration = UUID()

    init(feedbackScheduler: any StreamingTextScheduler = MainQueueStreamingTextScheduler()) {
        self.feedbackScheduler = feedbackScheduler
    }

    private func cancelPendingReset() {
        resetGeneration = UUID()
        cancelReset?()
        cancelReset = nil
    }

    func updateFocusedField(_ field: FocusedField?) {
        if field != nil {
            markEdited()
        }
        focusedField = field
    }

    func markEdited() {
        cancelPendingReset()
        status = .idle
    }

    func markSaved() {
        focusedField = nil
        cancelPendingReset()
        status = .saved
        let generation = resetGeneration
        cancelReset = feedbackScheduler.schedule(after: 2) { [weak self] in
            guard let self, self.resetGeneration == generation else { return }
            self.cancelReset = nil
            self.status = .idle
        }
    }
}
