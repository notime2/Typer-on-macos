// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import Foundation

/// A local model override; nil continues to follow changes to the global model.
struct ModuleModelDraft: Equatable {
    var customModel: String?

    init(customModel: String? = nil) {
        select(customModel ?? "")
    }

    func effectiveModel(globalModel: String) -> String {
        customModel ?? globalModel
    }

    mutating func select(_ modelID: String) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        customModel = trimmed.isEmpty ? nil : trimmed
    }

    static func catalogAPIKey(
        enteredKey: String,
        storedModuleKey: @autoclosure () -> String?,
        globalKey: @autoclosure () -> String?
    ) -> String {
        let entered = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return entered }
        let stored = storedModuleKey()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        return globalKey()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
