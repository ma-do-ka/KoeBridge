import Foundation

/// PCM energy remains useful diagnostic evidence, but cannot establish speech.
public struct AudioActivityEvidence: Equatable, Sendable {
    public enum Classification: String, Sendable {
        case unavailable, nearSilence, uncertain, activity
    }
    public let frames: Int
    public let activeFrames: Int
    public let longestActiveRun: Int
    public let peak: Float
    public let maximumFrameRMS: Float
    public let modulation: Float
    public let invalidSamples: Int
    public private(set) var speechVerification: SpeechVerification? = nil

    public func withSpeechVerification(_ speech: SpeechVerification) -> Self {
        var copy = self
        copy.speechVerification = speech
        return copy
    }

    public var classification: Classification {
        guard frames >= 4 else { return .unavailable }
        guard invalidSamples == 0 else { return .uncertain }
        if speechVerification?.allowsTranscript == true { return .activity }
        // Exact digital silence is unambiguous. A low-amplitude voice is not:
        // never discard it just because it is below a hand-tuned RMS threshold.
        if maximumFrameRMS == 0, peak == 0 { return .nearSilence }
        return .uncertain
    }
}

/// Bounded online 20ms/16kHz frame measurements; stores no audio or text.
public struct AudioActivityMeter {
    public static let frameSamples = 320
    public static let activityRMS: Float = 0.0018
    private var accumulatedSamples = 0
    private var accumulatedPower: Double = 0
    private var peak: Float = 0
    private var frameCount = 0
    private var activeCount = 0
    private var currentRun = 0
    private var longestRun = 0
    private var globalPeak: Float = 0
    private var maximumRMS: Float = 0
    private var rmsSum: Double = 0
    private var rmsSquaresSum: Double = 0
    private var invalidCount = 0

    public init() {}

    public mutating func observe(_ samples: UnsafeBufferPointer<Float>) {
        for raw in samples {
            let value: Float
            if raw.isFinite { value = raw }
            else { invalidCount += 1; value = 0 }
            let amplitude = min(abs(value), 1)
            accumulatedPower += Double(amplitude) * Double(amplitude)
            peak = max(peak, amplitude)
            accumulatedSamples += 1
            if accumulatedSamples == Self.frameSamples { completeFrame() }
        }
    }
    private mutating func completeFrame() {
        let rms = Float(sqrt(accumulatedPower / Double(Self.frameSamples)))
        frameCount += 1
        globalPeak = max(globalPeak, peak)
        maximumRMS = max(maximumRMS, rms)
        rmsSum += Double(rms)
        rmsSquaresSum += Double(rms) * Double(rms)
        if rms >= Self.activityRMS {
            activeCount += 1
            currentRun += 1
            longestRun = max(longestRun, currentRun)
        } else { currentRun = 0 }
        accumulatedSamples = 0
        accumulatedPower = 0
        peak = 0
    }
    public var evidence: AudioActivityEvidence {
        let mean = frameCount > 0 ? rmsSum / Double(frameCount) : 0
        let variance = frameCount > 0 ? max(0, rmsSquaresSum / Double(frameCount) - mean * mean) : 0
        let modulation = mean > 0 ? Float(sqrt(variance) / mean) : 0
        // Include the incomplete tail so a last-millisecond sound cannot vanish
        // behind completed all-zero frames when deciding whether to discard.
        let tailRMS = accumulatedSamples > 0
            ? Float(sqrt(accumulatedPower / Double(accumulatedSamples))) : 0
        return AudioActivityEvidence(frames: frameCount, activeFrames: activeCount,
                                     longestActiveRun: longestRun, peak: max(globalPeak, peak),
                                     maximumFrameRMS: max(maximumRMS, tailRMS), modulation: modulation,
                                     invalidSamples: invalidCount)
    }
}
public enum AudioActivityPolicy {
    public static func shouldDiscardQuietTake(_ evidence: AudioActivityEvidence,
                                               pcmBytes: Int, hasTranscript: Bool) -> Bool {
        evidence.classification == .nearSilence && pcmBytes >= 3_200 && !hasTranscript
    }
    public static func requiresReview(_ evidence: AudioActivityEvidence) -> Bool {
        evidence.classification != .activity
    }
    public static func mayShowInterim(_ evidence: AudioActivityEvidence) -> Bool {
        evidence.classification == .activity
    }
}
