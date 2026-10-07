// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation

struct CustomPromptDefinition: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var icon: String
    var shortDescription: String?
    var systemPrompt: String

    init(name: String, icon: String = "star", shortDescription: String? = nil, systemPrompt: String) {
        self.id = "custom-\(UUID().uuidString.prefix(8).lowercased())"
        self.name = name
        self.icon = icon
        self.shortDescription = Self.normalizedShortDescription(shortDescription)
        self.systemPrompt = systemPrompt
    }

    private static func normalizedShortDescription(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func normalized() -> CustomPromptDefinition {
        var normalized = self
        normalized.shortDescription = Self.normalizedShortDescription(shortDescription)
        return normalized
    }
}

@MainActor
@Observable
final class CustomPromptStore {
    private(set) var prompts: [CustomPromptDefinition] = []

    init() {
        load()
    }

    func add(_ prompt: CustomPromptDefinition) {
        prompts.append(prompt.normalized())
        save()
    }

    func update(_ prompt: CustomPromptDefinition) {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        prompts[index] = prompt.normalized()
        save()
    }

    func delete(id: String) {
        prompts.removeAll { $0.id == id }
        save()
    }

    func toModules() -> [CustomPromptModule] {
        prompts.map { definition in
            CustomPromptModule(
                id: definition.id,
                name: definition.name,
                icon: definition.icon,
                shortDescription: definition.shortDescription,
                systemPrompt: definition.systemPrompt
            )
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(for: .customPrompts),
              let decoded = try? JSONDecoder().decode([CustomPromptDefinition].self, from: data) else {
            return
        }
        prompts = decoded.map { $0.normalized() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(prompts) else { return }
        UserDefaults.standard.set(data, for: .customPrompts)
    }
}
