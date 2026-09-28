// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Testing
@testable import Typer_On

struct TargetLanguageCatalogTests {
    @Test
    func savedLanguageWinsOverSystemLanguages() {
        #expect(TargetLanguageCatalog.resolveDefaultLanguage(saved: "German", preferredLanguages: ["ru-RU"]) == "German")
    }

    @Test
    func blankSavedValueFallsBackToSystemLanguage() {
        #expect(TargetLanguageCatalog.resolveDefaultLanguage(saved: "  ", preferredLanguages: ["fr-FR"]) == "French")
        #expect(TargetLanguageCatalog.resolveDefaultLanguage(saved: nil, preferredLanguages: ["ru-RU", "en-US"]) == "Russian")
    }

    @Test
    func firstSupportedSystemLanguageWins() {
        #expect(TargetLanguageCatalog.resolveDefaultLanguage(saved: nil, preferredLanguages: ["sv-SE", "de-DE", "en-US"]) == "German")
    }

    @Test
    func scriptAndRegionSubtagsAreIgnored() {
        #expect(TargetLanguageCatalog.resolveDefaultLanguage(saved: nil, preferredLanguages: ["pt-BR"]) == "Portuguese")
        #expect(TargetLanguageCatalog.resolveDefaultLanguage(saved: nil, preferredLanguages: ["zh-Hant-TW"]) == "Chinese")
        #expect(TargetLanguageCatalog.resolveDefaultLanguage(saved: nil, preferredLanguages: ["zh-Hans-CN"]) == "Chinese")
        #expect(TargetLanguageCatalog.resolveDefaultLanguage(saved: nil, preferredLanguages: ["en_GB"]) == "English")
    }

    @Test
    func unsupportedOrEmptySystemLanguagesFallBackToEnglish() {
        #expect(TargetLanguageCatalog.resolveDefaultLanguage(saved: nil, preferredLanguages: []) == "English")
        #expect(TargetLanguageCatalog.resolveDefaultLanguage(saved: nil, preferredLanguages: ["sv-SE", ""]) == "English")
    }

    @Test
    func translationFallbackIsEnglishForNonEnglishDefault() {
        #expect(TargetLanguageCatalog.translationFallbackLanguage(for: "Russian", preferredLanguages: ["en-US"]) == "English")
        #expect(TargetLanguageCatalog.translationFallbackLanguage(for: "Chinese", preferredLanguages: []) == "English")
    }

    @Test
    func translationFallbackForEnglishDefaultIsNextSupportedSystemLanguage() {
        #expect(TargetLanguageCatalog.translationFallbackLanguage(for: "English", preferredLanguages: ["en-US", "ru-RU"]) == "Russian")
        #expect(TargetLanguageCatalog.translationFallbackLanguage(for: "english", preferredLanguages: ["en-GB", "sv-SE", "fr-FR"]) == "French")
    }

    @Test
    func translationFallbackIsNilWhenEnglishIsTheOnlySystemLanguage() {
        #expect(TargetLanguageCatalog.translationFallbackLanguage(for: "English", preferredLanguages: ["en-US", "en-GB"]) == nil)
        #expect(TargetLanguageCatalog.translationFallbackLanguage(for: "English", preferredLanguages: []) == nil)
    }

    @Test
    func detectedLanguageCodesMapOntoSupportedNames() {
        #expect(TargetLanguageCatalog.supportedLanguageName(forLanguageIdentifier: "zh-Hant") == "Chinese")
        #expect(TargetLanguageCatalog.supportedLanguageName(forLanguageIdentifier: "zh-Hans") == "Chinese")
        #expect(TargetLanguageCatalog.supportedLanguageName(forLanguageIdentifier: "uk") == "Ukrainian")
        #expect(TargetLanguageCatalog.supportedLanguageName(forLanguageIdentifier: "sv") == nil)
        #expect(TargetLanguageCatalog.supportedLanguageName(forLanguageIdentifier: "") == nil)
    }

    @Test
    func sameLanguageComparisonIgnoresCaseAndWhitespace() {
        #expect(TargetLanguageCatalog.isSameLanguage(" Russian ", "russian"))
        #expect(!TargetLanguageCatalog.isSameLanguage("Russian", "Ukrainian"))
    }

    @Test
    func supportedListContainsEveryMappedNameOnce() {
        let names = TargetLanguageCatalog.supportedLanguages
        #expect(Set(names).count == names.count)
        #expect(names.contains(TargetLanguageCatalog.universalFallbackLanguage))
    }
}
