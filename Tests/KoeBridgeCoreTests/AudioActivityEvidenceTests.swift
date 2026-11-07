import Foundation
import Testing
@testable import KoeBridgeCore

struct AudioActivityEvidenceTests {
    private func sample(_ samples: [Float], splitAt: Int? = nil) -> AudioActivityEvidence {
        var meter = AudioActivityMeter()
        if let splitAt {
            Array(samples.prefix(splitAt)).withUnsafeBufferPointer { meter.observe($0) }
            Array(samples.dropFirst(splitAt)).withUnsafeBufferPointer { meter.observe($0) }
        } else { samples.withUnsafeBufferPointer { meter.observe($0) } }
        return meter.evidence
    }
    private func utterance(_ amplitude: Float) -> [Float] {
        (0..<16_000).map { index in
            guard (3_200..<10_000).contains(index) else { return 0 }
            let envelope = Float(index % 1_200) / 1_200
            return Float(sin(Double(index) / 9.5)) * amplitude * (0.4 + envelope)
        }
    }
    @Test func silenceDoesNotAuthorizeModelText() {
        let silence = sample(Array(repeating: 0, count: 3 * 16_000))
        #expect(silence.classification == .nearSilence)
        #expect(AudioActivityPolicy.shouldDiscardQuietTake(silence, pcmBytes: 96_000, hasTranscript: false))
        #expect(!AudioActivityPolicy.shouldDiscardQuietTake(silence, pcmBytes: 96_000, hasTranscript: true))
        #expect(AudioActivityPolicy.requiresReview(silence))
        #expect(!AudioActivityPolicy.mayShowInterim(silence))
    }
    @Test func steadyAmbientHumCannotAuthorizeAutomaticTyping() {
        let humming = sample(Array(repeating: 0.005, count: 16_000))
        #expect(humming.classification == .uncertain)
        #expect(AudioActivityPolicy.requiresReview(humming))
    }
    @Test func singleClickCannotAuthorizeAutomaticTyping() {
        var samples = Array(repeating: Float.zero, count: 16_000)
        samples[100] = 0.8
        let click = sample(samples)
        #expect(click.classification == .uncertain)
        #expect(AudioActivityPolicy.requiresReview(click))
    }
    @Test func speechAndModerateWhisperRemainEligible() {
        for amplitude in [Float(0.007), Float(0.018)] {
            let speech = sample(utterance(amplitude))
            #expect(speech.classification == .activity)
            #expect(!AudioActivityPolicy.requiresReview(speech))
            #expect(AudioActivityPolicy.mayShowInterim(speech))
        }
    }
    @Test func faintSpeechIsRecoverableAndNotDiscarded() {
        let low = sample(utterance(0.0006))
        #expect(AudioActivityPolicy.requiresReview(low))
        #expect(!AudioActivityPolicy.shouldDiscardQuietTake(low, pcmBytes: 32_000, hasTranscript: true))
    }
    @Test func chunkBoundariesDoNotChangeEvidence() {
        let samples = utterance(0.008)
        #expect(sample(samples, splitAt: 49) == sample(samples))
        #expect(sample(samples, splitAt: 3_999) == sample(samples))
    }
    @Test func nonFinitePCMDoesNotAuthorizeTyping() {
        var samples = utterance(0.02)
        samples[500] = .nan
        let invalid = sample(samples)
        #expect(invalid.invalidSamples == 1)
        #expect(invalid.classification == .uncertain)
    }
    @Test func tooLittlePCMIsNotSilenceProof() {
        let tiny = sample(Array(repeating: 0.008, count: 200))
        #expect(tiny.classification == .unavailable)
        #expect(!AudioActivityPolicy.shouldDiscardQuietTake(tiny, pcmBytes: 400, hasTranscript: false))
    }
}
