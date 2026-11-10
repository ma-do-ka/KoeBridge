#if os(macOS)
import Testing
import KoeBridgeCore
@testable import KoeBridge

@MainActor struct MeetingSessionTests {
    @Test func stoppedBeforePermissionReturnsCompletesWithoutStarting() {
        let session = MeetingSession(engine: .local, vocabulary: [], style: .verbatim,
            japaneseHint: false, apiKey: nil, microphoneUID: "")
        var completions: [(String, Bool)] = []
        session.onFinished = { text, partial in completions.append((text, partial)) }

        session.stop()
        session.start()
        session.start()
        #expect(session.stopping)
        #expect(completions.count == 1)
        #expect(completions.first?.0 == "")
        #expect(completions.first?.1 == false)
    }

    @Test func microphoneDenialStopsAndCompletesOnceAsPartial() {
        let session = MeetingSession(engine: .local, vocabulary: [], style: .verbatim,
            japaneseHint: false, apiKey: nil, microphoneUID: "")
        var completions: [(String, Bool)] = []
        session.onFinished = { text, partial in completions.append((text, partial)) }

        session.microphonePermissionDenied()
        #expect(session.stopping)
        #expect(completions.count == 1)
        #expect(completions.first?.0 == "マイクが停止したため会議モードを終了しました")
        #expect(completions.first?.1 == true)

        session.start()
        session.microphonePermissionDenied()
        #expect(completions.count == 1)
    }
}
#endif
