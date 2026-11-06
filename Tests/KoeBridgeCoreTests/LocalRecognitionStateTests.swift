import Testing
@testable import KoeBridgeCore

struct LocalRecognitionStateTests {
    @Test func cancelledPermissionCannotStartRecognition() {
        var state = LocalRecognitionState()
        #expect(state.beginAuthorization())
        state.cancel()
        #expect(!state.beginRecognition())
        #expect(!state.beginAuthorization())
        #expect(!state.receive("遅延した結果", isFinal: true))
        #expect(state.phase == .cancelled)
        #expect(state.transcript.isEmpty)
    }

    @Test func cancelledRecognitionIgnoresDelayedCallbacks() {
        var state = listeningState()
        #expect(state.receive("保存する途中結果", isFinal: false))
        state.cancel()
        #expect(!state.receive("古い確定結果", isFinal: true))
        #expect(!state.receive("古い途中結果", isFinal: false))
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
        #expect(state.receive("確定結果", isFinal: true))
        state.receiveFailure("確定結果と同時に届くエラー")
        #expect(!state.receive("遅れた途中結果", isFinal: false))
        #expect(!state.receive("別の確定結果", isFinal: true))
        #expect(state.transcript == "確定結果")
        #expect(state.failure == nil)
        #expect(state.isFinal)
        #expect(!state.acceptsAudio)
        #expect(!state.endAudio())
    }

    @Test func failedRecognitionKeepsRecoveryTextAndRejectsLateSuccess() {
        var state = listeningState()
        #expect(state.receive("取得済みの文字", isFinal: false))
        state.receiveFailure("認識が停止しました")
        #expect(!state.receive("遅延した確定結果", isFinal: true))
        #expect(state.transcript == "取得済みの文字")
        #expect(state.failure == "認識が停止しました")
        #expect(state.phase == .failed)
        #expect(!state.acceptsAudio)
        #expect(!state.endAudio())
        #expect(!state.isFinal)
    }

    @Test func endAudioStopsInputButStillAcceptsItsFinal() {
        var state = LocalRecognitionState()
        #expect(!state.endAudio())
        #expect(state.beginAuthorization())
        #expect(!state.endAudio())
        #expect(state.beginRecognition())
        #expect(state.acceptsAudio)
        #expect(state.endAudio())
        #expect(!state.endAudio())
        #expect(state.phase == .finishing)
        #expect(!state.acceptsAudio)
        #expect(state.receive("確定待ち", isFinal: false))
        #expect(state.receive("確定", isFinal: true))
        #expect(state.isFinal)
        #expect(state.transcript == "確定")
    }

    @Test func cancellationDuringFinalizationRevokesSuccess() {
        for hadFinal in [false, true] {
            var state = listeningState()
            state.endAudio()
            state.receive("回復可能な文章", isFinal: hadFinal)
            state.cancel()
            #expect(!state.receive("遅延結果", isFinal: true))
            #expect(!state.isFinal)
            #expect(!state.beginRecognition())
            #expect(state.phase == .cancelled)
            #expect(state.transcript == "回復可能な文章")
        }
    }

    private func listeningState() -> LocalRecognitionState {
        var state = LocalRecognitionState()
        state.beginAuthorization()
        state.beginRecognition()
        return state
    }
}
