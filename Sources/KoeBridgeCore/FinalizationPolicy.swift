import Foundation

/// The connection owns exactly one manual activity and one end operation.
/// Begin only after all preceding PCM writes have completed. A terminal event
/// received during the end write belongs to that activity, but is not usable
/// until the write succeeds. This avoids relying on task-resumption order.
public struct TimedManualEndpointState<Instant: Sendable>: Sendable {
    public enum Phase: Equatable, Sendable {
        case recording, writingEnd, endWritten, failed, cancelled
    }

    public private(set) var phase: Phase = .recording
    public private(set) var writeCompletedAt: Instant?
    /// Time at which BOTH the end write and its server acknowledgement are
    /// known. This is not the raw arrival time of a possibly early reply.
    public private(set) var acknowledgedEndAt: Instant?
    private var hasPendingEndAcknowledgement = false

    public init() {}

    public mutating func beginEnd() {
        guard phase == .recording else { return }
        phase = .writingEnd
    }

    public mutating func receiveTurnComplete(at now: Instant) {
        receiveEndAcknowledgement(at: now)
    }

    /// Gemini Transcribe's manual flush acknowledges the activity with a
    /// root-level voiceActivity ACTIVITY_END. It uses the same write gate.
    public mutating func receiveActivityEnd(at now: Instant) {
        receiveEndAcknowledgement(at: now)
    }

    private mutating func receiveEndAcknowledgement(at now: Instant) {
        switch phase {
        case .writingEnd:
            hasPendingEndAcknowledgement = true
        case .endWritten:
            acknowledgedEndAt = now
        case .recording, .failed, .cancelled:
            break
        }
    }

    public mutating func endWriteSucceeded(at now: Instant) {
        guard phase == .writingEnd else { return }
        phase = .endWritten
        writeCompletedAt = now
        if hasPendingEndAcknowledgement { acknowledgedEndAt = now }
        hasPendingEndAcknowledgement = false
    }

    public mutating func endWriteFailed() {
        guard phase == .writingEnd else { return }
        phase = .failed
        hasPendingEndAcknowledgement = false
        acknowledgedEndAt = nil
    }

    public mutating func cancel() {
        phase = .cancelled
        hasPendingEndAcknowledgement = false
        acknowledgedEndAt = nil
    }
}

/// Gemini Transcribe Live emits an authoritative `inputTranscription` for a
/// speech SEGMENT. It is not guaranteed to arrive after `activityEnd` and
/// `turnComplete` is neither mandatory nor ordered relative to that text.
/// Transcribe's manual endpoint can instead return voiceActivity ACTIVITY_END.
///
/// Safety rule: Never auto-type an uncommitted interim. A final segment's
/// arrival time is not proof that all submitted audio was transcribed. Require
/// an activity-scoped completion acknowledged after the end-marker write has
/// succeeded, then a quiet period for independently delivered text to settle.
/// A transcription's optional `finished` flag can mark one speech segment;
/// it does not, by itself, establish that our activityEnd was processed.
public enum FinalizationPolicy {
    /// A bounded recovery policy, not a guarantee of the provider's latency.
    public static let maximumWaitSeconds: TimeInterval = 8

    public static func canFinish(endedAt: ContinuousClock.Instant, lastFinalAt: ContinuousClock.Instant?,
                                 endAcknowledgedAt: ContinuousClock.Instant?, now: ContinuousClock.Instant,
                                 hasPendingInterim: Bool = false, lastTranscriptionAt: ContinuousClock.Instant? = nil) -> Bool {
        guard !hasPendingInterim, let final = lastFinalAt, let ack = endAcknowledgedAt, ack >= endedAt else { return false }
        return now >= endedAt.advanced(by: .milliseconds(400)) &&
            now >= max(final, ack, lastTranscriptionAt ?? final).advanced(by: .milliseconds(250))
    }
}
