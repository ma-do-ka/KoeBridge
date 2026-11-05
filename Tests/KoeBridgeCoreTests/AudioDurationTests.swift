import Testing
@testable import KoeBridgeCore

struct AudioDurationTests {
    @Test func rapidEmptyTapsDismissInsteadOfCloudFinalization() {
        #expect(QuickNoInputPolicy.mayBeQuickExit(seconds: 0.20))
        #expect(!QuickNoInputPolicy.mayBeQuickExit(seconds: 1.0))
        // A short but audible utterance cannot silently become "no input".
        #expect(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.10, pcmBytes: 6_000, peak: 0.9, hasText: false, audioDropped: false))
        #expect(QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.10, pcmBytes: 1_000, peak: 0.001, hasText: false, audioDropped: false))
        #expect(QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.35, pcmBytes: 12_000, peak: 0.001, hasText: false, audioDropped: false))
        #expect(QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.25, pcmBytes: 0, peak: 0, hasText: false, audioDropped: false))
    }

    @Test func shortRealSpeechAndActualFailureAreNotSuppressed() {
        #expect(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.30, pcmBytes: 8_000, peak: 0.15, hasText: false, audioDropped: false))
        #expect(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.25, pcmBytes: 4_000, peak: 0.001, hasText: true, audioDropped: false))
        #expect(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.09, pcmBytes: 400, peak: 0, hasText: false, audioDropped: true))
        #expect(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.09, pcmBytes: 2_000, peak: 0.3, hasText: false, audioDropped: false))
        #expect(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 1.2, pcmBytes: 40_000, peak: 0, hasText: false, audioDropped: false))
        #expect(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 1.2, pcmBytes: 0, peak: 0, hasText: false, audioDropped: false))
        #expect(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: .nan, pcmBytes: 0, peak: 0, hasText: false, audioDropped: false))
        #expect(!QuickNoInputPolicy.shouldSkipRecognition(
            seconds: 0.2, pcmBytes: 5_000, peak: .nan, hasText: false, audioDropped: false))
    }

    @Test func immediateSecondPressDoesNotWaitForCloudFinal() {
        #expect(!AudioDurationPolicy.hasEnoughAudio(pcmBytes: 0))
        #expect(!AudioDurationPolicy.hasEnoughAudio(pcmBytes: 3_199))
        #expect(AudioDurationPolicy.hasEnoughAudio(pcmBytes: 3_200))
        #expect(AudioDurationPolicy.hasEnoughAudio(pcmBytes: 6_400))
        #expect(AudioDurationPolicy.hasEnoughAudio(pcmBytes: 32_000))
    }
}
