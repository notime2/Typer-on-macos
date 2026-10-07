// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Testing
@testable import Typer_On

@Test
@MainActor
func testModelSelectionClearsSavedFeedbackWithoutEditorFocus() {
    let scheduler = ManualStreamingTextScheduler()
    let state = ModuleSettingsSaveFeedbackState(feedbackScheduler: scheduler)
    state.markSaved()
    state.markEdited()
    #expect(state.status == .idle)
    #expect(state.focusedField == nil)
    state.markSaved()
    scheduler.advanceNext(includingCancelled: true)
    #expect(state.status == .saved)
    scheduler.advance()
    #expect(state.status == .idle)
}

@Test
@MainActor
func testMarkSavedClearsFocusAndReturnsToIdle() {
    let scheduler = ManualStreamingTextScheduler()
    let state = ModuleSettingsSaveFeedbackState(feedbackScheduler: scheduler)

    state.updateFocusedField(.systemPrompt)
    #expect(state.focusedField == .systemPrompt)
    #expect(state.status == .idle)

    state.markSaved()

    #expect(state.focusedField == nil)
    #expect(state.status == .saved)

    #expect(scheduler.delays == [2])
    scheduler.advance()
    #expect(state.status == .idle)
}

@Test
@MainActor
func testSecondSaveExtendsSavedFeedbackWindow() {
    let scheduler = ManualStreamingTextScheduler()
    let state = ModuleSettingsSaveFeedbackState(feedbackScheduler: scheduler)

    state.markSaved()
    state.markSaved()
    #expect(scheduler.delays == [2, 2])
    scheduler.advanceNext(includingCancelled: true)
    #expect(state.status == .saved)
    scheduler.advance()
    #expect(state.status == .idle)
}

@Test
@MainActor
func testRefocusingFieldClearsSavedFeedbackImmediately() {
    let scheduler = ManualStreamingTextScheduler()
    let state = ModuleSettingsSaveFeedbackState(feedbackScheduler: scheduler)

    state.markSaved()
    #expect(state.status == .saved)

    state.updateFocusedField(.customModel)
    scheduler.advance(includingCancelled: true)

    #expect(state.status == .idle)
    #expect(state.focusedField == .customModel)
}
