// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import SwiftUI

/// Adapted from MeetingRecorder's CodexReasoningEffortSlider: a native discrete
/// slider with the CLI default first, and unavailable model levels locked.
struct SubscriptionReasoningEffortSlider: View {
    let efforts: [ReasoningEffortOption]
    let availableEffortIDs: Set<String>
    let selectedEffortID: String?
    let selectedModelName: String?
    let isEnabled: Bool
    let onSelect: (String?) -> Void

    private struct Option: Identifiable {
        let id: String
        let effortID: String?
        let title: String
        let detail: String
    }

    private var options: [Option] {
        [Option(id: "default", effortID: nil, title: "Default", detail: "Uses the CLI's default reasoning level.")]
            + efforts.map { Option(id: $0.id, effortID: $0.id, title: $0.displayName, detail: $0.detail) }
    }

    var body: some View {
        Slider(value: sliderValue, in: 0...Double(max(options.count - 1, 1)), step: 1) {
            Text("Reasoning Effort")
        } tick: { value in
            let index = Int(value.rounded())
            guard options.indices.contains(index) else { return nil }
            return SliderTick(value) { tickLabel(options[index]) }
        }
        // Native tick labels cache their content. Refresh capability changes without
        // rebuilding the slider on every value change during a drag.
        .id(availableEffortIDs)
        .id(efforts)
        .labelsHidden()
        .disabled(!isEnabled)
        .accessibilityLabel("Reasoning Effort")
        .accessibilityValue(options[selectedIndex].title)
    }

    private var selectedIndex: Int {
        options.firstIndex { $0.effortID == selectedEffortID } ?? 0
    }

    private var sliderValue: Binding<Double> {
        Binding(get: { Double(selectedIndex) }, set: { selectAvailableOption(at: Int($0.rounded())) })
    }

    private func isAvailable(_ option: Option) -> Bool {
        option.effortID.map { availableEffortIDs.contains($0) } ?? true
    }

    private func tickLabel(_ option: Option) -> some View {
        let available = isAvailable(option)
        return HStack(spacing: 2) {
            if !available { Image(systemName: "lock.fill").imageScale(.small) }
            Text(option.title)
        }
        .font(.caption)
        .foregroundStyle(available ? Color.secondary : .secondary.opacity(0.4))
        .lineLimit(1)
        .help(available ? option.detail : "Unavailable for \(selectedModelName ?? "this model").")
    }

    private func selectAvailableOption(at proposedIndex: Int) {
        guard isEnabled, options.indices.contains(proposedIndex), proposedIndex != selectedIndex else { return }
        let direction = proposedIndex >= selectedIndex ? 1 : -1
        var index = proposedIndex
        while options.indices.contains(index) {
            let option = options[index]
            if isAvailable(option) {
                onSelect(option.effortID)
                return
            }
            index += direction
        }
    }
}
