// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

/// A view-owned single-entry cache. Streaming replaces the entry; completed
/// messages keep their parsed value until the owning view leaves the session.
@MainActor
final class MarkdownTextCache<Value> {
    private var cachedText: String?
    private var cachedValue: Value?

    func value(for text: String, parse: (String) -> Value) -> Value {
        if cachedText == text, let cachedValue { return cachedValue }
        let value = parse(text)
        cachedText = text
        cachedValue = value
        return value
    }
}
