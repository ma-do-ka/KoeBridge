import Foundation
import Testing
@testable import KoeBridgeCore

struct ProtectedAppsTests {
    @Test func validationNormalizationAndCaseInsensitiveUpsert() throws {
        #expect(ProtectedAppPolicy.validationHint(for: "com.apple.TextEdit") == nil)
        #expect(ProtectedAppPolicy.validationHint(for: "com.example-one.App") == nil)
        #expect(ProtectedAppPolicy.validationHint(for: " ") != nil)
        for invalid in ["example", "com..example", ".com.example", "com.example.", "com.example_app", "com.例えば.App"] {
            #expect(ProtectedAppPolicy.validationHint(for: invalid) != nil)
        }
        #expect(ProtectedAppPolicy.isValidBundleIdentifier("  com.example.Valid  "))

        let existing = ProtectedApp(bundleIdentifier: "com.example.Secrets", displayName: "Secrets")
        let replacement = ProtectedApp(bundleIdentifier: " COM.EXAMPLE.secrets ", displayName: " Secret Store ")
        let saved = ProtectedAppPolicy.saving(replacement, in: [existing])
        #expect(saved.count == 1)
        #expect(saved[0].id == existing.id)
        #expect(saved[0].bundleIdentifier == "COM.EXAMPLE.secrets")
        #expect(saved[0].displayName == "Secret Store")
        #expect(ProtectedAppPolicy.saving(ProtectedApp(bundleIdentifier: "com.example.Other", displayName: ""), in: saved).count == 2)
        #expect(ProtectedAppPolicy.bundleIdentifiers(in: saved + [ProtectedApp(bundleIdentifier: "not valid", displayName: "bad")]) == ["COM.EXAMPLE.secrets"])
    }

