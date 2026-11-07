#if os(macOS)
import Foundation
import KoeBridgeCore

/// One recording's opt-in evidence. Capturing evidence does no disk I/O and
/// never accepts transcript text, AX descriptions, window titles, or URLs.
/// The owner flushes only after input and receipt reconciliation have ended.
@MainActor final class InputDiagnosticTrace {
    let takeID: UUID
    private let consent: InputDiagnosticConsent.Token
    private let beganAt = ProcessInfo.processInfo.systemUptime
    private var buffer: InputDiagnosticBuffer
    private var finished = false

    init(takeID: UUID, consent: InputDiagnosticConsent.Token) {
        self.takeID = takeID
        self.consent = consent
        buffer = InputDiagnosticBuffer(takeID: takeID)
    }

    var isCollecting: Bool {
        guard !finished else { return false }
        guard DiagnosticLog.permitsInputTrace(consent) else {
            buffer.discard()
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
        buffer.append(InputDiagnosticEvent(kind: kind, stage: stage, fields: evidence),
                      elapsedMS: Self.milliseconds(since: beganAt))
    }

    func finish() {
        guard !finished else { return }
        finished = true
        defer { buffer.discard() }
        DiagnosticLog.writeInputTrace(buffer.renderedLines(), consent: consent)
    }

    static func milliseconds(since start: TimeInterval) -> Int {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard elapsed.isFinite else { return 0 }
        return Int(min(86_400_000, max(0, elapsed * 1_000)))
    }
}
#endif
