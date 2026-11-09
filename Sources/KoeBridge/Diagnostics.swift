#if os(macOS)
import Foundation
import KoeBridgeCore

/// Ordinary troubleshooting remains content-free. Developer diagnostics are a
/// separate explicit opt-in and never write transcript/audio into KoeBridge.log.
@MainActor enum DiagnosticLog {
    static let preferenceKey = "diagnosticsEnabled"
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/KoeBridge.log")
    private static let store = DiagnosticFileStore(fileURL: fileURL)
    private static var inputConsent = InputDiagnosticConsent()

    static var isEnabled: Bool {
        DiagnosticLogPolicy.isEnabled(
            storedValue: UserDefaults.standard.object(forKey: preferenceKey) as? Bool)
    }

    /// Build a breadcrumb only when either diagnostics mode needs it. The same
    /// content-free event may be copied to the isolated developer timeline.
    static func record(_ event: @autoclosure () -> String) {
        let standard = isEnabled
        let developer = DeveloperDiagnostics.isEnabled
        guard standard || developer else { return }
        let rendered = event()
        if standard {
            do { try store.append(rendered) }
            catch { /* Diagnostics may never interrupt actual dictation. */ }
        }
        if developer { DeveloperDiagnostics.appendGlobal(rendered) }
    }

    static func preferenceDidChange(_ enabled: Bool) {
        inputConsent.setEnabled(enabled)
    }

    static func inputTrace(takeID: UUID) -> InputDiagnosticTrace? {
        inputConsent.setEnabled(isEnabled)
        let standard = inputConsent.token
        let developer = DeveloperDiagnostics.token
        guard standard != nil || developer != nil else { return nil }
        return InputDiagnosticTrace(takeID: takeID, standardConsent: standard,
                                    developerConsent: developer)
    }

    static func permitsInputTrace(_ token: InputDiagnosticConsent.Token?) -> Bool {
        inputConsent.setEnabled(isEnabled)
        return inputConsent.allows(token)
    }

    static func writeInputTrace(_ lines: @autoclosure () -> [String],
                                consent: InputDiagnosticConsent.Token) {
        guard permitsInputTrace(consent) else { return }
        do { try store.appendBatch(lines()) }
        catch { /* A diagnostic failure must never change delivery. */ }
    }

    /// Microphone preparation evidence is duplicated into developer diagnostics
    /// only when its independent token is still valid.
    static func microphoneTrace(captureID: UUID, takeID: UUID?,
                                explicitSelection: Bool) -> MicrophonePreparationDiagnostics? {
        inputConsent.setEnabled(isEnabled)
        let standard = inputConsent.token
        let developer = DeveloperDiagnostics.token
        guard standard != nil || developer != nil else { return nil }
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        return MicrophonePreparationDiagnostics { entry in
            Task { @MainActor in
                let line = "mic_start v=1 capture=\(captureID.uuidString) build=\(build) explicit=\(explicitSelection ? 1 : 0) \(entry.rendered)"
                if let standard, permitsInputTrace(standard) {
                    writeInputTrace([line], consent: standard)
                }
                if let developer, DeveloperDiagnostics.allows(developer) {
                    Task {
                        await DeveloperDiagnosticsStore.shared.recordEvent(
                            takeID: takeID ?? captureID,
                            stage: "microphone_trace",
                            fields: [
                                "capture_id": captureID.uuidString.lowercased(),
                                "entry": entry.rendered,
                                "build": "\(build)"
                            ],
                            token: developer
                        )
                    }
                }
            }
        }
    }

    static func deleteExistingFiles() throws {
        inputConsent.invalidate()
        try store.deleteAll()
    }
}
#endif
