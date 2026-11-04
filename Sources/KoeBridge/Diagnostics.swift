#if os(macOS)
import Foundation
import KoeBridgeCore

/// Local troubleshooting only: explicit opt-in, no transcript/audio/API key.
/// All calls are main-actor serialized; file writes append instead of rewrite.
@MainActor enum DiagnosticLog {
    static let preferenceKey = "diagnosticsEnabled"
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/KoeBridge.log")
    private static let store = DiagnosticFileStore(fileURL: fileURL)

    /// An unset preference (including upgrades from v0.4.x) is OFF.
    static var isEnabled: Bool {
        DiagnosticLogPolicy.isEnabled(
            storedValue: UserDefaults.standard.object(forKey: preferenceKey) as? Bool)
    }

    /// Evaluate the event lazily: normal use never builds diagnostic strings.
    static func record(_ event: @autoclosure () -> String) {
        guard isEnabled else { return }
        do { try store.append(event()) }
        catch { /* Diagnostics may never interrupt actual dictation. */ }
    }

    /// Stopping logging never erases an old file. Deletion is user-initiated.
    static func deleteExistingFiles() throws {
        try store.deleteAll()
    }
}
#endif
