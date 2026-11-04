import Testing
@testable import KoeBridgeCore

struct SessionTransitionsTests {
    @Test func normalStartStopStartAgain() {
        let flow = VoiceSessionTransitions()
        #expect(flow.shortcut(phase: .idle) == .start)
        #expect(flow.shortcut(phase: .recording) == .stop)
        #expect(flow.shortcut(phase: .idle) == .start)
    }
    @Test func finalizationDoesNotLockRecordingKey() {
        let flow = VoiceSessionTransitions()
        #expect(flow.shortcut(phase: .finalizing) == .start)
        #expect(flow.shortcut(phase: .preparing) == .discard)
    }
}
