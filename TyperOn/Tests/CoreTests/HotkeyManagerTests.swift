// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Carbon.HIToolbox
import Testing
@testable import Typer_On

private let registerableTestHotkey = KeyCombo(
    keyCode: UInt16(kVK_ANSI_X),
    modifiers: UInt(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
)

@Test
@MainActor
func testHotkeyManagerStartInstallsHandler() throws {
    let manager = HotkeyManager()
    try manager.start()
    // Starting again should be a no-op (guard !isStarted)
    try manager.start()
    manager.stop()
}

@Test
@MainActor
func testHotkeyManagerStopIsIdempotent() {
    let manager = HotkeyManager()
    // stop() on never-started manager should not crash
    manager.stop()
    manager.stop()
}

@Test
@MainActor
func testHotkeyManagerApplyRegistersGlobalTrigger() throws {
    let manager = HotkeyManager()
    try manager.start()

    try manager.applyRegistrations([
        HotkeyRegistration(id: "globalTrigger", combo: registerableTestHotkey)
    ])

    manager.stop()
}

@Test
@MainActor
func testHotkeyManagerSwapCombo() throws {
    let manager = HotkeyManager()
    try manager.start()

    let combo1 = KeyCombo(
        keyCode: UInt16(kVK_ANSI_X),
        modifiers: UInt(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
    )
    try manager.applyRegistrations([
        HotkeyRegistration(id: "globalTrigger", combo: combo1)
    ])

    let combo2 = KeyCombo(
        keyCode: UInt16(kVK_ANSI_K),
        modifiers: UInt(CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)
    )
    try manager.applyRegistrations([
        HotkeyRegistration(id: "globalTrigger", combo: combo2)
    ])

    manager.stop()
}

@Test
@MainActor
func testHotkeyManagerSuspendAndResume() throws {
    let manager = HotkeyManager()
    try manager.start()

    try manager.applyRegistrations([
        HotkeyRegistration(id: "globalTrigger", combo: registerableTestHotkey)
    ])

    manager.suspend()
    // After suspend, resume should re-register the same desired registrations
    try manager.resume()

    manager.stop()
}

@Test
@MainActor
func testHotkeyManagerResumeBeforeStartIsNoOp() throws {
    let manager = HotkeyManager()
    // resume() before start() should be no-op (guard isStarted)
    try manager.resume()
}

@Test
@MainActor
func testHotkeyManagerConflictRestoresPreviousLiveRegistration() throws {
    let manager = HotkeyManager()
    let blocker = HotkeyManager()
    let probe = HotkeyManager()

    try manager.start()
    try blocker.start()
    try probe.start()

    defer {
        probe.stop()
        blocker.stop()
        manager.stop()
    }

    let modifiers = UInt(
        CGEventFlags.maskCommand.rawValue |
        CGEventFlags.maskShift.rawValue |
        CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskControl.rawValue
    )
    let combo = KeyCombo(
        keyCode: UInt16(kVK_ANSI_J),
        modifiers: modifiers
    )
    let conflictingCombo = KeyCombo(
        keyCode: UInt16(kVK_ANSI_K),
        modifiers: modifiers
    )

    try manager.applyRegistrations([
        HotkeyRegistration(id: "globalTrigger", combo: combo)
    ])
    try blocker.applyRegistrations([
        HotkeyRegistration(id: "blocker", combo: conflictingCombo)
    ])

    var sawConflict = false
    do {
        try manager.applyRegistrations([
            HotkeyRegistration(id: "globalTrigger", combo: conflictingCombo)
        ])
    } catch let error as HotkeyManagerError {
        if case .registrationConflict(let id, let failedCombo) = error {
            sawConflict = id == "globalTrigger" && failedCombo == conflictingCombo
        }
    } catch {
        #expect(Bool(false), "Expected registration conflict, got \(error)")
    }

    #expect(sawConflict)

    var probeSawConflict = false
    do {
        try probe.applyRegistrations([
            HotkeyRegistration(id: "probe", combo: combo)
        ])
    } catch let error as HotkeyManagerError {
        if case .registrationConflict(let id, let failedCombo) = error {
            probeSawConflict = id == "probe" && failedCombo == combo
        }
    } catch {
        #expect(Bool(false), "Expected restored combo to stay exclusive, got \(error)")
    }

    #expect(probeSawConflict)
}

@Test
@MainActor
func testHotkeyManagerCallbackFired() throws {
    let manager = HotkeyManager()
    var receivedID: String?
    manager.onHotkey = { id in
        receivedID = id
    }

    try manager.start()
    try manager.applyRegistrations([
        HotkeyRegistration(id: "globalTrigger", combo: registerableTestHotkey)
    ])

    // Simulate a Carbon event dispatch (test the internal handler routing)
    manager.handleCarbonEvent(1) // carbonID 1 = first registration
    #expect(receivedID == "globalTrigger")

    manager.stop()
}
