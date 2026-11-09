import Foundation

/// One take's leading audio, retained only in RAM. Recognition is prepared in
/// parallel, but receives no PCM until independent speech evidence arrives.
/// Once admitted, pauses never close the stream or cut the user's sentence.
public struct SpeechAdmissionBuffer: Sendable {
    public static let preRollSeconds = 1.0
    public struct OpenGeometry: Equatable, Sendable {
        public let firstSpeechStart: TimeInterval?
        public let releasedFrom: TimeInterval
        public let bufferedDuration: TimeInterval
    }
    public private(set) var openGeometry: OpenGeometry?
    public static let maximumBytes = 490 * 32_000
    public private(set) var opened = false
    public private(set) var overflowed = false
    private var ended = false
    private var pending = Data()
    public init() {}

    public mutating func append(_ pcm: Data, proof: SpeechVerification) -> Data? {
        guard !ended, !overflowed else { return nil }
        if opened { return pcm }
        guard pcm.count <= Self.maximumBytes - pending.count else {
            pending = Data(); overflowed = true; return nil
        }
        pending.append(pcm)
        guard proof.allowsTranscript else { return nil }
        return open(proof: proof)
    }

    /// Ambiguous speech is still sent at stop for recovery, but its failed speech
    /// proof independently prohibits preview/autotyping. Exact zero PCM is omitted.
    public mutating func finish(proof: SpeechVerification, isDigitalSilence: Bool) -> Data? {
        guard !ended else { return nil }
        ended = true
        defer { pending = Data() }
        guard !overflowed, !opened, !isDigitalSilence else { return nil }
        if proof.allowsTranscript { return open(proof: proof) }
        return pending.isEmpty ? nil : pending
    }

    private mutating func open(proof: SpeechVerification) -> Data? {
        guard !pending.isEmpty else { return nil }
        opened = true
        // Admission still requires independent speech proof. Longer pre-roll
        // only protects the first syllable after confirmation.
        let start = max(0, (proof.firstSpeechStart ?? 0) - Self.preRollSeconds)
        let rawOffset = min(Double(pending.count), start * 32_000)
        let offset = (Int(rawOffset) / 2) * 2
        // Invalid geometry never drops all captured speech.
        let actualOffset = offset < pending.count ? offset : 0
        openGeometry = OpenGeometry(firstSpeechStart: proof.firstSpeechStart,
                                    releasedFrom: Double(actualOffset) / 32_000,
                                    bufferedDuration: Double(pending.count) / 32_000)
        let result = pending.subdata(in: actualOffset..<pending.count)
        pending = Data()
        return result
    }
}
