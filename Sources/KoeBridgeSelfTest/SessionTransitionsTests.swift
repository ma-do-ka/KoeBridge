import KoeBridgeCore

struct SessionTransitionsTests {
    func normalStartStopStartAgain() {
        let flow = VoiceSessionTransitions()
        check(flow.shortcut(phase: .idle) == .start)
        check(flow.shortcut(phase: .recording) == .stop)
        check(flow.shortcut(phase: .idle) == .start)
    }
    func finalizationCannotReserveOrBlockANewRecording() {
        let flow = VoiceSessionTransitions()
        check(flow.shortcut(phase: .finalizing) == .start)
        check(flow.shortcut(phase: .idle) == .start)
    }
    func repeatedProcessingPressNeverEnqueuesGhostRestart() {
        let flow = VoiceSessionTransitions()
        for _ in 0..<7 { check(flow.shortcut(phase: .finalizing) == .start) }
    }
    func preparingPressCancelsWithoutDelayedAutoRestart() {
        let flow = VoiceSessionTransitions()
        check(flow.shortcut(phase: .preparing) == .discard)
    }
    func stopAfterACompletedTurnCanStartImmediately() {
        let flow = VoiceSessionTransitions()
        check(flow.shortcut(phase: .recording) == .stop)
        check(flow.shortcut(phase: .idle) == .start)
    }
}
