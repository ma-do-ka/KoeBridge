#if os(macOS)
import Foundation
import Testing
import KoeBridgeCore
@testable import KoeBridge

private final class ScriptedLiveSocket: GeminiSocket, @unchecked Sendable {
    let state = URLSessionTask.State.running
    let frames = AsyncStream<URLSessionWebSocketTask.Message>.makeStream()
    func resume() {}
    func receive() async throws -> URLSessionWebSocketTask.Message {
        var iterator = frames.stream.makeAsyncIterator()
        guard let next = await iterator.next() else { throw CancellationError() }
        return next
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {}
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) { pongReceiveHandler(nil) }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { frames.continuation.finish() }
    func feed(_ json: String) { frames.continuation.yield(.string(json)) }
}

@MainActor struct GeminiLiveConnectionTests {
    @Test func largeAudioMessageMatchesExistingWireBytes() async throws {
        let pcm = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0) })
        let expected = try GeminiWire.audio(pcm)
        let built = try await GeminiLiveConnection.audioMessage(pcm)
        #expect(built.utf8.elementsEqual(expected.utf8))
    }
    private func makeTake() -> DictationTake {
        DictationTake(preferred: .gemini, style: .verbatim, japaneseHint: false,
                      vocabulary: [], shouldPaste: true, options: .init())
    }

    @Test func effectiveEngineTimerUsesOriginalRecordingStart() async {
        let take = makeTake()
        let start = ContinuousClock.now.advanced(by: .seconds(-17))
        take.recordingStart = start
        #expect(take.recordingDeadline == start.advanced(by: .seconds(480)))
        take.effectiveMode = .local
        #expect(take.recordingDeadline == start.advanced(by: .seconds(17 + 33)))
        take.transformSelection = "selection"
        #expect(take.recordingDeadline == start.advanced(by: .seconds(30)))

        take.transformSelection = nil
        take.recordingStart = .now.advanced(by: .seconds(-51))
        take.effectiveMode = .gemini
        var expirations: [RecognitionMode] = []
        take.scheduleRecordingTimeout { expirations.append(.gemini) }
        let original = take.recordingTimeout
        take.effectiveMode = .local
        take.scheduleRecordingTimeout { expirations.append(.local) }
        #expect(original?.isCancelled == true)
        await take.recordingTimeout?.value
        #expect(expirations == [.local])
    }

    @Test func failedFinalSendUsesOnlyCompleteSameTakeAudio() async throws {
        for (drained, dropped, rescueExpected) in [(true, false, true), (false, false, false), (true, true, false)] {
            let take = makeTake()
            take.captureDrainedCleanly = drained
            take.stoppingAt = Date()
            if dropped { take.audioIntegrity.markDropped() }
            let stream = AsyncStream<Data> { output in
                output.yield(Data([1, 2]))
                output.yield(Data([3, 4]))
                output.finish()
            }
            var rescues = 0
            do {
                let result = try await take.transcribeLive(stream, send: { data in
                    if data == Data([3, 4]) { throw VoiceController.AppError.connectionLost }
                }, finish: {
                    Issue.record("Finalization after failed send")
                    return ""
                }, rescue: {
                    rescues += 1
                    #expect(take.audioBackup == Data([1, 2, 3, 4]))
                    return "回復"
                })
                #expect(result == "回復" && rescueExpected)
            } catch {
                #expect(!rescueExpected)
            }
            #expect(rescues == (rescueExpected ? 1 : 0))
        }
    }

    @Test func sendFailureDrainsQueuedTailIntoAppleRescueOnce() async throws {
        let take = makeTake()
        let (stream, output) = AsyncStream<Data>.makeStream()
        output.yield(Data([1, 2]))
        var sends = 0
        var rescues = 0
        let result = try await take.transcribeLive(stream, send: { _ in
            sends += 1
            // Stop races with the last network write. Capture still has a tail to drain.
            take.stoppingAt = Date()
            output.yield(Data([3, 4]))
            take.captureDrainedCleanly = true
            output.finish()
            throw VoiceController.AppError.connectionLost
        }, finish: {
            Issue.record("Cloud finalization after send failure")
            return ""
        }, rescue: {
            rescues += 1
            #expect(take.audioBackup == Data([1, 2, 3, 4]))
            return "全体"
        })
        #expect(sends == 1 && rescues == 1 && result == "全体")
    }

    @Test func goAwayPreventsAdoptionAndRequiresFreshSetup() async throws {
        let snapshot = GeminiPrewarmSnapshot(vocabulary: [], style: .verbatim, japaneseHint: false, apiKeyFingerprint: "fixture")
        for scenario in ["healthy", "setup", "receive"] {
            var connections = 0
            let socket = ScriptedLiveSocket()
            socket.feed(scenario == "setup" ? #"{"setupComplete":{},"goAway":{}}"# : #"{"setupComplete":{}}"#)
            let warm = GeminiLiveConnection { _ in connections += 1; return socket }
            var allocatedWarm = false
            let prewarmer = GeminiLivePrewarmer {
                if !allocatedWarm { allocatedWarm = true; return warm }
                let fresh = ScriptedLiveSocket()
                fresh.feed(#"{"setupComplete":{}}"#)
                return GeminiLiveConnection { _ in connections += 1; return fresh }
            }
            await prewarmer.warmIfNeeded { (snapshot, "fixture") }?.value
            if scenario == "receive" {
                socket.feed(#"{"usageMetadata":{"totalTokenCount":1},"goAway":{}}"#)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while warm.isUsableForPrewarm && ContinuousClock.now < deadline { await Task.yield() }
            }
            let selected = try await prewarmer.connectForTake(current: snapshot, enabled: true,
                                                               apiKey: "fixture") { _ in }
            #expect((selected === warm) == (scenario == "healthy"))
            selected.cancel()
            #expect(connections == (scenario == "healthy" ? 1 : 2))
        }
    }

    @Test func overBudgetFinalsCloseSocketAndCannotDeliverOrRescuePrefix() async throws {
        for budget in [TranscriptAssembler.FinalBudget(bytes: 12, identities: 100),
                       TranscriptAssembler.FinalBudget(bytes: 1000, identities: 1)] {
            let socket = ScriptedLiveSocket()
            socket.feed(#"{"setupComplete":{}}"#)
            let cloud = GeminiLiveConnection(finalBudget: budget) { _ in socket }
            try await cloud.connect(apiKey: "fixture", vocabulary: [], style: .verbatim, japaneseHint: false)
            try await cloud.sendAudio(Data([1, 2]))
            var interruptions = 0
            cloud.onEvent = { if case .error = $0 { interruptions += 1 } }
            for index in 0..<4 {
                socket.feed("""
                    {"serverContent":{"inputTranscription":{"text":"ab","startOffset":"\(index)","endOffset":"9"}}}
                    """)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !cloud.assembler.exceededFinalBudget && ContinuousClock.now < deadline { await Task.yield() }
            #expect(interruptions == 1)
            #expect(cloud.assembler.finalCount == 1)
            #expect(cloud.assembler.committedText.isEmpty)
            let take = makeTake()
            take.cloud = cloud
            take.captureDrainedCleanly = true
            take.stoppingAt = Date()
            let empty = AsyncStream<Data> { $0.finish() }
            var delivered: [String] = []
            do {
                delivered.append(try await take.transcribeLive(empty, send: cloud.sendAudio, finish: {
                    try await cloud.awaitFinal()
                }, rescue: {
                    Issue.record("Budget interruption entered rescue")
                    return "unexpected"
                }))
            } catch GeminiLiveConnection.ConnectionError.finalBudgetExceeded {}
            #expect(delivered.isEmpty)
            #expect(take.recoverableText == "ab")
        }
    }

    @Test func providerMessageIsDiscardedBeforeLoggingAndPresentation() throws {
        let marker = "B79-private-request-491bc7"
        let frame = try GeminiWire.decode("""
            {"error":{"message":"\(marker)","status":"\(marker)","code":429}}
            """)
        guard case .providerError(let failure) = frame.events.first else {
            Issue.record("Missing classified provider failure")
            return
        }
        #expect(failure.kind == .rateLimited)
        let diagnostic = GeminiLiveConnection.diagnosticFailure(failure)
        #expect(DiagnosticLogPolicy.sanitizedEvent(diagnostic) == "kind=rateLimited code=429")
        let presentation = GeminiLiveConnection.connectionFailureReason(for: failure)
        #expect(presentation.contains("利用上限"))
        for representation in [String(reflecting: frame), frame.diagnosticKind, diagnostic,
                               presentation, GeminiLiveConnection.ConnectionError.setup(presentation).localizedDescription] {
            #expect(!representation.contains(marker))
        }
    }

    @Test func setupReplyIsMappedOnceBeforeAddingTheAPIPrefix() {
        let raw = "Gemini API: The setup request was rejected."
        let error = GeminiLiveConnection.ConnectionError.setup(raw)
        let reason = GeminiLiveConnection.connectionFailureReason(for: error)
        let presented = GeminiLiveConnection.ConnectionError.setup(reason).errorDescription ?? ""
        #expect(reason == UserFacingErrorMessage.message(for: error, operation: "Geminiへの接続"))
        #expect(presented == "Gemini API: \(reason)")
        #expect(presented.components(separatedBy: "Gemini API: ").count == 2)
        #expect(!presented.contains("Gemini API: Gemini API:"))
        #expect(!presented.contains(raw))
    }

    @Test func connectionFailuresPreserveCuratedDetailAndMapTransportErrors() {
        let disconnected = GeminiLiveConnection.ConnectionError.disconnected
        #expect(GeminiLiveConnection.connectionFailureReason(for: disconnected) == disconnected.errorDescription)
        let transport = NSError(domain: NSURLErrorDomain, code: -1009,
                                userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        let reason = GeminiLiveConnection.connectionFailureReason(for: transport)
        #expect(reason == UserFacingErrorMessage.message(for: transport, operation: "Geminiへの接続"))
        #expect(!reason.contains(transport.localizedDescription))
    }
}
#endif
