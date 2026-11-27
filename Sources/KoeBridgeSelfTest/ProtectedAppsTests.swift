import Foundation
import KoeBridgeCore

struct ProtectedAppsTests {
    func validationAndUpsert() throws {
        check(ProtectedAppPolicy.validationHint(for: "com.apple.TextEdit") == nil)
        check(ProtectedAppPolicy.validationHint(for: " ") != nil)
        check(ProtectedAppPolicy.validationHint(for: "example") != nil)
        check(ProtectedAppPolicy.validationHint(for: "com.example_app") != nil)
        let existing = ProtectedApp(bundleIdentifier: "com.example.Secrets", displayName: "Secrets")
        let saved = ProtectedAppPolicy.saving(
            ProtectedApp(bundleIdentifier: " COM.EXAMPLE.secrets ", displayName: " Secret Store "), in: [existing])
        check(saved.count == 1)
        check(saved[0].id == existing.id)
        check(saved[0].bundleIdentifier == "COM.EXAMPLE.secrets")
        check(saved[0].displayName == "Secret Store")
        let decoded = try JSONDecoder().decode([ProtectedApp].self, from: JSONEncoder().encode(saved))
        check(decoded == saved)
    }

    func persistenceRoundTripAndCorruptStorage() throws {
        let suite = "KoeBridgeSelfTest.ProtectedApps." + UUID().uuidString
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "protectedApps"
        let app = ProtectedApp(bundleIdentifier: "com.example.Secrets", displayName: "Secrets")
        var store = SettingsArray<ProtectedApp>(key, defaults: defaults)
        check(store.state == .unset && store.rows.isEmpty)
        check(store.save([app]))
        check(SettingsArray<ProtectedApp>(key, defaults: defaults).rows == [app])
        check(store.save([]))
        check(SettingsArray<ProtectedApp>(key, defaults: defaults).rows.isEmpty)
        defaults.set(Data("not-json".utf8), forKey: key)
        store = SettingsArray(key, defaults: defaults)
        check(store.state == .corrupt)
        check(store.rows.isEmpty)
        check(!store.save([app]))
        check(ProtectedAppPolicy.bundleIdentifiers(in: store) == nil)
        check(InsertionReceiptPolicy.fieldNature(role: "AXSecureTextField", subrole: nil, editable: true,
                                                 hasTextSelection: true, bundleIdentifier: "com.example.Secrets") == .protected)
        check(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
                                                 hasTextSelection: true, bundleIdentifier: "com.example.Unlisted",
                                                 protectedBundleIdentifiers: nil) == .unknown)
    }

    func registryMatchingAndFailClosedBoundaries() throws {
        let registry: Set<String>? = ProtectedAppPolicy.bundleIdentifiers(in: [
            ProtectedApp(bundleIdentifier: " com.example.VaultApp ", displayName: "Vault"),
        ])
        check(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
            hasTextSelection: true, bundleIdentifier: "COM.EXAMPLE.VAULTAPP",
            protectedBundleIdentifiers: registry) == .protected)
        check(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
            hasTextSelection: true, bundleIdentifier: " com.example.vaultapp ",
            protectedBundleIdentifiers: registry) == .protected)
        check(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
            hasTextSelection: true, bundleIdentifier: "com.example.vaultapp.helper",
            protectedBundleIdentifiers: registry) == .normal)
        check(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
            hasTextSelection: true, bundleIdentifier: nil,
            protectedBundleIdentifiers: registry) == .unknown)
        check(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
            hasTextSelection: true, bundleIdentifier: "com.example.anything",
            protectedBundleIdentifiers: []) == .normal)
        check(ProtectedAppPolicy.saving(
            ProtectedApp(bundleIdentifier: "not valid", displayName: "bad"),
            in: []).isEmpty)
    }
}
