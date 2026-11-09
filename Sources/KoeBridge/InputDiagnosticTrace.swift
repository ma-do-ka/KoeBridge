#if os(macOS)
import Foundation
import KoeBridgeCore

/// One recording's bounded evidence. Ordinary diagnostics and developer
/// diagnostics use independent consent tokens and independent retention limits.
@MainActor final class InputDiagnosticTrace {
    let takeID: UUID
    private let standardConsent: InputDiagnosticConsent.Token?
    private let developerConsent: DeveloperDiagnosticsToken?
    private let beganAt = ProcessInfo.processInfo.systemUptime
    private var standardBuffer: InputDiagnosticBuffer?
    private var developerBuffer: InputDiagnosticBuffer?
    private var finished = false

    init(takeID: UUID, standardConsent: InputDiagnosticConsent.Token?,
         developerConsent: DeveloperDiagnosticsToken?) {
        self.takeID = takeID
        self.standardConsent = standardConsent
        self.developerConsent = developerConsent
        if standardConsent != nil {
            standardBuffer = InputDiagnosticBuffer(takeID: takeID)
        }
        if developerConsent != nil {
            developerBuffer = InputDiagnosticBuffer(
                takeID: takeID,
                maximumEvents: DeveloperDiagnosticsPolicy.developerInputTraceEvents,
                preservedInitialEvents: DeveloperDiagnosticsPolicy.developerInputTraceInitialEvents
            )
        }
    }

    var isCollecting: Bool {
        guard !finished else { return false }
        if standardBuffer != nil, !DiagnosticLog.permitsInputTrace(standardConsent) {
            standardBuffer?.discard()
            standardBuffer = nil
        }
        if developerBuffer != nil, !DeveloperDiagnostics.allows(developerConsent) {
            developerBuffer?.discard()
            developerBuffer = nil
        }
        if standardBuffer == nil && developerBuffer == nil {
            finished = true
            return false
        }
        return true
    }

    func record(_ kind: InputDiagnosticEvent.Kind, stage: InputDiagnosticEvent.Stage,
                _ fields: @autoclosure () -> [InputDiagnosticEvent.Field: InputDiagnosticEvent.Value] = [:]) {
        guard isCollecting else { return }
        var evidence = fields()
        let uptime = ProcessInfo.processInfo.systemUptime
        evidence[.uptimeMS] = .integer(uptime.isFinite
            ? Int(min(Double(Int.max / 2), max(0, uptime * 1_000))) : 0)
        let event = InputDiagnosticEvent(kind: kind, stage: stage, fields: evidence)
        let elapsed = Self.milliseconds(since: beganAt)
        standardBuffer?.append(event, elapsedMS: elapsed)
        developerBuffer?.append(event, elapsedMS: elapsed)
    }

    func finish() {
        guard !finished else { return }
        finished = true

        if let standardBuffer, DiagnosticLog.permitsInputTrace(standardConsent) {
            DiagnosticLog.writeInputTrace(standardBuffer.renderedLines(), consent: standardConsent!)
        }
        if let developerBuffer, DeveloperDiagnostics.allows(developerConsent) {
            DeveloperDiagnostics.writeInputTrace(
                takeID: takeID, lines: developerBuffer.renderedLines(),
                token: developerConsent
            )
        }
        standardBuffer?.discard()
        developerBuffer?.discard()
        standardBuffer = nil
        developerBuffer = nil
    }

    static func milliseconds(since start: TimeInterval) -> Int {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard elapsed.isFinite else { return 0 }
        return Int(min(86_400_000, max(0, elapsed * 1_000)))
    }
}
#endif
