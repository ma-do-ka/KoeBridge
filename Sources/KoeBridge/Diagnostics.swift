#if os(macOS)
import Foundation
import KoeBridgeCore

/// A single FIFO accepts complete events from the consent owner. No delayed
/// MainActor task is needed to drain it, even during a stalled startup.
final class DiagnosticWriter: @unchecked Sendable {
    private struct Submission {
        let lines: [String]
        let timestamp: Date
        let mirrored: Bool
    }
    private let main: DiagnosticFileStore
    private let mic: DiagnosticFileStore
    private let queue = DispatchQueue(label: "KoeBridge.diagnostic-writer")
    private let lock = NSLock()
    private var pending: [Submission] = []

    init(main: DiagnosticFileStore, microphone: DiagnosticFileStore) {
        self.main = main
        self.mic = microphone
    }

    @MainActor func append(_ lines: [String], mirrored: Bool = false, at timestamp: Date = Date()) {
        guard !lines.isEmpty else { return }
        lock.lock()
        let schedule = pending.isEmpty
        pending.append(Submission(lines: lines, timestamp: timestamp, mirrored: mirrored))
        let full = pending.count >= 64
        if schedule { queue.async { self.drain() } }
        lock.unlock()
        if full { flush() }
    }

    private func drain() {
        lock.lock()
        let batch = pending
        pending = []
        lock.unlock()
        var start = 0
        while start < batch.count {
            let mirrored = batch[start].mirrored
            var events: [(event: String, at: Date)] = []
            repeat {
                let submission = batch[start]
                events.append(contentsOf: submission.lines.map { ($0, submission.timestamp) })
                start += 1
            } while start < batch.count && batch[start].mirrored == mirrored
            try? main.appendTimedBatch(events)
            if mirrored { try? mic.appendTimedBatch(events) }
        }
    }

    func flush() { queue.sync {} }

    func deleteAll() throws {
        try queue.sync {
            var first: Error?
            do { try main.deleteAll() } catch { first = error }
            do { try mic.deleteAll() } catch { if first == nil { first = error } }
            if let first { throw first }
        }
    }
}

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
    private static let writer = DiagnosticWriter(main: store, microphone: microphoneStore)
    static func flush() { writer.flush() }

    private static var inputConsent = InputDiagnosticConsent()

    /// An unset preference (including upgrades from v0.4.x) is OFF.
    static var isEnabled: Bool {
        DiagnosticLogPolicy.isEnabled(
            storedValue: UserDefaults.standard.object(forKey: preferenceKey) as? Bool)
    }

    /// Evaluate the event lazily: normal use never builds diagnostic strings.
    static func record(_ event: @autoclosure () -> String) {
        guard isEnabled else { return }
        writer.append([event()])
    }

    /// Mirror the same diagnostic event under the existing consent/token gate.
    static func recordMicrophoneEvidence(_ event: @autoclosure () -> String) {
        microphoneEvidenceWriter()?.write(event())
    }

    static func microphoneEvidenceWriter() -> MicrophoneEvidenceWriter? {
        preferenceDidChange(isEnabled)
        return MicrophoneEvidenceWriter(token: inputConsent.token, permits: { permitsInputTrace($0) }) { line in
            writer.append([line], mirrored: true)
        }
    }

    /// Called for both ON and OFF, including an OFF/ON cycle between async
    /// receipt polls. Previously buffered evidence cannot cross that boundary.
    static func preferenceDidChange(_ enabled: Bool) {
        if inputConsent.isEnabled != enabled { flush() }
        inputConsent.setEnabled(enabled)
    }

    static func inputTrace(takeID: UUID) -> InputDiagnosticTrace? {
        preferenceDidChange(isEnabled)
        guard let token = inputConsent.token else { return nil }
        return InputDiagnosticTrace(takeID: takeID, consent: token)
    }

    static func permitsInputTrace(_ token: InputDiagnosticConsent.Token) -> Bool {
        preferenceDidChange(isEnabled)
        return inputConsent.allows(token)
    }

    static func writeInputTrace(_ lines: @autoclosure () -> [String],
                                consent: InputDiagnosticConsent.Token) {
        // Gate again immediately before formatting/writing. No asynchronous
        // writer can append old evidence after logging is disabled or deleted.
        guard permitsInputTrace(consent) else { return }
        writer.append(lines())
    }

    /// Streaming breadcrumbs use the SAME opt-in/revocation token and bounded
    /// stores as input diagnostics, with a longer-retained microphone mirror.
    static func microphoneTrace(captureID: UUID, explicitSelection: Bool) -> MicrophonePreparationDiagnostics? {
        preferenceDidChange(isEnabled)
        guard let token = inputConsent.token else { return nil }
        let build = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        return MicrophonePreparationDiagnostics { entry in
            Task { @MainActor in
                guard permitsInputTrace(token) else { return }
                let prefix = "mic_start v=1 capture=\(captureID.uuidString) build=\(build) explicit=\(explicitSelection ? 1 : 0)"
                writer.append(entry.logLines(prefix: prefix), mirrored: true)
            }
        }
    }

    /// Stopping logging never erases an old file. Deletion is user-initiated.
    static func deleteExistingFiles() throws {
        flush()
        inputConsent.invalidate()
        try writer.deleteAll()
    }
}
#endif
