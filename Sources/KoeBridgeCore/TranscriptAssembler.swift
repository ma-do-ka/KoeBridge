import Foundation

/// Gemini Live sends unstable hypotheses and finalized segments separately.
/// Never paste the unstable hypothesis. Final segments are incremental, not
/// cumulative. Repeated words are valid speech even within one activity.
public struct TranscriptAssembler {
    public private(set) var finalized = ""
    public private(set) var interim = ""
    public private(set) var finalCount = 0
    public private(set) var hasConflictingFinals = false
    private var acceptedSegments: [String: Set<String>] = [:]

    /// Called when the client sends a NEW manual activityStart. The server's
    /// turnComplete is not a reliable turn separator because final and
    /// turnComplete may arrive out of order.
    public mutating func beginActivity() {
        acceptedSegments.removeAll(keepingCapacity: true)
        interim = ""
    }
    public init() {}

    public var displayText: String {
        if interim.isEmpty { return finalized }
        if finalized.isEmpty { return interim }
        return join(finalized, interim)
    }

    public mutating func apply(_ event: TranscribeEvent, segmentIdentity: String? = nil) {
        switch event {
        case .interim(let text):
            let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // An identical hypothesis may be a NEW repetition. Keep it pending
            // until a final arrives; never infer completion from text equality.
            interim = candidate
        case .final(let text):
            let segment = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { return }
            // Only a provider identity can establish a retransmission. Do not
            // clear a newer pending hypothesis when a prior final is replayed.
            if let segmentIdentity {
                if let previous = acceptedSegments[segmentIdentity] {
                    if previous.contains(segment) { return }
                    // Optional timing fields identify a time range, not a
                    // guaranteed unique server ID. Preserve conflicting text
                    // for recovery and disallow an automatic final result.
                    hasConflictingFinals = true
                }
                acceptedSegments[segmentIdentity, default: []].insert(segment)
            }
            finalized = join(finalized, segment)
            interim = ""
            finalCount += 1
        default: break
        }
    }

    public var committedText: String { finalized }

    /// Failed recognition is saved as *partial* history, never auto-inserted.
    /// Preserve the pending suffix too; the previous implementation silently
    /// dropped interim instructions whenever a finalized prefix existed.
    public var recoveryText: String { displayText }

    private func join(_ a: String, _ b: String) -> String {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        guard let left = a.last, let right = b.first else { return a + b }
        let shouldSpace = left.isASCII && right.isASCII && (left.isLetter || left.isNumber) && (right.isLetter || right.isNumber)
        return a + (shouldSpace ? " " : "") + b
    }
}
