// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Testing
@testable import Typer_On

@Test
@MainActor
func testCopyFeedbackTransitionsFromIdleToCopiedAndBack() {
    let scheduler = ManualStreamingTextScheduler()
    let environment = AppEnvironment()
    let viewModel = ProcessingViewModel(environment: environment, feedbackScheduler: scheduler)
    viewModel.resultText = "Hello"

    #expect(viewModel.copyFeedbackState == .idle)

    viewModel.copyResult()
    #expect(viewModel.copyFeedbackState == .copied)

    #expect(scheduler.delays == [1])
    scheduler.advance()
    #expect(viewModel.copyFeedbackState == .idle)
}

@Test
@MainActor
func testCopyFeedbackSecondTapExtendsCopiedState() {
    let scheduler = ManualStreamingTextScheduler()
    let environment = AppEnvironment()
    let viewModel = ProcessingViewModel(environment: environment, feedbackScheduler: scheduler)
    viewModel.resultText = "Hello"

    viewModel.copyResult()
    viewModel.copyResult()
    #expect(scheduler.delays == [1, 1])
    scheduler.advanceNext(includingCancelled: true)
    #expect(viewModel.copyFeedbackState == .copied)
    scheduler.advance()
    #expect(viewModel.copyFeedbackState == .idle)
}
