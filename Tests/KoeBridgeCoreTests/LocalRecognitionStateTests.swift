import Testing
@testable import KoeBridgeCore

struct LocalRecognitionStateTests {
    @Test func cancelledPermissionCannotStartRecognition() {
        var state = LocalRecognitionState()
        let authorizationBegan = state.beginAuthorization()
        #expect(authorizationBegan)
        state.cancel()
        let recognitionBegan = state.beginRecognition()
        #expect(!recognitionBegan)
        let authorizationRestarted = state.beginAuthorization()
        #expect(!authorizationRestarted)
        let delayedResultAccepted = state.receive("遅延した結果", isFinal: true)
        #expect(!delayedResultAccepted)
        #expect(state.phase == .cancelled)
        #expect(state.transcript.isEmpty)
    }

    @Test func cancelledRecognitionIgnoresDelayedCallbacks() {
        var state = listeningState()
        let partialAccepted = state.receive("保存する途中結果", isFinal: false)
        #expect(partialAccepted)
        state.cancel()
        let delayedFinalAccepted = state.receive("古い確定結果", isFinal: true)
        #expect(!delayedFinalAccepted)
        let delayedPartialAccepted = state.receive("古い途中結果", isFinal: false)
        #expect(!delayedPartialAccepted)
        state.receiveFailure("認識キャンセルの遅延エラー")
        #expect(state.transcript == "保存する途中結果")
        #expect(state.failure == nil)
        #expect(state.phase == .cancelled)
        #expect(!state.acceptsAudio)
        #expect(!state.acceptsUpdates)
        #expect(!state.isFinal)
    }

    @Test func acceptedFinalCannotBeReplacedByLatePartialOrError() {
        var state = listeningState()
        let finalAccepted = state.receive("確定結果", isFinal: true)
        #expect(finalAccepted)
        state.receiveFailure("確定結果と同時に届くエラー")
        let delayedPartialAccepted = state.receive("遅れた途中結果", isFinal: false)
        #expect(!delayedPartialAccepted)
        let replacementFinalAccepted = state.receive("別の確定結果", isFinal: true)
        #expect(!replacementFinalAccepted)
        #expect(state.transcript == "確定結果")
        #expect(state.failure == nil)
        #expect(state.isFinal)
        #expect(!state.acceptsAudio)
        let endAccepted = state.endAudio()
        #expect(!endAccepted)
    }

    @Test func failedRecognitionKeepsRecoveryTextAndRejectsLateSuccess() {
        var state = listeningState()
        let partialAccepted = state.receive("取得済みの文字", isFinal: false)
        #expect(partialAccepted)
        state.receiveFailure("認識が停止しました")
        let delayedFinalAccepted = state.receive("遅延した確定結果", isFinal: true)
        #expect(!delayedFinalAccepted)
        #expect(state.transcript == "取得済みの文字")
        #expect(state.failure == "認識が停止しました")
        #expect(state.phase == .failed)
        #expect(!state.acceptsAudio)
        let endAccepted = state.endAudio()
        #expect(!endAccepted)
        #expect(!state.isFinal)
    }

    @Test func endAudioStopsInputButStillAcceptsItsFinal() {
        var state = LocalRecognitionState()
        let idleEndAccepted = state.endAudio()
        #expect(!idleEndAccepted)
        let authorizationBegan = state.beginAuthorization()
        #expect(authorizationBegan)
        let authorizingEndAccepted = state.endAudio()
        #expect(!authorizingEndAccepted)
        let recognitionBegan = state.beginRecognition()
        #expect(recognitionBegan)
        #expect(state.acceptsAudio)
        let firstEndAccepted = state.endAudio()
        #expect(firstEndAccepted)
        let repeatedEndAccepted = state.endAudio()
        #expect(!repeatedEndAccepted)
        #expect(state.phase == .finishing)
        #expect(!state.acceptsAudio)
        let finishingPartialAccepted = state.receive("確定待ち", isFinal: false)
        #expect(finishingPartialAccepted)
        let finalAccepted = state.receive("確定", isFinal: true)
        #expect(finalAccepted)
        #expect(state.isFinal)
        #expect(state.transcript == "確定")
    }

    @Test func cancellationDuringFinalizationRevokesSuccess() {
        for hadFinal in [false, true] {
            var state = listeningState()
            state.endAudio()
            state.receive("回復可能な文章", isFinal: hadFinal)
            state.cancel()
            let delayedResultAccepted = state.receive("遅延結果", isFinal: true)
            #expect(!delayedResultAccepted)
            #expect(!state.isFinal)
            let recognitionRestarted = state.beginRecognition()
            #expect(!recognitionRestarted)
            #expect(state.phase == .cancelled)
            #expect(state.transcript == "回復可能な文章")
        }
    }

    @Test func structuredPreviewPreservesFinalizedPrefix() {
        var state = listeningState()
        let finalizedSegmentAccepted = state.receiveSegment("確定", finalized: true)
        #expect(finalizedSegmentAccepted)
        #expect(state.preview.finalizedPrefix == "確定")
        state.receiveSegment("長い仮説", finalized: false)
        state.receiveSegment("短", finalized: false)
        #expect(state.preview.finalizedPrefix == "確定")
        #expect(state.preview.volatileTail == "短")
        state.receiveSegment("短", finalized: true)
        #expect(state.preview.finalizedPrefix == "確定短")
        #expect(state.preview.volatileTail.isEmpty)
        state.receiveSegment("末尾", finalized: false)
        state.endAudio()
        state.receiveSegment("末尾", finalized: false, completesRequest: true)
        #expect(state.preview.finalizedPrefix == "確定短末尾")
        #expect(state.preview.volatileTail.isEmpty)
        #expect(state.isFinal)
        let delayedSegmentAccepted = state.receiveSegment("遅延", finalized: true)
        #expect(!delayedSegmentAccepted)
    }

    @Test func unchangedTextStillTransitionsToFinal() {
        var state = listeningState()
        state.receiveSegment("同じ文字", finalized: false)
        let before = state.preview
        let finalizationAccepted = state.receiveSegment("同じ文字", finalized: true)
        #expect(finalizationAccepted)
        #expect(state.transcript == before.text)
        #expect(state.preview != before)
        #expect(state.preview.finalizedPrefix == before.text)
        // Legacy SFSpeech has no segment finality before request completion.
        var legacy = listeningState()
        legacy.receive("累積結果", isFinal: false)
        #expect(legacy.preview.finalizedPrefix.isEmpty)
        #expect(legacy.preview.volatileTail == "累積結果")
        legacy.receive("累積結果", isFinal: true)
        #expect(legacy.preview.finalizedPrefix == "累積結果")
        #expect(legacy.preview.volatileTail.isEmpty)
        var assembler = TranscriptAssembler()
        assembler.apply(.final("hello"))
        assembler.apply(.interim("world"))
        #expect(assembler.preview.finalizedPrefix == "hello")
        #expect(assembler.preview.volatileTail == " world")
        #expect(assembler.preview.text == assembler.displayText)
        let hypothesis = assembler.preview
        assembler.apply(.final("world"))
        #expect(assembler.preview.text == hypothesis.text)
        #expect(assembler.preview != hypothesis)
        #expect(assembler.preview.volatileTail.isEmpty)
    }

    private func listeningState() -> LocalRecognitionState {
        var state = LocalRecognitionState()
        state.beginAuthorization()
        state.beginRecognition()
        return state
    }
}