    @Test func protectedAppsSettingsArrayRoundTripAddRemoveReloadAndCorruptFailsClosed() throws {
        let suite = "KoeBridge.ProtectedApps." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "protectedApps"
        let first = ProtectedApp(bundleIdentifier: "com.example.Secrets", displayName: "Secrets")
        let second = ProtectedApp(bundleIdentifier: "com.example.Bank", displayName: "Bank")

        var store = SettingsArray<ProtectedApp>(key, defaults: defaults)
        #expect(store.state == .unset && store.rows.isEmpty)
        let savedFirst = store.save([first])
        #expect(savedFirst)
        store = SettingsArray(key, defaults: defaults)
        #expect(store.state == .loaded && store.rows == [first])
        let savedBoth = store.save([first, second])
        #expect(savedBoth)
        #expect(SettingsArray<ProtectedApp>(key, defaults: defaults).rows == [first, second])
        let savedSecondOnly = store.save([second])
        #expect(savedSecondOnly)
        #expect(SettingsArray<ProtectedApp>(key, defaults: defaults).rows == [second])
        let savedEmpty = store.save([])
        #expect(savedEmpty)
        store = SettingsArray(key, defaults: defaults)
        #expect(store.state == .loaded && store.rows.isEmpty)

        let damaged = Data("not-json".utf8)
        defaults.set(damaged, forKey: key)
        store = SettingsArray(key, defaults: defaults)
        #expect(store.state == .corrupt)
        #expect(store.rows.isEmpty)
        let corruptSave = store.save([first])
        #expect(!corruptSave)
        #expect(defaults.data(forKey: key) == damaged)
        // Corrupt store => nil registry => even a normal field fails closed.
        #expect(ProtectedAppPolicy.bundleIdentifiers(in: store) == nil)
        #expect(InsertionReceiptPolicy.fieldNature(role: "AXSecureTextField", subrole: nil, editable: true,
                                                   hasTextSelection: true, bundleIdentifier: "com.example.Secrets") == .protected)
        #expect(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
                                                   hasTextSelection: true, bundleIdentifier: "com.example.Unlisted",
                                                   protectedBundleIdentifiers: nil) == .unknown)
        store.resetCorruptValue()
        #expect(store.state == .unset)
        let recoveredSave = store.save([first])
        #expect(recoveredSave)
    }

    @Test func corruptSchemaRowsFailWholeListClosedAndRecoveryRestoresNormalState() throws {
        let suite = "KoeBridge.ProtectedAppsPartial." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "protectedApps"
        // A single malformed row poisons the whole list decode: never skip the
        // bad row and continue, since it could have been the protected app.
        let partial = Data("""
            [{"id":"\(UUID().uuidString)","bundleIdentifier":"com.example.Ok","displayName":"Ok"},
             {"id":"\(UUID().uuidString)","bundleIdentifier":"com.example.Broken"}]
            """.utf8)
        defaults.set(partial, forKey: key)
        var store = SettingsArray<ProtectedApp>(key, defaults: defaults)
        #expect(store.state == .corrupt)
        #expect(ProtectedAppPolicy.bundleIdentifiers(in: store) == nil)
        #expect(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
                                                   hasTextSelection: true, bundleIdentifier: "com.example.Unlisted",
                                                   protectedBundleIdentifiers: nil) == .unknown)
        store.resetCorruptValue()
        #expect(store.state == .unset)
        let app = ProtectedApp(bundleIdentifier: "com.example.Ok", displayName: "Ok")
        let appSave = store.save([app])
        #expect(appSave)
        #expect(ProtectedAppPolicy.bundleIdentifiers(in: store) == ["com.example.Ok"])

        // A decodable row with an unrecognizable identifier is damaged data:
        // fail closed rather than silently skipping what might be protected.
        let suspicious = Data("""
            [{"id":"\(UUID().uuidString)","bundleIdentifier":"!!!not a bundle id!!!","displayName":"Bad"}]
            """.utf8)
        defaults.set(suspicious, forKey: key)
        store = SettingsArray(key, defaults: defaults)
        #expect(store.state == .loaded)
        #expect(ProtectedAppPolicy.bundleIdentifiers(in: store) == nil)
    }

    @Test func registryMatchingIsBundleIdOnlyNormalizedCaseInsensitiveAndExact() {
        let registry: Set<String>? = ProtectedAppPolicy.bundleIdentifiers(in: [
            ProtectedApp(bundleIdentifier: " com.example.VaultApp ", displayName: "Vault"),
            ProtectedApp(bundleIdentifier: "com.example.bank", displayName: "Bank"),
        ])
        // Case-insensitive + surrounding-whitespace-trimmed, bundle ID only.
        #expect(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
            hasTextSelection: true, bundleIdentifier: "com.example.vaultapp",
            protectedBundleIdentifiers: registry) == .protected)
        #expect(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
            hasTextSelection: true, bundleIdentifier: " COM.EXAMPLE.BANK ",
            protectedBundleIdentifiers: registry) == .protected)
        // Display names are never match input; a renamed app still matches by ID.
        // Exact match only: helper/sub-app and prefix collisions stay normal.
        for runtime in ["com.example.vaultapp.helper", "com.example.vaultapp2", "com.example.bankex"] {
            #expect(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
                hasTextSelection: true, bundleIdentifier: runtime,
                protectedBundleIdentifiers: registry) == .normal)
        }
        // A valid, legitimately-empty registry leaves normal fields normal
        // (distinct from a corrupt store, which is nil and fails closed).
        #expect(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
            hasTextSelection: true, bundleIdentifier: "com.example.anything",
            protectedBundleIdentifiers: []) == .normal)
        // Unobtainable runtime identifiers fail closed.
        for missing in [nil, "", "   "] {
            #expect(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
                hasTextSelection: true, bundleIdentifier: missing,
                protectedBundleIdentifiers: registry) == .unknown)
        }
    }

    @Test func savingRejectsInvalidIdentifiersAndLargeRegistriesStillMatch() {
        let app = ProtectedApp(bundleIdentifier: "com.example.App", displayName: "App")
        for bad in ["", "   ", "not-valid", "com.example bad", "com.example_underscore"] {
            #expect(ProtectedAppPolicy.saving(
                ProtectedApp(bundleIdentifier: bad, displayName: "bad"), in: [app]) == [app])
        }
        let many = (0..<500).map {
            ProtectedApp(bundleIdentifier: "com.example.app\($0)", displayName: "App \($0)")
        }
        let registry = ProtectedAppPolicy.bundleIdentifiers(in: many)
        #expect(registry.count == 500)
        #expect(InsertionReceiptPolicy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
            hasTextSelection: true, bundleIdentifier: "COM.EXAMPLE.APP499",
            protectedBundleIdentifiers: registry) == .protected)
    }
}
