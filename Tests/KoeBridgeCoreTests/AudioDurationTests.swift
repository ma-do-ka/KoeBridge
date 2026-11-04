import Testing
@testable import KoeBridgeCore

struct AudioDurationTests {
    @Test func immediateSecondPressDoesNotWaitForCloudFinal() {
        #expect(!AudioDurationPolicy.hasEnoughAudio(pcmBytes: 0))
        #expect(!AudioDurationPolicy.hasEnoughAudio(pcmBytes: 3_199))
        #expect(AudioDurationPolicy.hasEnoughAudio(pcmBytes: 3_200))
        #expect(AudioDurationPolicy.hasEnoughAudio(pcmBytes: 6_400))
        #expect(AudioDurationPolicy.hasEnoughAudio(pcmBytes: 32_000))
    }
}
