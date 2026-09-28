// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Maksim Nikolaev

import ApplicationServices
import Synchronization

/// Some apps hide their web-content AX tree from non-VoiceOver clients until an
/// assistive client activates it on the application element. Electron waits for
/// `AXManualAccessibility`, whose getter always reads false; Gecko and Chrome
/// enable accessibility when the application's `AXRole` is read. The activated
/// PID is therefore tracked here.
final class AXManualAccessibilityActivator: Sendable {
    enum Method: String, Sendable {
        case manualAccessibility
        case applicationRole
    }

    typealias Activate = @Sendable (pid_t, Method) -> AXError

    static let shared = AXManualAccessibilityActivator()

    // Exact IDs only: other Electron apps (for example VS Code) react to
    // accessibility support changes, and enabling it costs renderer work.
    private static let methods: [String: Method] = {
        var methods: [String: Method] = [
            "com.anthropic.claudefordesktop": .manualAccessibility,
            // GeckoNSApplication.accessibilityRole enables accessibility (bug 1845364).
            "app.zen-browser.zen": .applicationRole,
        ]
        // Chrome 154: AXFocusedUIElement stays noValue after every launch until the
        // application AXRole is read (~100 ms); AXManualAccessibility is unsupported.
        // The other Chromium IDs are unverified and read by analogy. Yandex Browser
        // 26.8 ignores this read (only AXEnhancedUserInterface works) and is absent.
        for bundleIdentifier in AccessibilityManager.chromiumBundleIdentifiers {
            methods[bundleIdentifier.lowercased()] = .applicationRole
        }
        return methods
    }()

    private let activate: Activate
    private let activatedPID = Mutex<pid_t?>(nil)

    init(activate: @escaping Activate = AXManualAccessibilityActivator.activate) {
        self.activate = activate
    }

    static func method(for bundleIdentifier: String?) -> Method? {
        guard let bundleIdentifier else { return nil }
        return methods[bundleIdentifier.lowercased()]
    }

    static func applies(to bundleIdentifier: String?) -> Bool {
        method(for: bundleIdentifier) != nil
    }

    /// Activates once per activation: reading any other app resets the state,
    /// so returning to the app (or a relaunch) activates it again.
    func prepare(pid: pid_t, bundleIdentifier: String?) {
        guard pid > 0, let method = Self.method(for: bundleIdentifier) else {
            activatedPID.withLock { $0 = nil }
            return
        }
        let claimed = activatedPID.withLock { state in
            guard state != pid else { return false }
            state = pid
            return true
        }
        guard claimed else { return }

        let error = activate(pid, method)
        if Self.isTransient(error) {
            activatedPID.withLock { state in
                if state == pid { state = nil }
            }
        }
        Log.accessibility.info("Accessibility tree activated: bundle=\(bundleIdentifier ?? "unknown", privacy: .public) method=\(method.rawValue, privacy: .public) error=\(error.rawValue)")
    }

    private static func isTransient(_ error: AXError) -> Bool {
        error == .cannotComplete || error == .failure || error == .apiDisabled
    }

    static func activate(pid: pid_t, method: Method) -> AXError {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        switch method {
        case .manualAccessibility:
            return AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, true as CFBoolean)
        case .applicationRole:
            var role: AnyObject?
            return AXUIElementCopyAttributeValue(application, kAXRoleAttribute as CFString, &role)
        }
    }
}
