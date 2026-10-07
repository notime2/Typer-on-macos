// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

struct CustomPromptsSettingsView: View {
    let environment: AppEnvironment
    @ObservedObject var state: SettingsWindowState

    @State private var editingPrompt: CustomPromptDefinition?

    // New prompt fields
    @State private var newName = ""
    @State private var newShortDescription = ""
    @State private var newIcon = "star"
    @State private var newSystemPrompt = ""

    private let iconOptions = [
        "star", "bolt", "wand.and.stars", "text.quote", "doc.text",
        "envelope", "bubble.left", "pencil", "checkmark.circle", "hand.thumbsup"
    ]

    init(
        environment: AppEnvironment,
        state: SettingsWindowState
    ) {
        self.environment = environment
        self.state = state
    }

    private var store: CustomPromptStore {
        environment.customPromptStore
    }

    private func trimmedShortDescription(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        contentContainer
    }

    private var contentContainer: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DS.Colors.background)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xl) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.md) {
                Text("Create your own modules with custom AI instructions for quick access from the toolbar.")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button {
                    if state.isAddingCustomPrompt {
                        state.cancelCustomPromptCreation()
                    } else {
                        state.beginCustomPromptCreation(returnToModules: false)
                    }
                    resetFields()
                } label: {
                    Image(systemName: state.isAddingCustomPrompt ? "minus.circle" : "plus.circle")
                    Text(state.isAddingCustomPrompt ? "Cancel" : "Add Module")
                }
                .font(.system(size: 13))
                .buttonStyle(.glass)
                .fixedSize(horizontal: true, vertical: false)
            }

            if state.isAddingCustomPrompt {
                promptEditor(isNew: true)
            }

            if store.prompts.isEmpty && !state.isAddingCustomPrompt {
                VStack(spacing: DS.Spacing.md) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(DS.Colors.textTertiary)
                    Text("No custom modules yet")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.xxl)
            }

            ForEach(store.prompts) { prompt in
                promptRow(prompt)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.background)
    }

    private func promptRow(_ prompt: CustomPromptDefinition) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: prompt.icon)
                    .frame(width: 24)
                    .foregroundStyle(DS.Colors.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(prompt.name)
                        .font(.system(size: 14, weight: .medium))

                    if let shortDescription = trimmedShortDescription(prompt.shortDescription) {
                        Text(shortDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textTertiary)
                    }
                }

                Spacer()

                Button {
                    editingPrompt = prompt
                    newName = prompt.name
                    newShortDescription = trimmedShortDescription(prompt.shortDescription) ?? ""
                    newIcon = prompt.icon
                    newSystemPrompt = prompt.systemPrompt
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Colors.textTertiary)

                Button {
                    store.delete(id: prompt.id)
                    environment.reloadModules()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.7))
            }
            .padding(DS.Spacing.md)

            if editingPrompt?.id == prompt.id {
                Divider().foregroundStyle(DS.Colors.separator)
                promptEditor(isNew: false)
                    .padding(DS.Spacing.md)
            }

            Text(prompt.systemPrompt)
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(2)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.md)
        }
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.Colors.separator, lineWidth: 0.5))
    }

    private func promptEditor(isNew: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            TextField("Module Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))

            TextField("Short Description (optional)", text: $newShortDescription)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))

            HStack(spacing: DS.Spacing.sm) {
                Text("Icon:").font(.system(size: 13)).foregroundStyle(DS.Colors.textSecondary)
                ForEach(iconOptions, id: \.self) { icon in
                    Button {
                        newIcon = icon
                    } label: {
                        Image(systemName: icon)
                            .frame(width: 28, height: 28)
                            .background(
                                newIcon == icon ? DS.Colors.accent.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: DS.Radius.button)
                            )
                            .foregroundStyle(newIcon == icon ? DS.Colors.accent : DS.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("System Prompt").font(.system(size: 13)).foregroundStyle(DS.Colors.textSecondary)

            TextEditor(text: $newSystemPrompt)
                .font(.system(size: 13))
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.button).stroke(DS.Colors.separator, lineWidth: 0.5))

            HStack {
                Spacer()
                Button(isNew ? "Create Module" : "Update Module") {
                    if isNew {
                        let prompt = CustomPromptDefinition(
                            name: newName,
                            icon: newIcon,
                            shortDescription: newShortDescription,
                            systemPrompt: newSystemPrompt
                        )
                        store.add(prompt)
                        environment.reloadModules()
                        environment.moduleRegistry.setEnabled(true, for: prompt.id)
                        state.completeCustomPromptCreation()
                    } else if var editing = editingPrompt {
                        editing.name = newName
                        editing.shortDescription = newShortDescription
                        editing.icon = newIcon
                        editing.systemPrompt = newSystemPrompt
                        store.update(editing)
                        environment.reloadModules()
                        editingPrompt = nil
                    }
                    resetFields()
                }
                .buttonStyle(.glassProminent)
                .disabled(newName.isEmpty || newSystemPrompt.isEmpty)
            }
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.background, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func resetFields() {
        newName = ""
        newShortDescription = ""
        newIcon = "star"
        newSystemPrompt = ""
    }
}
