// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct ModelMenuModuleInfo: Equatable {
    let id: String
    let name: String
    let isEnabled: Bool
}

struct ModelMenuOverrideEntry: Equatable {
    let modelId: String
    let moduleLabels: [String]
}

enum ModelMenuStateBuilder {
    static func moduleOverrideEntries(
        modules: [ModelMenuModuleInfo],
        configs: [String: ModuleAIConfig]
    ) -> [ModelMenuOverrideEntry] {
        var grouped: [String: [String]] = [:]

        for module in modules {
            guard let config = configs[module.id], !config.useGlobal else { continue }
            guard let rawModelId = config.customModel else { continue }

            let modelId = rawModelId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelId.isEmpty else { continue }

            let label = module.isEnabled ? module.name : "\(module.name) (disabled)"
            grouped[modelId, default: []].append(label)
        }

        return grouped.map { modelId, labels in
            ModelMenuOverrideEntry(
                modelId: modelId,
                moduleLabels: labels.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
            )
        }
        .sorted { lhs, rhs in
            lhs.modelId.localizedCaseInsensitiveCompare(rhs.modelId) == .orderedAscending
        }
    }
}
