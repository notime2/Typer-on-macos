// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import NaturalLanguage
import Foundation

extension String {
    static let defaultLanguageDetectionFallback = "same language as the input text"

    var detectedLanguage: NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(self)
        return recognizer.dominantLanguage
    }

    var detectedLanguageCode: String? {
        detectedLanguage?.rawValue
    }

    var isEnglish: Bool {
        detectedLanguage == .english
    }

    var detectedLanguageDisplayName: String {
        guard let code = detectedLanguageCode else {
            return Self.defaultLanguageDetectionFallback
        }

        if let mapped = TargetLanguageCatalog.supportedLanguageName(forLanguageIdentifier: code) {
            return mapped
        }

        if let localized = Locale(identifier: "en_US_POSIX").localizedString(forLanguageCode: code),
           !localized.isEmpty {
            return localized.capitalized
        }

        return Self.defaultLanguageDetectionFallback
    }
}
