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
    // One Live dictation can last eight minutes. Charge the output, separators,
    // and every retained dedup key/value before mutating either collection.
    public struct FinalBudget: Sendable {
        public let bytes: Int
        public let identities: Int
        public static let dictation = Self(bytes: 256 * 1024, identities: 2048)
        public init(bytes: Int, identities: Int) {
            precondition(bytes > 0 && identities > 0)
            self.bytes = bytes
            self.identities = identities
        }
    }
    private let budget: FinalBudget?
    private var chargedBytes = 0
    public private(set) var exceededFinalBudget = false
    public init(budget: FinalBudget? = nil) { self.budget = budget }

    public var displayText: String {
        if interim.isEmpty { return finalized }
        if finalized.isEmpty { return interim }
        return join(finalized, interim)
    }

    public mutating func apply(_ event: TranscribeEvent, segmentIdentity: String? = nil) {
        guard !exceededFinalBudget else { return }
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
            let previous = segmentIdentity.flatMap { acceptedSegments[$0] }
            if previous?.contains(segment) == true { return }
            if let budget {
                let size = segment.utf8.count
                let identityBytes = previous == nil ? segmentIdentity?.utf8.count ?? 0 : 0
                let cost = size + (needsSpace(finalized, segment) ? 1 : 0)
                    + (segmentIdentity == nil ? 0 : size) + identityBytes
                guard cost <= budget.bytes - chargedBytes,
                      segmentIdentity == nil || previous != nil || acceptedSegments.count < budget.identities else {
                    // Even an oversized first final leaves a bounded, manual-only prefix.
                    if finalized.isEmpty && interim.isEmpty {
                        var remaining = budget.bytes - chargedBytes
                        for scalar in segment.unicodeScalars {
                            guard scalar.utf8.count <= remaining else { break }
                            interim.unicodeScalars.append(scalar)
                            remaining -= scalar.utf8.count
                        }
                    }
                    exceededFinalBudget = true
                    return
                }
                chargedBytes += cost
            }
            if let segmentIdentity {
                if previous != nil { hasConflictingFinals = true }
                acceptedSegments[segmentIdentity, default: []].insert(segment)
            }
            finalized = join(finalized, segment)
            interim = ""
            finalCount += 1
        default: break
        }
    }

    /// Preserve the assembler's existing spacing, including the tail separator.
    public var preview: RecognitionPreview {
        RecognitionPreview(finalizedPrefix: finalized,
                           volatileTail: String(displayText.dropFirst(finalized.count)))
    }

    public var committedText: String { exceededFinalBudget ? "" : finalized }

    /// Failed recognition is saved as *partial* history, never auto-inserted.
    /// Preserve the pending suffix too; the previous implementation silently
    /// dropped interim instructions whenever a finalized prefix existed.
    public var recoveryText: String { displayText }

    private func join(_ a: String, _ b: String) -> String {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        return a + (needsSpace(a, b) ? " " : "") + b
    }

    private func needsSpace(_ a: String, _ b: String) -> Bool {
        guard let left = a.last, let right = b.first else { return false }
        return left.isASCII && right.isASCII && (left.isLetter || left.isNumber) && (right.isLetter || right.isNumber)
    }
}
