// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI
import Carbon.HIToolbox

struct HotkeyRecorderView: View {
    let combo: KeyCombo
    let onRecord: (KeyCombo) -> Void
    var onRecordingChanged: ((Bool) -> Void)?

    @State private var isRecording = false
    @State private var localMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(isRecording ? "Press shortcut..." : combo.displayString)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(isRecording ? DS.Colors.accent : DS.Colors.textPrimary)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, 4)
                    .frame(minWidth: 120)
                    .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.button))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.button)
                            .stroke(isRecording ? DS.Colors.accent : DS.Colors.separator, lineWidth: isRecording ? 1.5 : 0.5)
                    )
                    .animation(DS.Animation.quick, value: isRecording)
            }
            .buttonStyle(.plain)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        onRecordingChanged?(true)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Escape cancels recording
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }

            // Only process keyDown, not flagsChanged alone
            guard event.type == .keyDown else { return nil }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Require at least one modifier (Cmd, Ctrl, or Option)
            guard mods.contains(.command) || mods.contains(.control) || mods.contains(.option) else {
                return nil
            }

            let newCombo = KeyCombo(
                keyCode: event.keyCode,
                modifiers: KeyCombo.modifiersFromNSEvent(mods)
            )
            onRecord(newCombo)
            stopRecording()
            return nil // consume the event
        }
    }

    private func stopRecording() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if isRecording {
            isRecording = false
            onRecordingChanged?(false)
        }
    }
}
