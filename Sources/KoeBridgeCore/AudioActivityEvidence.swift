import Foundation

/// Content-free acoustic evidence only; environmental sounds are not proof of a voice.
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

    public var classification: Classification {
        guard frames >= 4 else { return .unavailable }
        guard invalidSamples == 0 else { return .uncertain }
        // Reject only near-digital silence; keep quieter possible speech recoverable.
        if maximumFrameRMS < 0.0007, peak < 0.005 { return .nearSilence }
        // Sustained and changing energy can corroborate speech, not prove it.
        if activeFrames >= 4, longestActiveRun >= 3,
           maximumFrameRMS >= 0.0025, modulation >= 0.12 { return .activity }
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
        return AudioActivityEvidence(frames: frameCount, activeFrames: activeCount,
                                     longestActiveRun: longestRun, peak: globalPeak,
                                     maximumFrameRMS: maximumRMS, modulation: modulation,
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
