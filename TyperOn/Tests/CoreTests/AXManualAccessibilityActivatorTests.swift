// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import ApplicationServices
import Synchronization
import Testing
@testable import Typer_On

private struct ActivationCall: Equatable {
    let pid: pid_t
    let method: AXManualAccessibilityActivator.Method
}

private final class RecordingManualAccessibilitySetter: Sendable {
    private let state = Mutex<(calls: [ActivationCall], results: [AXError])>(([], []))

    init(results: [AXError] = []) {
        state.withLock { $0.results = results }
    }

    var calls: [pid_t] { state.withLock { $0.calls.map(\.pid) } }
    var activations: [ActivationCall] { state.withLock { $0.calls } }

    func makeActivator() -> AXManualAccessibilityActivator {
        AXManualAccessibilityActivator { [self] pid, method in
            state.withLock { state in
                state.calls.append(ActivationCall(pid: pid, method: method))
                return state.results.isEmpty ? .success : state.results.removeFirst()
            }
        }
    }
}

private let claudeBundleIdentifier = "com.anthropic.claudefordesktop"
private let zenBundleIdentifier = "app.zen-browser.zen"
private let yandexBundleIdentifier = "ru.yandex.desktop.yandex-browser"

@Test
func testManualAccessibilityAppliesOnlyToExactClaudeBundle() {
    #expect(AXManualAccessibilityActivator.applies(to: claudeBundleIdentifier))
    #expect(AXManualAccessibilityActivator.applies(to: "com.Anthropic.ClaudeForDesktop"))
    #expect(!AXManualAccessibilityActivator.applies(to: "com.anthropic.claudefordesktop.helper"))
    #expect(!AXManualAccessibilityActivator.applies(to: "com.microsoft.VSCode"))
    #expect(!AXManualAccessibilityActivator.applies(to: yandexBundleIdentifier))
    #expect(!AXManualAccessibilityActivator.applies(to: nil))
    #expect(AXManualAccessibilityActivator.method(for: claudeBundleIdentifier) == .manualAccessibility)
}

@Test
func testApplicationRoleActivationAppliesOnlyToExactZenBundle() {
    #expect(AXManualAccessibilityActivator.method(for: zenBundleIdentifier) == .applicationRole)
    #expect(AXManualAccessibilityActivator.method(for: "App.Zen-Browser.Zen") == .applicationRole)
    #expect(AXManualAccessibilityActivator.method(for: "app.zen-browser.zen.helper") == nil)
    #expect(AXManualAccessibilityActivator.method(for: "org.mozilla.firefox") == nil)
}

@Test
func testApplicationRoleActivationAppliesToExactChromiumBundles() {
    #expect(AXManualAccessibilityActivator.method(for: "com.google.Chrome") == .applicationRole)
    #expect(AXManualAccessibilityActivator.method(for: "COM.GOOGLE.CHROME") == .applicationRole)
    #expect(AXManualAccessibilityActivator.method(for: "com.google.Chrome.canary") == .applicationRole)
    #expect(AXManualAccessibilityActivator.method(for: "com.microsoft.edgemac") == .applicationRole)
    #expect(AXManualAccessibilityActivator.method(for: "company.thebrowser.Browser") == .applicationRole)
    #expect(AXManualAccessibilityActivator.method(for: "com.google.Chrome.helper") == nil)
    // Yandex Browser ignores the AXRole read; only AXEnhancedUserInterface activates it.
    #expect(AXManualAccessibilityActivator.method(for: yandexBundleIdentifier) == nil)
}

