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
    private static var inputConsent = InputDiagnosticConsent()

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

    /// Called for both ON and OFF, including an OFF/ON cycle between async
    /// receipt polls. Previously buffered evidence cannot cross that boundary.
    static func preferenceDidChange(_ enabled: Bool) {
        inputConsent.setEnabled(enabled)
    }

    static func inputTrace(takeID: UUID) -> InputDiagnosticTrace? {
        inputConsent.setEnabled(isEnabled)
        guard let token = inputConsent.token else { return nil }
        return InputDiagnosticTrace(takeID: takeID, consent: token)
    }

    static func permitsInputTrace(_ token: InputDiagnosticConsent.Token) -> Bool {
        inputConsent.setEnabled(isEnabled)
        return inputConsent.allows(token)
    }

    static func writeInputTrace(_ lines: @autoclosure () -> [String],
                                consent: InputDiagnosticConsent.Token) {
        // Gate again immediately before formatting/writing. No asynchronous
        // writer can append old evidence after logging is disabled or deleted.
        guard permitsInputTrace(consent) else { return }
        do { try store.appendBatch(lines()) }
        catch { /* A diagnostic failure must never change delivery. */ }
    }

    /// Streaming breadcrumbs use the SAME opt-in/revocation token and bounded
    /// rotating store as input diagnostics. No separate log or consent setting.
    static func microphoneTrace(captureID: UUID, explicitSelection: Bool) -> MicrophonePreparationDiagnostics? {
        inputConsent.setEnabled(isEnabled)
        guard let token = inputConsent.token else { return nil }
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        return MicrophonePreparationDiagnostics { entry in
            Task { @MainActor in
                writeInputTrace(["mic_start v=1 capture=\(captureID.uuidString) build=\(build) explicit=\(explicitSelection ? 1 : 0) \(entry.rendered)"],
                                consent: token)
            }
        }
    }

    /// Stopping logging never erases an old file. Deletion is user-initiated.
    static func deleteExistingFiles() throws {
        inputConsent.invalidate()
        try store.deleteAll()
    }
}
#endif
