// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

struct ModelPickerView: View {
    let catalog: ModelCatalogService
    let clipboardManager: ClipboardManager
    @Binding var selectedModelId: String
    let apiKey: String
    /// A refresh target for an endpoint being edited; `nil` refreshes whatever source the catalog already shows.
    var source: ModelCatalogSource?
    /// Off where the host already reports the catalog failure next to its own actions.
    var showsCatalogError = true

    @State private var searchText = ""
    @State private var customModelId = ""
    @State private var showCustomInput = false
    @State private var copiedModelId: String?

    private var filteredGroups: [(provider: String, models: [OpenRouterModel])] {
        catalog.groups(matching: searchText)
    }

    /// A subscription CLI lists its own models and runs its default one until a model is chosen.
    private var isSubscriptionCatalog: Bool {
        catalog.source.provider.isSubscription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            // Search + Refresh
            HStack(spacing: DS.Spacing.sm) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DS.Colors.textTertiary)
                        .font(.system(size: 12))
                    TextField("Search models...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DS.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 5)
                .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.button))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.button).stroke(DS.Colors.separator, lineWidth: 0.5))

                Button {
                    let activeSource = catalog.source
                    Task {
                        guard catalog.source == activeSource else { return }
                        await catalog.fetchModels(apiKey: apiKey, source: source ?? activeSource)
                    }
                } label: {
                    Image(systemName: catalog.isLoading ? "arrow.trianglehead.2.clockwise" : "arrow.trianglehead.2.clockwise")
                        .font(.system(size: 12))
                        .rotationEffect(catalog.isLoading ? .degrees(360) : .zero)
                        .animation(catalog.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: catalog.isLoading)
                }
                .buttonStyle(.glass)
                .disabled(catalog.isLoading)
                .help("Refresh model list")
            }

            // Current selection
            HStack(spacing: DS.Spacing.sm) {
                Text("Selected:")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textTertiary)
                Text(
                    selectedModelId.isEmpty
                        ? (isSubscriptionCatalog ? "Default" : "Not selected")
                        : catalog.displayName(for: selectedModelId)
                )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selectedModelId.isEmpty ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                    .lineLimit(1)
            }

            // Model list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredGroups.isEmpty {
                        Text(
                            isSubscriptionCatalog && searchText.isEmpty
                                ? "No models loaded. Check the connection to list this CLI's models."
                                : "No models found"
                        )
                            .font(.system(size: 12))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(DS.Spacing.md)
                    }
                    ForEach(filteredGroups, id: \.provider) { group in
                        // Provider header
                        Text(group.provider)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .textCase(.uppercase)
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.top, DS.Spacing.sm)
                            .padding(.bottom, 2)

                        ForEach(group.models) { model in
                            modelRow(model)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.Colors.separator, lineWidth: 0.5))

            // Custom model input
            HStack(spacing: DS.Spacing.sm) {
                if showCustomInput {
                    TextField(isSubscriptionCatalog ? "Model ID" : "provider/model-name", text: $customModelId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onSubmit {
                            applyCustomModel()
                        }

                    Button("Apply") {
                        applyCustomModel()
                    }
                    .buttonStyle(.glass)
                    .disabled(customModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Cancel") {
                        showCustomInput = false
                        customModelId = ""
                    }
                    .buttonStyle(.glass)
                } else {
                    Button("Custom Model ID...") {
                        customModelId = selectedModelId
                        showCustomInput = true
                    }
                    .font(.system(size: 12))
                    .buttonStyle(.glass)
                }
            }

            if showsCatalogError, let error = catalog.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private func modelRow(_ model: OpenRouterModel) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Button {
                selectedModelId = model.id
            } label: {
                HStack {
                    Image(systemName: selectedModelId == model.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedModelId == model.id ? DS.Colors.accent : DS.Colors.textTertiary)
                        .font(.system(size: 12))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.displayName)
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text(model.id)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if let ctx = model.context_length, ctx > 0 {
                        Text(Self.formatContextLength(ctx))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DS.Colors.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                clipboardManager.write(model.id)
                withAnimation(.easeInOut(duration: 0.2)) {
                    copiedModelId = model.id
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if copiedModelId == model.id {
                            copiedModelId = nil
                        }
                    }
                }
            } label: {
                Image(systemName: copiedModelId == model.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copiedModelId == model.id ? .green : DS.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help("Copy model ID")
            .accessibilityLabel("Copy model ID")
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, 4)
        .background(selectedModelId == model.id ? DS.Colors.surfaceHover : Color.clear)
    }

    private func applyCustomModel() {
        let trimmed = customModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedModelId = trimmed
        showCustomInput = false
        customModelId = ""
    }

    private static func formatContextLength(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return "\(tokens / 1_000_000)M ctx"
        } else {
            return "\(tokens / 1_000)K ctx"
        }
    }
}
