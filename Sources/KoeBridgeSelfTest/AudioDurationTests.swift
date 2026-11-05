import KoeBridgeCore

struct AudioDurationTests {
    func rapidEmptyInputIsNeutralButSpeechAndLossRemainReal() {
        check(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.10, pcmBytes: 5_000, peak: 0.50, hasText: false, audioDropped: false))
        check(QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.10, pcmBytes: 1_000, peak: 0.001, hasText: false, audioDropped: false))
        check(QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.4, pcmBytes: 14_000, peak: 0.001, hasText: false, audioDropped: false))
        check(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.3, pcmBytes: 8_000, peak: 0.15, hasText: false, audioDropped: false))
        check(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.2, pcmBytes: 4_000, peak: 0.001, hasText: true, audioDropped: false))
        check(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.08, pcmBytes: 100, peak: 0, hasText: false, audioDropped: true))
        check(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.09, pcmBytes: 2_000, peak: 0.3, hasText: false, audioDropped: false))
        check(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 1.2, pcmBytes: 40_000, peak: 0, hasText: false, audioDropped: false))
        check(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 1.2, pcmBytes: 0, peak: 0, hasText: false, audioDropped: false))
    }

    func immediateSecondPressDoesNotWaitForCloudFinal() {
        check(!AudioDurationPolicy.hasEnoughAudio(pcmBytes: 0))
        check(!AudioDurationPolicy.hasEnoughAudio(pcmBytes: 3_199))
        check(AudioDurationPolicy.hasEnoughAudio(pcmBytes: 3_200))
        check(AudioDurationPolicy.hasEnoughAudio(pcmBytes: 6_400))
        check(AudioDurationPolicy.hasEnoughAudio(pcmBytes: 32_000))
    }
}
