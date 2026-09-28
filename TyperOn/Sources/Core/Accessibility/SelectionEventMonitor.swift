// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Carbon
import CoreGraphics

@MainActor
@Observable
final class SelectionEventMonitor {
    private static let deleteKeyCodes: Set<CGKeyCode> = [
        CGKeyCode(kVK_Delete),
        CGKeyCode(kVK_ForwardDelete),
    ]
    private static let modifierKeyCodes: Set<CGKeyCode> = [
        CGKeyCode(kVK_Shift),
        CGKeyCode(kVK_RightShift),
        CGKeyCode(kVK_Command),
        CGKeyCode(kVK_RightCommand),
        CGKeyCode(kVK_Option),
        CGKeyCode(kVK_RightOption),
        CGKeyCode(kVK_Control),
        CGKeyCode(kVK_RightControl),
    ]

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onPotentialSelectionChange: ((pid_t) -> Void)?

    var isRunning: Bool { eventTap != nil }

    func start() {
        guard !isRunning else { return }

        let eventMask =
            CGEventMask(1 << CGEventType.leftMouseUp.rawValue) |
            CGEventMask(1 << CGEventType.keyUp.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) else {
            Log.accessibility.warning("Selection event monitor unavailable, continuing with polling only")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            Log.accessibility.warning("Selection event monitor run loop source unavailable")
            return
        }

        self.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        Log.accessibility.info("Selection event monitor started")
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<SelectionEventMonitor>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak monitor] in
                monitor?.reenableEventTap()
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard SelectionEventMonitor.shouldHandleEvent(type: type, keyCode: keyCode, flags: event.flags) else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [weak monitor] in
            monitor?.notifyPotentialSelectionChange()
        }
        return Unmanaged.passUnretained(event)
    }

    static func shouldHandleEvent(type: CGEventType, keyCode: CGKeyCode?, flags: CGEventFlags) -> Bool {
        switch type {
        case .leftMouseUp:
            return true
        case .keyUp:
            if let keyCode {
                let arrows: Set<CGKeyCode> = [CGKeyCode(kVK_LeftArrow), CGKeyCode(kVK_RightArrow),
                                              CGKeyCode(kVK_UpArrow), CGKeyCode(kVK_DownArrow)]
                if flags.contains(.maskShift), arrows.contains(keyCode), !flags.contains(.maskControl) {
                    return true
                }
                if keyCode == CGKeyCode(kVK_ANSI_A), flags.contains(.maskCommand),
                   !flags.contains(.maskAlternate), !flags.contains(.maskControl), !flags.contains(.maskShift) {
                    return true
                }
            }
            let hasBlockedModifiers = flags.contains(.maskCommand)
                || flags.contains(.maskControl)
                || flags.contains(.maskAlternate)
            if hasBlockedModifiers {
                return false
            }

            if flags.contains(.maskShift) {
                if let keyCode, modifierKeyCodes.contains(keyCode) {
                    return false
                }
                return true
            }

            guard let keyCode else {
                return false
            }
            return deleteKeyCodes.contains(keyCode)
        default:
            return false
        }
    }

    private func reenableEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func notifyPotentialSelectionChange() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid > 0 else {
            return
        }

        onPotentialSelectionChange?(pid)
    }
}
