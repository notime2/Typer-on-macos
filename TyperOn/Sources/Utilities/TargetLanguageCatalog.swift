// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

/// The languages the default target language can take, plus the rules that map
/// system locale identifiers and detected languages onto that list.
enum TargetLanguageCatalog {
    /// Display names in the order the Settings picker shows them.
    static let supportedLanguages: [String] = [
        "Russian", "English", "German", "French", "Spanish",
        "Japanese", "Chinese", "Italian", "Portuguese", "Korean",
        "Dutch", "Polish", "Turkish", "Arabic", "Hindi", "Ukrainian"
    ]

    /// Used when neither a saved choice nor the system languages map to a supported language,
    /// and as the Translate fallback for every non-English default.
    static let universalFallbackLanguage = "English"

    private static let codesByLowercasedName: [String: String] = [
        "russian": "ru", "english": "en", "german": "de", "french": "fr", "spanish": "es",
        "japanese": "ja", "chinese": "zh", "italian": "it", "portuguese": "pt", "korean": "ko",
        "dutch": "nl", "polish": "pl", "turkish": "tr", "arabic": "ar", "hindi": "hi",
        "ukrainian": "uk"
    ]

    private static let namesByCode: [String: String] = Dictionary(
        uniqueKeysWithValues: supportedLanguages.compactMap { name in
            codesByLowercasedName[name.lowercased()].map { ($0, name) }
        }
    )

    /// The effective default language: the saved choice, otherwise the first system
    /// language that is supported, otherwise English.
    static func resolveDefaultLanguage(saved: String?, preferredLanguages: [String]) -> String {
        if let saved = saved?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        return firstSupportedLanguage(in: preferredLanguages) ?? universalFallbackLanguage
    }

    /// The language Translate targets when the input is already in `defaultLanguage`:
    /// English, or for an English default the first other supported system language.
    /// `nil` means no distinct alternative exists.
    static func translationFallbackLanguage(for defaultLanguage: String, preferredLanguages: [String]) -> String? {
        if !isSameLanguage(defaultLanguage, universalFallbackLanguage) {
            return universalFallbackLanguage
        }
        return firstSupportedLanguage(in: preferredLanguages, excluding: defaultLanguage)
    }

    /// The first supported display name among locale identifiers such as `en-US` or `zh-Hant-TW`.
    static func firstSupportedLanguage(in preferredLanguages: [String], excluding excluded: String? = nil) -> String? {
        for identifier in preferredLanguages {
            guard let name = supportedLanguageName(forLanguageIdentifier: identifier) else { continue }
            if let excluded, isSameLanguage(name, excluded) { continue }
            return name
        }
        return nil
    }

    /// The supported display name for a language identifier, ignoring script and region
    /// subtags, so `zh-Hans`, `zh-Hant` and `zh-Hant-TW` all resolve to `Chinese`.
    static func supportedLanguageName(forLanguageIdentifier identifier: String) -> String? {
        guard let code = baseLanguageCode(of: identifier) else { return nil }
        return namesByCode[code]
    }

    /// Whether two display names denote the same language, ignoring case and surrounding whitespace.
    static func isSameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func baseLanguageCode(of identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let code = Locale.Language(identifier: trimmed).languageCode?.identifier, !code.isEmpty {
            return code.lowercased()
        }
        return trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() }
    }
}
