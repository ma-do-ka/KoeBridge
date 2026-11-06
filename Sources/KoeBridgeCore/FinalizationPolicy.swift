import Foundation

/// Gemini Transcribe Live emits an authoritative `inputTranscription` for a
/// speech SEGMENT. It is not guaranteed to arrive after `activityEnd` and
/// `turnComplete` is neither mandatory nor ordered relative to that text.
///
/// Safety rule: Never auto-type an uncommitted interim. A final segment's
/// arrival time is not proof that all submitted audio was transcribed. Require
/// an explicit completion after the end-marker write has completed, then a
/// short quiet period to allow independently delivered text frames to settle.
public enum FinalizationPolicy {
    /// A bounded recovery policy, not a guarantee of the provider's latency.
    public static let maximumWaitSeconds: TimeInterval = 8

    public static func canFinish(endedAt: Date, lastFinalAt: Date?,
                                 turnCompleteAt: Date?, now: Date,
                                 hasPendingInterim: Bool = false,
                                 lastTranscriptionAt: Date? = nil,
                                 transcriptionFinishedAt: Date? = nil) -> Bool {
        guard let lastFinalAt, now >= endedAt, !hasPendingInterim else { return false }
        let sinceStop = now.timeIntervalSince(endedAt)
        let sinceFinal = now.timeIntervalSince(lastFinalAt)
        let sinceUpdate = now.timeIntervalSince(lastTranscriptionAt ?? lastFinalAt)
        guard sinceFinal >= 0, sinceUpdate >= 0 else { return false }

        let completion = [turnCompleteAt, transcriptionFinishedAt].compactMap { $0 }.max()
        guard let completion, completion >= endedAt else { return false }
        return sinceStop >= 0.40 && sinceFinal >= 0.25
            && now.timeIntervalSince(completion) >= 0.25 && sinceUpdate >= 0.25
    }
}
