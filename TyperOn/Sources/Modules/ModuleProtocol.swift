// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI
import Carbon.HIToolbox

struct KeyCombo: Codable, Hashable, Sendable {
    let keyCode: UInt16
    let modifiers: UInt

    // MARK: - Default Global Hotkey (Option+F)

    static let defaultGlobalHotkey = KeyCombo(
        keyCode: UInt16(kVK_ANSI_F),
        modifiers: UInt(CGEventFlags.maskAlternate.rawValue)
    )

    // MARK: - Display

    var displayString: String {
        var parts: [String] = []
        let flags = CGEventFlags(rawValue: UInt64(modifiers))
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if flags.contains(.maskCommand) { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    /// NSEvent.modifierFlags → CGEventFlags-compatible UInt
    static func modifiersFromNSEvent(_ flags: NSEvent.ModifierFlags) -> UInt {
        var cg: UInt64 = 0
        if flags.contains(.command) { cg |= CGEventFlags.maskCommand.rawValue }
        if flags.contains(.shift) { cg |= CGEventFlags.maskShift.rawValue }
        if flags.contains(.option) { cg |= CGEventFlags.maskAlternate.rawValue }
        if flags.contains(.control) { cg |= CGEventFlags.maskControl.rawValue }
        return UInt(cg)
    }

    /// keyCode → NSEvent-compatible keyEquivalent character (for NSMenuItem)
    var keyEquivalentCharacter: String {
        Self.keyCharacter(for: keyCode)
    }

    /// Carbon modifier mask for RegisterEventHotKey
    var carbonModifiers: UInt32 {
        let cg = CGEventFlags(rawValue: UInt64(modifiers))
        var carbon: UInt32 = 0
        if cg.contains(.maskCommand) { carbon |= UInt32(cmdKey) }
        if cg.contains(.maskShift) { carbon |= UInt32(shiftKey) }
        if cg.contains(.maskAlternate) { carbon |= UInt32(optionKey) }
        if cg.contains(.maskControl) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// NSEvent.ModifierFlags built from stored modifiers
    var nsEventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        let cg = CGEventFlags(rawValue: UInt64(modifiers))
        if cg.contains(.maskCommand) { flags.insert(.command) }
        if cg.contains(.maskShift) { flags.insert(.shift) }
        if cg.contains(.maskAlternate) { flags.insert(.option) }
        if cg.contains(.maskControl) { flags.insert(.control) }
        return flags
    }

    // MARK: - Persistence

    static func load(from defaults: UserDefaults = .standard, key: SettingsKey = .globalHotkey) -> KeyCombo? {
        guard let data = defaults.data(for: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard, key: SettingsKey = .globalHotkey) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, for: key)
        }
    }

    // MARK: - Key Name Mapping

    private static func keyName(for keyCode: UInt16) -> String {
        keyNameMap[keyCode] ?? "Key\(keyCode)"
    }

    private static func keyCharacter(for keyCode: UInt16) -> String {
        keyCharMap[keyCode] ?? ""
    }

    private static let keyNameMap: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
        UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
        UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
        UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
        UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
        UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
        UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9",
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "Return", UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Delete): "Delete", UInt16(kVK_ForwardDelete): "Fwd Delete",
        UInt16(kVK_Escape): "Esc",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "Home", UInt16(kVK_End): "End",
        UInt16(kVK_PageUp): "Page Up", UInt16(kVK_PageDown): "Page Down",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_Equal): "=",
        UInt16(kVK_ANSI_LeftBracket): "[", UInt16(kVK_ANSI_RightBracket): "]",
        UInt16(kVK_ANSI_Semicolon): ";", UInt16(kVK_ANSI_Quote): "'",
        UInt16(kVK_ANSI_Comma): ",", UInt16(kVK_ANSI_Period): ".",
        UInt16(kVK_ANSI_Slash): "/", UInt16(kVK_ANSI_Backslash): "\\",
        UInt16(kVK_ANSI_Grave): "`",
    ]

    private static let keyCharMap: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "a", UInt16(kVK_ANSI_B): "b", UInt16(kVK_ANSI_C): "c",
        UInt16(kVK_ANSI_D): "d", UInt16(kVK_ANSI_E): "e", UInt16(kVK_ANSI_F): "f",
        UInt16(kVK_ANSI_G): "g", UInt16(kVK_ANSI_H): "h", UInt16(kVK_ANSI_I): "i",
        UInt16(kVK_ANSI_J): "j", UInt16(kVK_ANSI_K): "k", UInt16(kVK_ANSI_L): "l",
        UInt16(kVK_ANSI_M): "m", UInt16(kVK_ANSI_N): "n", UInt16(kVK_ANSI_O): "o",
        UInt16(kVK_ANSI_P): "p", UInt16(kVK_ANSI_Q): "q", UInt16(kVK_ANSI_R): "r",
        UInt16(kVK_ANSI_S): "s", UInt16(kVK_ANSI_T): "t", UInt16(kVK_ANSI_U): "u",
        UInt16(kVK_ANSI_V): "v", UInt16(kVK_ANSI_W): "w", UInt16(kVK_ANSI_X): "x",
        UInt16(kVK_ANSI_Y): "y", UInt16(kVK_ANSI_Z): "z",
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9",
        UInt16(kVK_Space): " ", UInt16(kVK_Return): "\r", UInt16(kVK_Tab): "\t",
        UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_Equal): "=",
        UInt16(kVK_ANSI_LeftBracket): "[", UInt16(kVK_ANSI_RightBracket): "]",
        UInt16(kVK_ANSI_Semicolon): ";", UInt16(kVK_ANSI_Quote): "'",
        UInt16(kVK_ANSI_Comma): ",", UInt16(kVK_ANSI_Period): ".",
        UInt16(kVK_ANSI_Slash): "/", UInt16(kVK_ANSI_Backslash): "\\",
        UInt16(kVK_ANSI_Grave): "`",
    ]
}

struct ModuleContext: Sendable {
    var targetLanguage: String
    var outputLanguageMode: ModuleOutputLanguageMode
    var sourceLanguageName: String?
    var userComment: String?
    var customSystemPrompt: String?
    /// The language Translate targets when the input already matches `targetLanguage`.
    /// `nil` lets the module apply its own English fallback.
    var fallbackTargetLanguage: String?

    static let `default` = ModuleContext(
        targetLanguage: "English",
        outputLanguageMode: .defaultLanguage,
        sourceLanguageName: nil,
        customSystemPrompt: nil
    )
}

protocol TextModule: Identifiable, Hashable, Sendable {
    var id: String { get }
    var name: String { get }
    var icon: String { get }
    var shortDescription: String? { get }
    var category: ModuleCategory { get }

    func buildPrompt(for inputText: String, context: ModuleContext) -> [ChatMessage]
    func postProcess(response: String, originalText: String) -> String
}

extension TextModule {
    var shortDescription: String? { nil }

    func postProcess(response: String, originalText: String) -> String {
        response
    }

    func resolvedSystemPrompt(defaultPrompt: String, context: ModuleContext) -> String {
        let trimmed = context.customSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultPrompt : trimmed
    }

    func resolvedOutputLanguageName(context: ModuleContext) -> String {
        switch context.outputLanguageMode {
        case .defaultLanguage:
            return context.targetLanguage
        case .sourceLanguage:
            return context.sourceLanguageName ?? "same language as the input text"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}
