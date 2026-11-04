import Foundation

/// Gemini Live sends unstable hypotheses and finalized segments separately.
/// Never paste the unstable hypothesis. Avoid doubling up repeated final segments.
public struct TranscriptAssembler {
    public private(set) var finalized = ""
    public private(set) var interim = ""
    public private(set) var finalCount = 0
    private var nextFinalStartsNewActivity = false

    /// Called when the client sends a NEW manual activityStart. The server's
    /// turnComplete is not a reliable turn separator because final and
    /// turnComplete may arrive out of order.
    public mutating func beginActivity() {
        nextFinalStartsNewActivity = true
        interim = ""
    }
    public init() {}

    public var displayText: String {
        if interim.isEmpty { return finalized }
        if finalized.isEmpty { return interim }
        if interim.hasPrefix(finalized) { return interim }
        return join(finalized, interim)
    }

    public mutating func apply(_ event: TranscribeEvent) {
        switch event {
        case .interim(let text):
            let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Network messages need not be ordered. A retransmission of an
            // already committed transcript is not a new unfinished segment.
            if !finalized.isEmpty && (candidate == finalized || finalized.hasSuffix(candidate)) {
                interim = ""
            } else {
                interim = candidate
            }
        case .final(let text):
            let segment = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { return }
            // A repeated phrase in a NEW turn is valid dictation, not a
            // retransmission ("はい" followed by another "はい").
            // Within one turn, ignore an identical retransmitted segment.
            if !nextFinalStartsNewActivity && (segment == finalized || finalized.hasSuffix(segment)) {
                interim = ""
                return
            }
            // Some versions deliver a cumulative hypothesis instead of a new segment.
            if !nextFinalStartsNewActivity && segment.hasPrefix(finalized) && !finalized.isEmpty {
                finalized = segment
            } else {
                finalized = join(finalized, segment)
            }
            interim = ""
            finalCount += 1
            nextFinalStartsNewActivity = false
        default: break
        }
    }

    public var committedText: String { finalized }
    public var recoveryText: String { finalized.isEmpty ? interim : finalized }

    private func join(_ a: String, _ b: String) -> String {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        guard let left = a.last, let right = b.first else { return a + b }
        let shouldSpace = left.isASCII && right.isASCII && (left.isLetter || left.isNumber) && (right.isLetter || right.isNumber)
        return a + (shouldSpace ? " " : "") + b
    }
}
