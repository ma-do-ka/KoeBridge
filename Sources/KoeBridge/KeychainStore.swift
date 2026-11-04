#if os(macOS)
import Foundation
import Security

/// API keys are not stored in UserDefaults, source code, or debug logs.
enum KeychainStore {
    private static let service = "dev.koebridge.gemini-api"
    private static let account = "personal-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw KeyError.empty }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
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

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
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
