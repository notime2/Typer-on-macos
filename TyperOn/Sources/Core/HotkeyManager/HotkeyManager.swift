// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Carbon.HIToolbox
import AppKit

struct HotkeyRegistration: Hashable, Sendable {
    let id: String
    let combo: KeyCombo
}

enum HotkeyManagerError: Error, Equatable {
    case handlerInstallFailed(OSStatus)
    case registrationConflict(id: String, combo: KeyCombo)
    case registrationFailed(id: String, status: OSStatus)
}

@MainActor
final class HotkeyManager {
    var onHotkey: ((String) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var liveRefs: [String: EventHotKeyRef] = [:]
    private var carbonIDToRegistrationID: [UInt32: String] = [:]
    private var desiredRegistrations: [HotkeyRegistration] = []
    private var nextCarbonID: UInt32 = 1
    private var isStarted = false

    // MARK: - Lifecycle

    func start() throws {
        guard !isStarted else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyCallback,
            1,
            &eventSpec,
            selfPtr,
            &handlerRef
        )

        guard status == noErr else {
            throw HotkeyManagerError.handlerInstallFailed(status)
        }

        isStarted = true
        Log.hotkeys.info("HotkeyManager started (Carbon handler installed)")
    }

    func applyRegistrations(_ registrations: [HotkeyRegistration]) throws {
        let previousDesired = desiredRegistrations

        unregisterAll()

        do {
            try registerAll(registrations)
            desiredRegistrations = registrations
        } catch {
            let applyError = error
            unregisterAll()
            desiredRegistrations = previousDesired

            do {
                try registerAll(previousDesired)
            } catch {
                unregisterAll()
                Log.hotkeys.error("Hotkey rollback failed after swap error: \(String(describing: applyError)); rollback error: \(String(describing: error))")
            }

            throw applyError
        }
    }

    func suspend() {
        unregisterAll()
    }

    func resume() throws {
        guard isStarted else { return }
        let regs = desiredRegistrations
        unregisterAll()
        desiredRegistrations = regs

        for reg in regs {
            try registerSingle(reg)
        }
    }

    func stop() {
        unregisterAll()
        desiredRegistrations = []

        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        isStarted = false
        Log.hotkeys.info("HotkeyManager stopped")
    }

    // MARK: - Internal

    func handleCarbonEvent(_ carbonID: UInt32) {
        guard let regID = carbonIDToRegistrationID[carbonID] else { return }
        onHotkey?(regID)
    }

    private func registerSingle(_ reg: HotkeyRegistration) throws {
        let carbonID = nextCarbonID
        nextCarbonID += 1

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x5459_5052), // 'TYPR'
            id: carbonID
        )

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(reg.combo.keyCode),
            reg.combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &hotKeyRef
        )

        if status == OSStatus(eventHotKeyExistsErr) {
            throw HotkeyManagerError.registrationConflict(id: reg.id, combo: reg.combo)
        }

        guard status == noErr, let ref = hotKeyRef else {
            throw HotkeyManagerError.registrationFailed(id: reg.id, status: status)
        }

        liveRefs[reg.id] = ref
        carbonIDToRegistrationID[carbonID] = reg.id
        Log.hotkeys.info("Registered hotkey '\(reg.id)': \(reg.combo.displayString)")
    }

    private func registerAll(_ registrations: [HotkeyRegistration]) throws {
        for reg in registrations {
            try registerSingle(reg)
        }
    }

    private func unregisterAll() {
        for (id, ref) in liveRefs {
            UnregisterEventHotKey(ref)
            Log.hotkeys.info("Unregistered hotkey '\(id)'")
        }
        liveRefs.removeAll()
        carbonIDToRegistrationID.removeAll()
    }
}

// MARK: - Carbon Callback (free function)

private func carbonHotkeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr else { return status }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        manager.handleCarbonEvent(hotKeyID.id)
    }

    return noErr
}
