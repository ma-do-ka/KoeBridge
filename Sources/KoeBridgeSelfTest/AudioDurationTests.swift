import KoeBridgeCore

struct AudioDurationTests {
    func immediateSecondPressDoesNotWaitForCloudFinal() {
        check(!AudioDurationPolicy.hasEnoughAudio(pcmBytes: 0))
        check(!AudioDurationPolicy.hasEnoughAudio(pcmBytes: 3_199))
        check(AudioDurationPolicy.hasEnoughAudio(pcmBytes: 3_200))
        check(AudioDurationPolicy.hasEnoughAudio(pcmBytes: 6_400))
        check(AudioDurationPolicy.hasEnoughAudio(pcmBytes: 32_000))
    }
}
