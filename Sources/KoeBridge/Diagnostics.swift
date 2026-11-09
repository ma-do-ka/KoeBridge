#if os(macOS)
import Foundation
import KoeBridgeCore

/// Local troubleshooting only: explicit opt-in, no transcript/audio/API key.
/// Two files share ONE consent switch/token and deletion path. The microphone
/// mirror exists only to retain microphone evidence longer.
/// All calls are main-actor serialized; file writes append instead of rewrite.
@MainActor enum DiagnosticLog {
    static let preferenceKey = "diagnosticsEnabled"
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/KoeBridge.log")
    static let microphoneFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/KoeBridge-mic.log")
    private static let store = DiagnosticFileStore(
        fileURL: fileURL, maximumFileBytes: DiagnosticLogPolicy.main.maximumFileBytes,
        maximumGenerations: DiagnosticLogPolicy.main.maximumGenerations)
    private static let microphoneStore = DiagnosticFileStore(
        fileURL: microphoneFileURL, maximumFileBytes: DiagnosticLogPolicy.microphone.maximumFileBytes,
        maximumGenerations: DiagnosticLogPolicy.microphone.maximumGenerations)
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

    /// Mirror the same diagnostic event under the existing consent/token gate.
    static func recordMicrophoneEvidence(_ event: @autoclosure () -> String) {
        inputConsent.setEnabled(isEnabled)
        guard let token = inputConsent.token else { return }
        let line = event()
        writeInputTrace([line], consent: token)
        writeMicrophoneTrace([line], consent: token)
    }

    private static func writeMicrophoneTrace(_ lines: [String], consent: InputDiagnosticConsent.Token) {
        guard permitsInputTrace(consent) else { return }
        do { try microphoneStore.appendBatch(lines) }
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
    /// stores as input diagnostics, with a longer-retained microphone mirror.
    static func microphoneTrace(captureID: UUID, explicitSelection: Bool) -> MicrophonePreparationDiagnostics? {
        inputConsent.setEnabled(isEnabled)
        guard let token = inputConsent.token else { return nil }
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        return MicrophonePreparationDiagnostics { entry in
            Task { @MainActor in
                guard permitsInputTrace(token) else { return }
                let line = "mic_start v=1 capture=\(captureID.uuidString) build=\(build) explicit=\(explicitSelection ? 1 : 0) \(entry.rendered)"
                writeInputTrace([line], consent: token)
                writeMicrophoneTrace([line], consent: token)
            }
        }
    }

    /// Stopping logging never erases an old file. Deletion is user-initiated.
    static func deleteExistingFiles() throws {
        inputConsent.invalidate()
        // Attempt both stores even if one cannot be removed.
        var deletionError: Error?
        do { try store.deleteAll() } catch { deletionError = error }
        do { try microphoneStore.deleteAll() } catch { if deletionError == nil { deletionError = error } }
        if let deletionError { throw deletionError }
    }
}
#endif
