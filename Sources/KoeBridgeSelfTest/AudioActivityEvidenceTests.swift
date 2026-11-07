import Foundation
import KoeBridgeCore

struct AudioActivityEvidenceTests {
    private func sample(_ samples: [Float]) -> AudioActivityEvidence {
        var meter = AudioActivityMeter()
        samples.withUnsafeBufferPointer { meter.observe($0) }
        return meter.evidence
    }
    private func utterance(_ amplitude: Float) -> [Float] {
        (0..<16_000).map { index in
            guard (3_200..<10_000).contains(index) else { return 0 }
            let envelope = Float(index % 1_200) / 1_200
            return Float(sin(Double(index) / 9.5)) * amplitude * (0.4 + envelope)
        }
    }
    func silenceCannotBeConfirmedByModelText() {
        let silence = sample(Array(repeating: 0, count: 3 * 16_000))
        check(silence.classification == .nearSilence)
        check(AudioActivityPolicy.shouldDiscardQuietTake(silence, pcmBytes: 96_000, hasTranscript: false))
        check(!AudioActivityPolicy.shouldDiscardQuietTake(silence, pcmBytes: 96_000, hasTranscript: true))
        check(AudioActivityPolicy.requiresReview(silence))
        check(!AudioActivityPolicy.mayShowInterim(silence))
    }
    func ambientNoiseAndClickRequireReview() {
        let hum = sample(Array(repeating: 0.005, count: 16_000))
        check(hum.classification == .uncertain)
        var click = Array(repeating: Float.zero, count: 16_000)
        click[100] = 0.8
        check(sample(click).classification == .uncertain)
    }
    func speechAndWhisperCanBeInput() {
        for amplitude in [Float(0.007), Float(0.018)] {
            let voice = sample(utterance(amplitude))
            check(voice.classification == .activity)
            check(!AudioActivityPolicy.requiresReview(voice))
        }
    }
    func weakSpeechCannotBeThrownAway() {
        let low = sample(utterance(0.0006))
        check(AudioActivityPolicy.requiresReview(low))
        check(!AudioActivityPolicy.shouldDiscardQuietTake(low, pcmBytes: 32_000, hasTranscript: true))
    }
    func invalidPCMDoesNotAuthorizeInput() {
        var voice = utterance(0.02)
        voice[500] = .nan
        let observed = sample(voice)
        check(observed.invalidSamples == 1)
        check(observed.classification == .uncertain)
    }
}