@Test
func testManualAccessibilitySkipsOtherBundlesWithoutIPC() {
    let setter = RecordingManualAccessibilitySetter()
    let activator = setter.makeActivator()

    activator.prepare(pid: 10, bundleIdentifier: "com.microsoft.VSCode")
    activator.prepare(pid: 11, bundleIdentifier: yandexBundleIdentifier)
    activator.prepare(pid: 13, bundleIdentifier: "org.mozilla.firefox")
    activator.prepare(pid: 12, bundleIdentifier: nil)
    activator.prepare(pid: 0, bundleIdentifier: claudeBundleIdentifier)
    activator.prepare(pid: 0, bundleIdentifier: zenBundleIdentifier)

    #expect(setter.calls.isEmpty)
}

@Test
func testManualAccessibilityIsAssertedOncePerActivation() {
    let setter = RecordingManualAccessibilitySetter()
    let activator = setter.makeActivator()

    activator.prepare(pid: 42, bundleIdentifier: claudeBundleIdentifier)
    activator.prepare(pid: 42, bundleIdentifier: claudeBundleIdentifier)
    activator.prepare(pid: 42, bundleIdentifier: claudeBundleIdentifier)
    #expect(setter.calls == [42])

    // Reading another app ends the activation; returning asserts the attribute again.
    activator.prepare(pid: 7, bundleIdentifier: "com.apple.TextEdit")
    activator.prepare(pid: 42, bundleIdentifier: claudeBundleIdentifier)
    #expect(setter.calls == [42, 42])

    // A relaunched app has a new PID.
    activator.prepare(pid: 43, bundleIdentifier: claudeBundleIdentifier)
    #expect(setter.calls == [42, 42, 43])
}

@Test
func testApplicationRoleIsReadOncePerZenActivation() {
    let setter = RecordingManualAccessibilitySetter()
    let activator = setter.makeActivator()

    activator.prepare(pid: 50, bundleIdentifier: zenBundleIdentifier)
    activator.prepare(pid: 50, bundleIdentifier: zenBundleIdentifier)
    #expect(setter.activations == [ActivationCall(pid: 50, method: .applicationRole)])

    // Switching to Claude and back activates each app with its own method.
    activator.prepare(pid: 42, bundleIdentifier: claudeBundleIdentifier)
    activator.prepare(pid: 50, bundleIdentifier: zenBundleIdentifier)
    // An updated and relaunched Zen has a new PID.
    activator.prepare(pid: 51, bundleIdentifier: zenBundleIdentifier)
    #expect(setter.activations == [
        ActivationCall(pid: 50, method: .applicationRole),
        ActivationCall(pid: 42, method: .manualAccessibility),
        ActivationCall(pid: 50, method: .applicationRole),
        ActivationCall(pid: 51, method: .applicationRole),
    ])
}

@Test
func testManualAccessibilityRetriesOnlyAfterTransientErrors() {
    let setter = RecordingManualAccessibilitySetter(results: [.cannotComplete, .success])
    let activator = setter.makeActivator()

    activator.prepare(pid: 42, bundleIdentifier: claudeBundleIdentifier)
    activator.prepare(pid: 42, bundleIdentifier: claudeBundleIdentifier)
    activator.prepare(pid: 42, bundleIdentifier: claudeBundleIdentifier)
    #expect(setter.calls == [42, 42])

    let unsupportedSetter = RecordingManualAccessibilitySetter(results: [.attributeUnsupported])
    let unsupportedActivator = unsupportedSetter.makeActivator()
    unsupportedActivator.prepare(pid: 42, bundleIdentifier: claudeBundleIdentifier)
    unsupportedActivator.prepare(pid: 42, bundleIdentifier: claudeBundleIdentifier)
    #expect(unsupportedSetter.calls == [42])

    let zenSetter = RecordingManualAccessibilitySetter(results: [.apiDisabled, .success])
    let zenActivator = zenSetter.makeActivator()
    zenActivator.prepare(pid: 50, bundleIdentifier: zenBundleIdentifier)
    zenActivator.prepare(pid: 50, bundleIdentifier: zenBundleIdentifier)
    zenActivator.prepare(pid: 50, bundleIdentifier: zenBundleIdentifier)
    #expect(zenSetter.calls == [50, 50])
}
