#if os(macOS)
import Foundation
import Security

/// Supported API-key providers stored in macOS Keychain.
/// Gemini's service and account names are frozen for backward compatibility.
enum CredentialProvider: String, CaseIterable, Equatable, Sendable {
    case gemini
    case amivoice

    var service: String {
        switch self {
        case .gemini: return "dev.koebridge.gemini-api"
        case .amivoice: return "dev.koebridge.amivoice-api"
        }
    }

    var account: String {
        switch self {
        case .gemini: return "personal-key"
        case .amivoice: return "api-key"
        }
    }
}

/// API keys are not stored in UserDefaults, source code, or debug logs.
enum KeychainStore {
    static func baseQuery(for provider: CredentialProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.service,
            kSecAttrAccount as String: provider.account
        ]
    }

    // Observe registration and search-list changes made outside KoeBridge too.
    // Data-access events must be excluded: refreshing the cache reads the item.
    static let observingChanges: Bool = {
        let events: SecKeychainEventMask = [.addEventMask, .deleteEventMask, .updateEventMask,
            .lockEventMask, .unlockEventMask, .passwordChangedEventMask, .defaultChangedEventMask,
            .keychainListChangedMask]
        return SecKeychainAddCallback({ _, _, _ in
            Task { @MainActor in VoiceController.shared.invalidateKeyRegistration() }
            return errSecSuccess
        }, events, nil) == errSecSuccess
    }()

    @MainActor static func loadForUse(provider: CredentialProvider = .gemini) -> String? {
        let key = load(provider: provider)
        if key == nil { VoiceController.shared.invalidateKeyRegistration() }
        return key
    }

    static func load(provider: CredentialProvider = .gemini) -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String, provider: CredentialProvider = .gemini) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw KeyError.empty }
        let query = baseQuery(for: provider)
        let status = SecItemAdd(query.merging([
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query as CFDictionary,
                                       [kSecValueData as String: Data(value.utf8)] as CFDictionary)
            guard update == errSecSuccess else { throw KeyError.security(update) }
        } else if status != errSecSuccess {
            throw KeyError.security(status)
        }
    }

    static func delete(provider: CredentialProvider = .gemini) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyError.security(status)
        }
    }

    enum KeyError: Error, LocalizedError {
        case empty
        case security(OSStatus)
        var errorDescription: String? {
            switch self {
            case .empty: return "APIキーが空です"
            case .security(let status): return "キーチェーンエラー (\(status))"
            }
        }
    }
}
#endif
