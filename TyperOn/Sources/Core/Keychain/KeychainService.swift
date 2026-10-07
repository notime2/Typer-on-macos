// SPDX-License-Identifier: LicenseRef-Typer-On-Individual-1.0
// Copyright 2026 Maksim Nikolaev

import Foundation
import Security

final class KeychainService: Sendable {
    private let serviceName = "com.typeron.app"
    private let allowsSystemAccess: Bool
    private let accessOverrides: KeychainAccessOverrides?

    init(allowsSystemAccess: Bool = true, accessOverrides: KeychainAccessOverrides? = nil) {
        self.allowsSystemAccess = allowsSystemAccess
        self.accessOverrides = accessOverrides
    }

    func getGlobalAPIKey() -> String? {
        get(account: "openrouter-api-key")
    }

    func setGlobalAPIKey(_ key: String) {
        set(key, account: "openrouter-api-key")
    }

    func deleteGlobalAPIKey() {
        delete(account: "openrouter-api-key")
    }

    /// The optional key for a user-configured OpenAI-compatible endpoint; it never touches UserDefaults.
    func getLocalEndpointAPIKey() -> String? {
        get(account: "local-endpoint-api-key")
    }

    func setLocalEndpointAPIKey(_ key: String) {
        set(key, account: "local-endpoint-api-key")
    }

    func deleteLocalEndpointAPIKey() {
        delete(account: "local-endpoint-api-key")
    }

    func getModuleAPIKey(moduleId: String) -> String? {
        get(account: "module.\(moduleId).apikey")
    }

    func setModuleAPIKey(_ key: String, moduleId: String) {
        set(key, account: "module.\(moduleId).apikey")
    }

    func deleteModuleAPIKey(moduleId: String) {
        delete(account: "module.\(moduleId).apikey")
    }

    // MARK: - Private

    private func get(account: String) -> String? {
        guard allowsSystemAccess else { return nil }
        if let accessOverrides { return accessOverrides.read(account) }
        guard !AppRuntime.isRunningTests else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func set(_ value: String, account: String) {
        guard allowsSystemAccess else { return }
        if let accessOverrides { accessOverrides.write(account, value); return }
        guard !AppRuntime.isRunningTests else { return }

        delete(account: account)

        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    private func delete(account: String) {
        guard allowsSystemAccess else { return }
        if let accessOverrides { accessOverrides.delete(account); return }
        guard !AppRuntime.isRunningTests else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}

/// In-memory operation substitution for tests; the access gate applies before every callback.
struct KeychainAccessOverrides: Sendable {
    let read: @Sendable (String) -> String?
    let write: @Sendable (String, String) -> Void
    let delete: @Sendable (String) -> Void
}
