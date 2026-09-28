// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

@MainActor
@Observable
final class ModuleRegistry {
    private static let explainModuleID = "explain"
    private static let summarizationModuleID = "summarization"
    private static let explainMigrationKey = "didMigrateExplainModule"
    private static let factCheckModuleID = "fact-check"
    private static let factCheckMigrationKey = "didMigrateFactCheckModule"

    private(set) var modules: [any TextModule] = []
    private var modulesByID: [String: any TextModule] = [:]
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var activeModules: [any TextModule] {
        let enabledIDs = enabledModuleIDs
        let orderedIDs = normalizedOrder(from: moduleOrder, enabledIDs: enabledIDs)
        return orderedIDs.compactMap { module(byId: $0) }
    }

    private var enabledModuleIDs: Set<String> {
        if let ids: [String] = userDefaults.value(for: .enabledModuleIDs) {
            return Set(ids)
        }
        return Set(modules.map { $0.id })
    }

    private var moduleOrder: [String] {
        userDefaults.value(for: .moduleOrder) ?? []
    }

    private var registeredModuleIDs: Set<String> {
        Set(modulesByID.keys)
    }

    func bootstrap(customModules: [CustomPromptModule] = [], persistNormalization: Bool = true) {
        modules.removeAll(keepingCapacity: true)
        modulesByID.removeAll(keepingCapacity: true)

        registerBuiltInModules()
        for module in customModules {
            register(module)
        }

        if persistNormalization { normalizePersistedState() }
        Log.modules.info("Registered \(self.modules.count) modules")
    }

    private func registerBuiltInModules() {
        register(TranslationModule())
        register(GrammarFixModule())
        register(RephrasingModule())
        register(ToneAdjustmentModule())
        register(SummarizationModule())
        register(ExplainModule())
        register(FactCheckModule())
        register(ContentGenerationModule())
    }

    func register(_ module: any TextModule) {
        guard modulesByID[module.id] == nil else { return }
        modules.append(module)
        modulesByID[module.id] = module
    }

    func module(byId id: String) -> (any TextModule)? {
        modulesByID[id]
    }

    func setEnabled(_ enabled: Bool, for moduleId: String) {
        guard registeredModuleIDs.contains(moduleId) else { return }

        var ids = enabledModuleIDs
        var order = normalizedOrder(from: moduleOrder, enabledIDs: ids)

        if enabled {
            ids.insert(moduleId)
            order.removeAll { $0 == moduleId }
            order.append(moduleId)
        } else {
            ids.remove(moduleId)
            order.removeAll { $0 == moduleId }
        }

        userDefaults.set(Array(ids), for: .enabledModuleIDs)
        userDefaults.set(order, for: .moduleOrder)
    }

    func setOrder(_ order: [String]) {
        let normalized = normalizedOrder(from: order, enabledIDs: enabledModuleIDs)
        userDefaults.set(normalized, for: .moduleOrder)
    }

    private func normalizePersistedState() {
        let defaults = userDefaults
        let hasEnabledState = defaults.object(forKey: SettingsKey.enabledModuleIDs.rawValue) != nil
        let hasOrderState = defaults.object(forKey: SettingsKey.moduleOrder.rawValue) != nil
        let shouldMigrateExplain = hasEnabledState && !defaults.bool(forKey: Self.explainMigrationKey)
        let shouldMigrateFactCheck = hasEnabledState && !defaults.bool(forKey: Self.factCheckMigrationKey)

        var normalizedEnabled = enabledModuleIDs.intersection(registeredModuleIDs)

        if shouldMigrateExplain {
            normalizedEnabled.insert(Self.explainModuleID)
            defaults.set(true, forKey: Self.explainMigrationKey)
        }

        if shouldMigrateFactCheck {
            normalizedEnabled.insert(Self.factCheckModuleID)
            defaults.set(true, forKey: Self.factCheckMigrationKey)
        }

        // Prunes IDs of deleted custom modules; an absent key still means "all enabled".
        if hasEnabledState {
            defaults.set(Array(normalizedEnabled), for: .enabledModuleIDs)
        }

        if hasOrderState || hasEnabledState {
            let migratedOrder = hasOrderState
                ? insertFactCheckAfterExplain(
                    order: insertExplainAfterSummarization(
                        order: moduleOrder,
                        enabledIDs: normalizedEnabled,
                        shouldInsertExplain: shouldMigrateExplain
                    ),
                    enabledIDs: normalizedEnabled,
                    shouldInsertFactCheck: shouldMigrateFactCheck
                )
                : moduleOrder
            let normalized = normalizedOrder(from: migratedOrder, enabledIDs: normalizedEnabled)
            defaults.set(normalized, for: .moduleOrder)
        }
    }

    private func insertExplainAfterSummarization(
        order: [String],
        enabledIDs: Set<String>,
        shouldInsertExplain: Bool
    ) -> [String] {
        guard shouldInsertExplain else { return order }
        guard enabledIDs.contains(Self.explainModuleID) else { return order }
        guard !order.isEmpty else { return order }
        guard !order.contains(Self.explainModuleID) else { return order }

        var migrated = order

        if enabledIDs.contains(Self.summarizationModuleID),
           let summaryIndex = migrated.firstIndex(of: Self.summarizationModuleID) {
            migrated.insert(Self.explainModuleID, at: migrated.index(after: summaryIndex))
            return migrated
        }

        migrated.append(Self.explainModuleID)
        return migrated
    }

    private func insertFactCheckAfterExplain(
        order: [String],
        enabledIDs: Set<String>,
        shouldInsertFactCheck: Bool
    ) -> [String] {
        guard shouldInsertFactCheck,
              enabledIDs.contains(Self.factCheckModuleID),
              !order.isEmpty,
              !order.contains(Self.factCheckModuleID) else { return order }

        var migrated = order
        for anchorID in [Self.explainModuleID, Self.summarizationModuleID] where enabledIDs.contains(anchorID) {
            if let anchorIndex = migrated.firstIndex(of: anchorID) {
                migrated.insert(Self.factCheckModuleID, at: migrated.index(after: anchorIndex))
                return migrated
            }
        }

        migrated.append(Self.factCheckModuleID)
        return migrated
    }

    private func normalizedOrder(from rawOrder: [String], enabledIDs: Set<String>) -> [String] {
        let validEnabledIDs = enabledIDs.intersection(registeredModuleIDs)
        var seen = Set<String>()
        var result: [String] = []

        for id in rawOrder where validEnabledIDs.contains(id) {
            if seen.insert(id).inserted {
                result.append(id)
            }
        }

        for module in modules where validEnabledIDs.contains(module.id) {
            if seen.insert(module.id).inserted {
                result.append(module.id)
            }
        }

        return result
    }
}
