import KoeBridgeCore

struct LocalRecognitionStateTests {
    func cancelledPermissionCannotStartRecognition() {
        var state = LocalRecognitionState()
        check(state.beginAuthorization())
        state.cancel()
        check(!state.beginRecognition())
        check(!state.beginAuthorization())
        check(!state.receive("遅延した結果", isFinal: true))
        check(state.phase == .cancelled)
        check(state.transcript.isEmpty)
    }

    func cancelledRecognitionIgnoresDelayedCallbacks() {
        var state = listeningState()
        check(state.receive("保存する途中結果", isFinal: false))
        state.cancel()
        check(!state.receive("古い確定結果", isFinal: true))
        check(!state.receive("古い途中結果", isFinal: false))
        state.receiveFailure("認識キャンセルの遅延エラー")
        check(state.transcript == "保存する途中結果")
        check(state.failure == nil)
        check(state.phase == .cancelled)
        check(!state.acceptsAudio)
        check(!state.acceptsUpdates)
        check(!state.isFinal)
    }

    func acceptedFinalCannotBeReplacedByLatePartialOrError() {
        var state = listeningState()
        check(state.receive("確定結果", isFinal: true))
        state.receiveFailure("確定結果と同時に届くエラー")
        check(!state.receive("遅れた途中結果", isFinal: false))
        check(!state.receive("別の確定結果", isFinal: true))
        check(state.transcript == "確定結果")
        check(state.failure == nil)
        check(state.isFinal)
        check(!state.acceptsAudio)
        check(!state.endAudio())
    }

    func failedRecognitionKeepsRecoveryTextAndRejectsLateSuccess() {
        var state = listeningState()
        check(state.receive("取得済みの文字", isFinal: false))
        state.receiveFailure("認識が停止しました")
        check(!state.receive("遅延した確定結果", isFinal: true))
        check(state.transcript == "取得済みの文字")
        check(state.failure == "認識が停止しました")
        check(state.phase == .failed)
        check(!state.acceptsAudio)
        check(!state.endAudio())
        check(!state.isFinal)
    }

    func endAudioStopsInputButStillAcceptsItsFinal() {
        var state = LocalRecognitionState()
        check(!state.endAudio())
        check(state.beginAuthorization())
        check(!state.endAudio())
        check(state.beginRecognition())
        check(state.acceptsAudio)
        check(state.endAudio())
        check(!state.endAudio())
        check(state.phase == .finishing)
        check(!state.acceptsAudio)
        check(state.receive("確定待ち", isFinal: false))
        check(state.receive("確定", isFinal: true))
        check(state.isFinal)
        check(state.transcript == "確定")
    }

    func cancellationDuringFinalizationRevokesSuccess() {
        for hadFinal in [false, true] {
            var state = listeningState()
            state.endAudio()
            state.receive("回復可能な文章", isFinal: hadFinal)
            state.cancel()
            check(!state.receive("遅延結果", isFinal: true))
            check(!state.isFinal)
            check(!state.beginRecognition())
            check(state.phase == .cancelled)
            check(state.transcript == "回復可能な文章")
        }
    }

    func structuredPreviewPreservesFinalizedPrefix() {
        var state = listeningState()
        check(state.receiveSegment("確定", finalized: true))
        check(state.preview.finalizedPrefix == "確定")
        state.receiveSegment("長い仮説", finalized: false)
        state.receiveSegment("短", finalized: false)
        check(state.preview.finalizedPrefix == "確定")
        check(state.preview.volatileTail == "短")
        state.receiveSegment("短", finalized: true)
        check(state.preview.finalizedPrefix == "確定短")
        check(state.preview.volatileTail.isEmpty)
        state.receiveSegment("末尾", finalized: false)
        state.endAudio()
        state.receiveSegment("末尾", finalized: false, completesRequest: true)
        check(state.preview.finalizedPrefix == "確定短末尾")
        check(state.preview.volatileTail.isEmpty)
        check(state.isFinal)
        check(!state.receiveSegment("遅延", finalized: true))
    }

    func unchangedTextStillTransitionsToFinal() {
        var state = listeningState()
        state.receiveSegment("同じ文字", finalized: false)
        let before = state.preview
        check(state.receiveSegment("同じ文字", finalized: true))
        check(state.transcript == before.text)
        check(state.preview != before)
        check(state.preview.finalizedPrefix == before.text)
        // Legacy SFSpeech has no segment finality before request completion.
        var legacy = listeningState()
        legacy.receive("累積結果", isFinal: false)
        check(legacy.preview.finalizedPrefix.isEmpty)
        check(legacy.preview.volatileTail == "累積結果")
        legacy.receive("累積結果", isFinal: true)
        check(legacy.preview.finalizedPrefix == "累積結果")
        check(legacy.preview.volatileTail.isEmpty)
        var assembler = TranscriptAssembler()
        assembler.apply(.final("hello"))
        assembler.apply(.interim("world"))
        check(assembler.preview.finalizedPrefix == "hello")
        check(assembler.preview.volatileTail == " world")
        check(assembler.preview.text == assembler.displayText)
        let hypothesis = assembler.preview
        assembler.apply(.final("world"))
        check(assembler.preview.text == hypothesis.text)
        check(assembler.preview != hypothesis)
        check(assembler.preview.volatileTail.isEmpty)
    }

    private func listeningState() -> LocalRecognitionState {
        var state = LocalRecognitionState()
        state.beginAuthorization()
        state.beginRecognition()
        return state
    }
}
