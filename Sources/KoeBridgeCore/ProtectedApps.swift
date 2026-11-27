import Foundation

public struct ProtectedApp: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String
    public var displayName: String

    public init(id: UUID = UUID(), bundleIdentifier: String, displayName: String) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

public enum ProtectedAppPolicy {
    public static func normalizedBundleIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isValidBundleIdentifier(_ value: String) -> Bool {
        let normalized = normalizedBundleIdentifier(value)
        guard normalized.count <= 255, normalized.contains(".") else { return false }
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value)
                    || (65...90).contains(scalar.value)
                    || (97...122).contains(scalar.value)
                    || scalar.value == 45
            }
        }
    }

    public static func validationHint(for bundleIdentifier: String) -> String? {
        if normalizedBundleIdentifier(bundleIdentifier).isEmpty {
            return "バンドルIDを入力してください"
        }
        guard isValidBundleIdentifier(bundleIdentifier) else {
            return "バンドルIDは com.example.App の形式で入力してください（英数字・ハイフン・ドット）"
        }
        return nil
    }

    public static func isSameBundle(_ lhs: String, _ rhs: String) -> Bool {
        normalizedBundleIdentifier(lhs).caseInsensitiveCompare(normalizedBundleIdentifier(rhs)) == .orderedSame
    }

    public static func saving(_ entry: ProtectedApp, in apps: [ProtectedApp]) -> [ProtectedApp] {
        guard isValidBundleIdentifier(entry.bundleIdentifier) else { return apps }
        var result = apps
        var normalized = entry
        normalized.bundleIdentifier = normalizedBundleIdentifier(entry.bundleIdentifier)
        if normalizedBundleIdentifier(normalized.displayName).isEmpty {
            normalized.displayName = normalized.bundleIdentifier
        } else {
            normalized.displayName = normalizedBundleIdentifier(normalized.displayName)
        }
        if let index = result.firstIndex(where: { isSameBundle($0.bundleIdentifier, normalized.bundleIdentifier) }) {
            result[index].bundleIdentifier = normalized.bundleIdentifier
            result[index].displayName = normalized.displayName
        } else {
            result.append(normalized)
        }
        return result
    }

    public static func bundleIdentifiers(in apps: [ProtectedApp]) -> Set<String> {
        Set(apps.map { normalizedBundleIdentifier($0.bundleIdentifier) }.filter { isValidBundleIdentifier($0) })
    }

    /// The canonical lookup for the delivery path. A corrupt stored list is
    /// unreadable evidence: nil means the classifier must fail closed. A row
    /// that decodes but fails identifier validation is treated the same way —
    /// it may be a damaged protected entry, so it is never silently skipped.
    public static func bundleIdentifiers(in store: SettingsArray<ProtectedApp>) -> Set<String>? {
        guard store.state != .corrupt else { return nil }
        let ids = store.rows.map { normalizedBundleIdentifier($0.bundleIdentifier) }
        guard ids.allSatisfy(isValidBundleIdentifier) else { return nil }
        return Set(ids)
    }
}
