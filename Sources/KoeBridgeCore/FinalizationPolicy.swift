import Foundation

/// Gemini Transcribe Live emits an authoritative `inputTranscription` for a
/// speech SEGMENT. It is not guaranteed to arrive after `audioStreamEnd` and
/// `turnComplete` is neither mandatory nor ordered relative to that text.
///
/// Safety rule: Never auto-type an uncommitted interim. Without server-side
/// end-of-turn acknowledgement, a final that predates stop by many seconds
/// could omit newer speech and must remain a recovery-only transcript.
public enum FinalizationPolicy {
    public static func canFinish(endedAt: Date, lastFinalAt: Date?,
                                 turnCompleteAt: Date?, now: Date,
                                 hasPendingInterim: Bool = false,
                                 lastTranscriptionAt: Date? = nil) -> Bool {
        guard let lastFinalAt, now >= endedAt, !hasPendingInterim else { return false }
        let sinceStop = now.timeIntervalSince(endedAt)
        let sinceFinal = now.timeIntervalSince(lastFinalAt)
        let sinceUpdate = now.timeIntervalSince(lastTranscriptionAt ?? lastFinalAt)
        guard sinceFinal >= 0, sinceUpdate >= 0 else { return false }

        // An explicit completion received AFTER stream end can settle an older
        // segment. No dependency on the ordering of final vs. turnComplete.
        if let complete = turnCompleteAt, complete >= endedAt {
            return sinceStop >= 0.40 && sinceFinal >= 0.25
                && now.timeIntervalSince(complete) >= 0.25 && sinceUpdate >= 0.25
        }

        // A terminal final may arrive during the last part of a recording,
        // before audioStreamEnd is transmitted. The old code rejected it
        // forever unless it was within 400 ms of stop. Accept reasonably
        // recent FINAL text after a brief settle, but never a stale prefix.
        guard lastFinalAt >= endedAt.addingTimeInterval(-1.50) else { return false }
        return sinceStop >= 0.70 && sinceFinal >= 0.35 && sinceUpdate >= 0.35
    }
}
