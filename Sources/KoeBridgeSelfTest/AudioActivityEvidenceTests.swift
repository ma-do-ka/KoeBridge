import Foundation
import KoeBridgeCore

struct AudioActivityEvidenceTests {
    private func sample(_ samples: [Float]) -> AudioActivityEvidence {
        var meter = AudioActivityMeter()
        samples.withUnsafeBufferPointer { meter.observe($0) }
        return meter.evidence
    }
    private func modulatedTone(_ amplitude: Float) -> [Float] {
        (0..<16_000).map { index in
            guard (3_200..<10_000).contains(index) else { return 0 }
            return Float(sin(Double(index) / 9.5)) * amplitude * (0.4 + Float(index % 1_200) / 1_200)
        }
    }
    private func proof() -> SpeechVerification {
        var proof = SpeechVerification()
        proof.started(); proof.observe(confidence: 0.95, start: 0, duration: 0.5)
        return proof
    }
    func silenceCannotBeConfirmedByModelText() {
        let silence = sample(Array(repeating: 0, count: 48_000))
        check(silence.classification == .nearSilence)
        check(AudioActivityPolicy.shouldDiscardQuietTake(silence, pcmBytes: 96_000, hasTranscript: false))
        check(!AudioActivityPolicy.shouldDiscardQuietTake(silence, pcmBytes: 96_000, hasTranscript: true))
        check(AudioActivityPolicy.requiresReview(silence))
        check(!AudioActivityPolicy.mayShowInterim(silence))
        var pending = SpeechAdmissionBuffer()
        check(pending.append(Data(repeating: 0, count: 32_000), proof: SpeechVerification()) == nil)
        check(pending.finish(proof: SpeechVerification(), isDigitalSilence: true) == nil)
    }
    func ambientNoiseAndClickRequireReview() {
        check(sample(Array(repeating: 0.005, count: 16_000)).classification == .uncertain)
        var click = Array(repeating: Float.zero, count: 16_000)
        click[100] = 0.8
        check(sample(click).classification == .uncertain)
        let fluctuating = sample(modulatedTone(0.03))
        check(fluctuating.activeFrames >= 4 && fluctuating.maximumFrameRMS >= 0.0025)
        check(fluctuating.modulation >= 0.12)
        check(AudioActivityPolicy.requiresReview(fluctuating))
        check(!AudioActivityPolicy.mayShowInterim(fluctuating))
    }
    func speechAndWhisperCanBeInput() {
        for amplitude in [Float(0.0006), 0.007, 0.018] {
            let signal = sample(modulatedTone(amplitude))
            check(signal.classification == .uncertain)
            check(signal.withSpeechVerification(proof()).classification == .activity)
        }
        var failed = proof(); failed.fail()
        check(!failed.allowsTranscript)
        var timeout = proof(); timeout.timeOut(); timeout.complete()
        check(!timeout.allowsTranscript)
    }
    func weakSpeechCannotBeThrownAway() {
        let low = sample(modulatedTone(0.0006))
        check(AudioActivityPolicy.requiresReview(low))
        check(!AudioActivityPolicy.shouldDiscardQuietTake(low, pcmBytes: 32_000, hasTranscript: false))
        var tail = Array(repeating: Float.zero, count: 3_200)
        tail.append(0.01)
        check(sample(tail).classification == .uncertain)
        var pending = SpeechAdmissionBuffer()
        let audio = Data(repeating: 1, count: 3_200)
        check(pending.append(audio, proof: SpeechVerification()) == nil)
        check(pending.finish(proof: SpeechVerification(), isDigitalSilence: false) == audio)
        check(pending.finish(proof: proof(), isDigitalSilence: false) == nil)
    }
    func invalidPCMDoesNotAuthorizeInput() {
        var signal = modulatedTone(0.02)
        signal[500] = .nan
        check(sample(signal).invalidSamples == 1)
        check(sample(signal).withSpeechVerification(proof()).classification == .uncertain)
        var observed = SpeechVerification(); observed.started()
        observed.observe(confidence: 0.7, start: 0, duration: 0.5)
        observed.observe(confidence: 0.7, start: 0, duration: 0.5)
        check(!observed.allowsTranscript)
        observed.observe(confidence: 0.7, start: 0.25, duration: 0.5)
        check(observed.allowsTranscript)
        observed.timeOut()
        observed.observe(confidence: 1, start: 1, duration: 0.5)
        check(!observed.allowsTranscript)
    }
}
