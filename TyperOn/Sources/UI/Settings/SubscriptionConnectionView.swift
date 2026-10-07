// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import AppKit
import SwiftUI

/// What a catalog already knows about a subscription CLI. Reading it never launches the CLI,
/// so the status bar and onboarding can show it while they draw.
enum SubscriptionConnectionState: Equatable {
    case notChecked
    case checking
    case ready
    case executableMissing
    /// The result message distinguishes sign-in, startup and other connection failures.
    case connectionFailed

    @MainActor
    init(catalog: ModelCatalogService) {
        if catalog.isLoading {
            self = .checking
        } else if let result = catalog.subscriptionConnectionResult {
            if result.isReady {
                self = .ready
            } else {
                // A check that could not resolve an executable has no path to report.
                self = result.executablePath == nil ? .executableMissing : .connectionFailed
            }
        } else {
            self = .notChecked
        }
    }

    var label: String {
        switch self {
        case .notChecked: "Not Checked"
        case .checking: "Checking..."
        case .ready: "Signed In"
        case .executableMissing: "CLI Not Found"
        case .connectionFailed: "Connection Failed"
        }
    }
}

/// The Codex / Claude Code block of `Settings -> API \ Models`: sign-in state, executable and
/// the actions on them. It edits the settings draft only and never reads the CLI's credentials.
struct SubscriptionConnectionView: View {
    let provider: AIProvider
    /// The catalog whose check result is shown.
    let statusCatalog: ModelCatalogService
    /// An explicit executable; `nil` searches the usual install locations.
    @Binding var executablePath: String?
    let onCheckConnection: () -> Void

    @State private var signInNote: String?

    private var cliName: String {
        provider == .codex ? "Codex CLI" : "Claude Code CLI"
    }

    private var accountName: String {
        provider == .codex ? "ChatGPT" : "Claude"
    }

    private var signInArguments: String {
        provider == .codex ? "login" : "auth login"
    }

    var body: some View {
        let state = SubscriptionConnectionState(catalog: statusCatalog)
        let executable = try? SubscriptionCLI.resolveExecutable(provider: provider, configuredPath: executablePath)

        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Account").font(.system(size: 14, weight: .medium))
                Text(
                    "Uses the \(cliName) installed on this Mac and its existing \(accountName) subscription sign-in. "
                        + "No API key is needed, and Typer On never reads the CLI's tokens."
                )
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

                statusRow(for: state)

                HStack(spacing: DS.Spacing.sm) {
                    Button("Check Connection") {
                        signInNote = nil
                        onCheckConnection()
                    }
                    .buttonStyle(.glass)
                    .disabled(state == .checking)

                    Button("Sign In...") {
                        startSignIn()
                    }
                    .buttonStyle(.glass)
                    .disabled(executable == nil)
                    .help("Opens Terminal and runs the CLI's own sign-in command.")

                    Spacer(minLength: 0)
                }

                if let signInNote {
                    Text(signInNote)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Executable").font(.system(size: 14, weight: .medium))

                executableRow(resolved: executable)

                HStack(spacing: DS.Spacing.sm) {
                    Button("Choose...") {
                        chooseExecutable(startingAt: executable)
                    }
                    .buttonStyle(.glass)

                    if executablePath != nil {
                        Button("Use Automatic Detection") {
                            executablePath = nil
                        }
                        .buttonStyle(.glass)
                    }

                    Spacer(minLength: 0)
                }
            }

            Text(
                "Text modules, custom prompts and Chat Mode run through this CLI. Screenshot input works with "
                    + "listed models that report image input; a custom model ID stays text-only. Image generation "
                    + "is unavailable through this integration - select OpenRouter yourself to generate images."
            )
            .font(.system(size: 12))
            .foregroundStyle(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusRow(for state: SubscriptionConnectionState) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            if state == .checking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: statusImage(for: state))
            }
            Text(statusText(for: state))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
        .foregroundStyle(statusTint(for: state))
    }

    private func statusText(for state: SubscriptionConnectionState) -> String {
        switch state {
        case .notChecked:
            return "Not checked yet. Use Check Connection."
        case .checking:
            return "Checking the \(cliName) and its sign-in..."
        case .ready, .executableMissing, .connectionFailed:
            return statusCatalog.subscriptionConnectionResult?.message ?? state.label
        }
    }

    private func statusImage(for state: SubscriptionConnectionState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .notChecked, .checking: "questionmark.circle"
        case .executableMissing, .connectionFailed: "exclamationmark.triangle.fill"
        }
    }

    private func statusTint(for state: SubscriptionConnectionState) -> Color {
        switch state {
        case .ready: .green
        case .notChecked, .checking: DS.Colors.textTertiary
        case .executableMissing, .connectionFailed: .orange
        }
    }

    @ViewBuilder
    private func executableRow(resolved: URL?) -> some View {
        if let path = executablePath ?? resolved?.path {
            Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DS.Colors.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(path)
        }

        Text(executableHint(isResolved: resolved != nil))
            .font(.system(size: 12))
            .foregroundStyle(resolved == nil ? .orange : DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func executableHint(isResolved: Bool) -> String {
        switch (executablePath != nil, isResolved) {
        case (true, true):
            return "Chosen manually."
        case (true, false):
            return "This file cannot be run. Choose the \(cliName) executable or use automatic detection."
        case (false, true):
            return "Detected automatically."
        case (false, false):
            return "Not found in ~/.local/bin, Homebrew or PATH. Install the \(cliName) or choose its executable."
        }
    }

    private func chooseExecutable(startingAt current: URL?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        // Keep a chosen link such as ~/.local/bin/claude, so CLI updates behind it keep applying.
        panel.resolvesAliases = false
        panel.directoryURL = current?.deletingLastPathComponent()
        panel.prompt = "Choose"
        panel.message = "Choose the \(cliName) executable."

        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        executablePath = path
    }

    /// Sign-in is always the user's own action: the CLI's interactive login runs in Terminal,
    /// and Typer On only learns the outcome from the next connection check.
    private func startSignIn() {
        do {
            let executable = try SubscriptionCLI.resolveExecutable(provider: provider, configuredPath: executablePath)
            let command = "\(Self.shellQuoted(executable.path)) \(signInArguments)"
            guard try Self.openInTerminal(command) else {
                signInNote = "Terminal could not be opened. Run this command yourself, then use Check Connection: \(command)"
                return
            }
            signInNote = "Finish signing in in Terminal, then use Check Connection."
        } catch {
            signInNote = error.localizedDescription
        }
    }

    /// Runs one command through a self-deleting `.command` file, which Terminal opens without
    /// an Automation prompt. The file holds only the quoted executable path and fixed arguments.
    private static func openInTerminal(_ command: String) throws -> Bool {
        let script = """
        #!/bin/zsh
        rm -f -- "$0"
        \(command)
        echo
        echo "Return to Typer On and use Check Connection."

        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typer-on-sign-in-\(UUID().uuidString).command")
        var opened = false
        defer { if !opened { try? FileManager.default.removeItem(at: url) } }
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        opened = NSWorkspace.shared.open(url)
        return opened
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
