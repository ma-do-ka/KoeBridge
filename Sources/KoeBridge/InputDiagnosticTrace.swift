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
    private let permits: (InputDiagnosticConsent.Token) -> Bool
    private(set) var buffer: InputDiagnosticBuffer
    private var finished = false

    init(takeID: UUID, consent: InputDiagnosticConsent.Token,
         permits: ((InputDiagnosticConsent.Token) -> Bool)? = nil) {
        self.takeID = takeID
        self.consent = consent
        self.permits = permits ?? { DiagnosticLog.permitsInputTrace($0) }
        buffer = InputDiagnosticBuffer(takeID: takeID)
    }

    var isCollecting: Bool {
        guard !finished else { return false }
        guard permits(consent) else {
            buffer.discard()
            finished = true
            return false
        }
        return true
    }

    @discardableResult
    func record(_ kind: InputDiagnosticEvent.Kind, stage: InputDiagnosticEvent.Stage,
                _ fields: @autoclosure () -> [InputDiagnosticEvent.Field: InputDiagnosticEvent.Value] = [:]) -> Int? {
        guard isCollecting else { return nil }
        var evidence = fields()
        let uptime = ProcessInfo.processInfo.systemUptime
        let uptimeMS = Self.uptimeMilliseconds(uptime)
        evidence[.uptimeMS] = .integer(uptimeMS)
        buffer.append(InputDiagnosticEvent(kind: kind, stage: stage, fields: evidence),
                      elapsedMS: Self.milliseconds(since: beganAt))
        return uptimeMS
    }

    static func uptimeMilliseconds(_ uptime: TimeInterval) -> Int {
        uptime.isFinite ? Int(min(Double(Int.max / 2), max(0, uptime * 1_000))) : 0
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
