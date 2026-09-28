// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import Combine
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let environment: AppEnvironment

    private static let hasSeenOnboardingKey = "hasSeenOnboarding"

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    static var needsOnboarding: Bool {
        !UserDefaults.standard.bool(forKey: hasSeenOnboardingKey)
    }

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingView(
            environment: environment,
            onOpenAPISettings: { [weak self] in
                self?.environment.showSettings(tab: .api)
            },
            onRunTestAction: {
                NotificationCenter.default.post(name: .openChatRequested, object: nil)
            }
        ) {
            UserDefaults.standard.set(true, forKey: Self.hasSeenOnboardingKey)
            self.window?.close()
        }

        let hostingView = NSHostingView(rootView: onboardingView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "Welcome to Typer On"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}

struct OnboardingView: View {
    let environment: AppEnvironment
    let onOpenAPISettings: () -> Void
    let onRunTestAction: () -> Void
    let onComplete: () -> Void

    @State private var axGranted = false
    @State private var hasAPIKey = false
    @State private var hasCompletedTestAction = false

    private var canComplete: Bool {
        axGranted && hasAPIKey && hasCompletedTestAction
    }

    private var providerSettings: AIProviderSettings {
        UserDefaults.standard.aiProviderSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xl) {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Label("Welcome to Typer On", systemImage: "sparkles")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)

                Text("Complete this checklist to make sure the first real action works end-to-end.")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Colors.textSecondary)
            }

            VStack(spacing: DS.Spacing.md) {
                checklistRow(
                    icon: "hand.raised",
                    title: "Grant Accessibility",
                    description: "Typer On needs Accessibility access to detect selection and replace text in other apps.",
                    isComplete: axGranted,
                    actionTitle: axGranted ? "Granted" : "Open Accessibility Settings",
                    secondaryActionTitle: axGranted ? nil : "Refresh",
                    action: openAccessibilitySettings,
                    secondaryAction: refreshStatus
                )

                checklistRow(
                    icon: "key",
                    title: providerSettings.provider == .openRouter
                        ? "Add OpenRouter API Key"
                        : "Configure Local Endpoint",
                    description: providerSettings.provider == .openRouter
                        ? "Open Settings -> API and save a valid key. Typer On uses your own key and model selection."
                        : "Open Settings -> API and save the base URL of your OpenAI-compatible server, then pick a model.",
                    isComplete: hasAPIKey,
                    actionTitle: "Open API Settings",
                    secondaryActionTitle: "Refresh",
                    action: onOpenAPISettings,
                    secondaryAction: refreshStatus
                )

                checklistRow(
                    icon: "bubble.left.and.text.bubble.right",
                    title: "Run a Test Action",
                    description: "Open the chat window once to confirm the app is ready for your first real action.",
                    isComplete: hasCompletedTestAction,
                    actionTitle: "Open Chat Window",
                    secondaryActionTitle: nil,
                    action: runTestAction,
                    secondaryAction: nil
                )
            }

            HStack {
                Spacer()

                if canComplete {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.green)
                }

                Button("Get Started") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canComplete)
            }
        }
        .onAppear {
            refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
        .padding(.horizontal, DS.Spacing.xxl)
        .padding(.vertical, DS.Spacing.xl)
        .frame(width: 540, height: 460)
        .background(DS.Colors.background)
    }

    @ViewBuilder
    private func checklistRow(
        icon: String,
        title: String,
        description: String,
        isComplete: Bool,
        actionTitle: String,
        secondaryActionTitle: String?,
        action: @escaping () -> Void,
        secondaryAction: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .top, spacing: DS.Spacing.md) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isComplete ? .green : DS.Colors.accent)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))

                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.textSecondary)
                }

                Spacer()
            }

            HStack(spacing: DS.Spacing.sm) {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.bordered)

                if let secondaryActionTitle, let secondaryAction {
                    Button(secondaryActionTitle) {
                        secondaryAction()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
            .padding(.leading, 34)
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .stroke(DS.Colors.separator, lineWidth: 0.5)
        )
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        refreshStatus()
    }

    private func runTestAction() {
        onRunTestAction()
        hasCompletedTestAction = true
    }

    private func refreshStatus() {
        axGranted = AXIsProcessTrusted()
        let settings = providerSettings
        hasAPIKey = AIProviderReadiness.isConfigured(
            provider: settings.provider,
            hasOpenRouterKey: environment.keychainService.getGlobalAPIKey()?.isEmpty == false,
            localBaseURL: settings.localBaseURL
        )
    }
}
