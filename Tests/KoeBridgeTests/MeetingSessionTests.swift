#if os(macOS)
import Foundation
import AVFAudio
import Testing
import KoeBridgeCore
import KoeBridgeEngines
@testable import KoeBridge

@MainActor struct MeetingSessionTests {
    @Test func collisionDistinguishesConnectedDevicesWithoutOfferingAmbiguousSelections() {
        let first = MicrophoneDeviceOption(uid: "shared", name: "first", deviceID: 1)
        let second = MicrophoneDeviceOption(uid: "shared", name: "second", deviceID: 2)
        let unique = MicrophoneDeviceOption(uid: "unique", name: "third", deviceID: 3)
        let snapshot = MicrophoneDevices.Snapshot(devices: [first, second, unique], defaultID: 1)
        #expect(snapshot.devices == [unique])
        #expect(snapshot.collidingUIDs == ["shared"])
        #expect(!snapshot.collidingUIDs.contains("disconnected"))
        #expect(MicrophoneDevices.Snapshot(devices: [first], defaultID: 1).devices == [first])
    }

    @Test func tapCopySpareReusesOnlyCompletedMatchingBuffers() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        input.frameLength = 1024
        let spare = TapCopySpare()
        let identity: ObjectIdentifier
        do {
            let first = spare.borrow(for: input)
            let held = try #require(first.buffer)
            held.frameLength = 1024
            identity = ObjectIdentifier(held)
            #expect(first.owned)
            let overlapping = spare.borrow(for: input)
            #expect(!overlapping.owned && overlapping.buffer !== held)
            spare.recycle(held)
        }
        for _ in 0..<100 {
            let next = spare.borrow(for: input)
            let buffer = try #require(next.buffer)
            #expect(next.owned && ObjectIdentifier(buffer) == identity)
            spare.recycle(buffer)
        }
        input.frameLength = 64
        let resized = spare.borrow(for: input)
        #expect(resized.buffer?.frameCapacity == 64)
    }

    @Test func commandAndBothMeetingSourcesRecordSuccessfulUsage() async {
        let take = DictationTake(preferred: .local, style: .verbatim, japaneseHint: false, vocabulary: [],
                                 shouldPaste: true, options: .init())
        take.commandCandidate = .newline
        take.appleAttempted = true
        take.successfulEngine = .local
        let command = take.usageSamples(recognizedText: "改行", cancelled: false)
        #expect(command.engines.map(\.outcome) == [.success])

        let session = MeetingSession(engine: .local, vocabulary: [], style: .verbatim,
            japaneseHint: false, apiKey: nil, microphoneUID: "")
        var started = 0
        var events: [EngineUsageSample] = []
        session.onUsage = { event, tokens in events.append(event); #expect(tokens.isEmpty) }
        await withCheckedContinuation { done in
            session.onFinished = { _, _ in done.resume() }
            session.start { chunk, source in
                started += 1
                while started < 2 { await Task.yield() }
                chunk.localProcessedBytes = source == .microphone ? 32_000 : 64_000
                chunk.finalText = "fixture"
                session.stop()
            }
        }
        #expect(events.map(\.audioSeconds).sorted() == [1, 2])
        #expect(events.allSatisfy { $0.engine == .apple && $0.outcome == .success })
    }

    @Test func stopOutcomesSurviveHistoryReload() async throws {
        for (losses, recognitionFailed) in [(1, false), (0, true), (0, false)] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("history.json")
            var store = TranscriptHistoryStore(fileURL: file)
            let session = MeetingSession(engine: .local, vocabulary: [], style: .verbatim,
                japaneseHint: false, apiKey: nil, microphoneUID: "")
            await withCheckedContinuation { done in
                session.onFinished = { text, partial in
                    _ = session.save(text, partial: partial, to: &store)
                    done.resume()
                }
                session.start { chunk, source in
                    guard source == .microphone else { return }
                    chunk.worker = Task {
                        if recognitionFailed { throw VoiceController.AppError.connectionLost }
                        return losses > 0 ? "" : "会議録"
                    }
                    session.stop()
                    chunk.microphoneStopped(losses: losses)
                    chunk.finalText = try await chunk.worker?.value
                }
            }
            let record = try #require(TranscriptHistoryStore(fileURL: file).entries.first)
            let partial = losses > 0 || recognitionFailed
            #expect(record.isPartial == partial)
            #expect(record.kind == "meeting")
            #expect(record.delivery == (partial ? .recognitionInterrupted : .automaticPasteDisabled))
        }
    }

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

    @Test func amiVoiceMeetingRecordsSpeechSecondsEngineVariantAndDeadline() async throws {
        #expect(MeetingSession.chunkDurationSeconds(for: .local) == 50.0)
        #expect(MeetingSession.chunkDurationSeconds(for: .gemini) == 480.0)
        #expect(MeetingSession.chunkDurationSeconds(for: .amivoice) == 480.0)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var store = TranscriptHistoryStore(fileURL: folder.appendingPathComponent("history.json"))

        let session = MeetingSession(
            engine: .amivoice,
            vocabulary: ["KoeBridge"],
            style: .verbatim,
            japaneseHint: true,
            apiKey: nil,
            microphoneUID: "",
            amiVoiceKey: "fixture-amivoice-key",
            amiVoiceEngine: .hybridJapaneseInput
        )
        var started = 0
        var completedChunks = 0
        var events: [EngineUsageSample] = []
        var savedID: UUID?
        session.onUsage = { event, tokens in
            events.append(event)
            #expect(tokens.isEmpty)
        }
        await withCheckedContinuation { done in
            session.onFinished = { text, partial in
                savedID = session.save(text, partial: partial, to: &store)
                done.resume()
            }
            session.start { chunk, source in
                started += 1
                while started < 2 && !session.stopping && !Task.isCancelled { await Task.yield() }
                let isMic = source == .microphone
                let connection = AmiVoiceWebSocketConnection(
                    apiKey: "fixture-amivoice-key",
                    engine: .hybridJapaneseInput,
                    vocabulary: ["KoeBridge"],
                    finalBudget: nil
                ) { request in
                    ScriptedAmiVoiceSocket(request: request) { message, ws in
                        guard case .string(let text) = message else { return }
                        if text.hasPrefix("s ") {
                            ws.feed("s")
                        } else if text == "e" {
                            if isMic {
                                ws.feed("S 200")
                                ws.feed("E 2200")
                                ws.feed(#"A {"text":"マイク発話","code":""}"#)
                            } else {
                                ws.feed("S 100")
                                ws.feed("E 1600")
                                ws.feed(#"A {"text":"相手発話","code":""}"#)
                            }
                            ws.feed("e")
                        }
                    }
                }
                chunk.amiVoice = connection
                try await connection.sendAudio(Data(count: isMic ? 96_000 : 64_000))
                chunk.finalText = try await connection.endAudioAndAwaitFinal()
                completedChunks += 1
                while completedChunks < 2 && !session.stopping && !Task.isCancelled { await Task.yield() }
                session.stop()
            }
        }

        let sorted = events.sorted { $0.audioSeconds < $1.audioSeconds }
        #expect(sorted.count == 2)
        #expect(sorted.map(\.audioSeconds) == [2.0, 3.0])
        #expect(sorted.map(\.speechSeconds) == [1.5, 2.0])
        #expect(sorted.allSatisfy {
            $0.engine == .amivoice
                && $0.outcome == .success
                && $0.engineVariant == AmiVoiceEngine.hybridJapaneseInput.rawValue
        })
        let record = try #require(store.entries.first { $0.id == savedID })
        #expect(record.engine == RecognitionMode.amivoice.label)
        #expect(record.kind == "meeting")
    }

    @Test func amiVoiceMeetingSilenceOnlyAndInterruptedUsageSamplesAndPartialRecovery() async throws {
        // Silence-only cleanly acknowledged chunk records speechSeconds == 0.0 (no audioSeconds fallback).
        let silenceSession = MeetingSession(
            engine: .amivoice,
            vocabulary: [],
            style: .verbatim,
            japaneseHint: true,
            apiKey: nil,
            microphoneUID: "",
            amiVoiceKey: "fixture-amivoice-key",
            amiVoiceEngine: .e2eJapaneseGeneral
        )
        var silenceEvents: [EngineUsageSample] = []
        silenceSession.onUsage = { event, tokens in
            silenceEvents.append(event)
            #expect(tokens.isEmpty)
        }
        await withCheckedContinuation { done in
            silenceSession.onFinished = { _, _ in done.resume() }
            silenceSession.start { chunk, source in
                guard source == .microphone else {
                    while !silenceSession.stopping && !Task.isCancelled { await Task.yield() }
                    return
                }
                let connection = AmiVoiceWebSocketConnection(
                    apiKey: "fixture-amivoice-key",
                    engine: .e2eJapaneseGeneral,
                    finalBudget: nil
                ) { request in
                    ScriptedAmiVoiceSocket(request: request) { message, ws in
                        guard case .string(let text) = message else { return }
                        if text.hasPrefix("s ") {
                            ws.feed("s")
                        } else if text == "e" {
                            ws.feed(#"A {"text":"","code":"o"}"#)
                            ws.feed("e")
                        }
                    }
                }
                chunk.amiVoice = connection
                try await connection.sendAudio(Data(count: 32_000))
                chunk.finalText = try await connection.endAudioAndAwaitFinal()
            }
        }
        let silenceMic = try #require(silenceEvents.first { $0.audioSeconds == 1.0 })
        #expect(silenceMic.engine == .amivoice)
        #expect(silenceMic.speechSeconds == 0.0)
        #expect(silenceMic.engineVariant == AmiVoiceEngine.e2eJapaneseGeneral.rawValue)
        #expect(silenceMic.outcome == .failure)

        // Mid-speech interruption before E/e preserves partial text, cancels socket, and leaves speechSeconds nil.
        let interruptSession = MeetingSession(
            engine: .amivoice,
            vocabulary: [],
            style: .verbatim,
            japaneseHint: true,
            apiKey: nil,
            microphoneUID: "",
            amiVoiceKey: "fixture-amivoice-key",
            amiVoiceEngine: .e2eJapaneseGeneral
        )
        var interruptEvents: [EngineUsageSample] = []
        var capturedSocket: ScriptedAmiVoiceSocket?
        var finishedText = ""
        var finishedPartial = false
        interruptSession.onUsage = { event, tokens in
            interruptEvents.append(event)
            #expect(tokens.isEmpty)
        }
        await withCheckedContinuation { done in
            interruptSession.onFinished = { text, partial in
                finishedText = text
                finishedPartial = partial
                done.resume()
            }
            interruptSession.start { chunk, source in
                guard source == .microphone else {
                    while !interruptSession.stopping && !Task.isCancelled { await Task.yield() }
                    return
                }
                let connection = AmiVoiceWebSocketConnection(
                    apiKey: "fixture-amivoice-key",
                    engine: .e2eJapaneseGeneral,
                    finalBudget: nil
                ) { request in
                    let socket = ScriptedAmiVoiceSocket(request: request) { message, ws in
                        guard case .string(let text) = message else { return }
                        if text.hasPrefix("s ") {
                            ws.feed("s")
                        }
                    }
                    capturedSocket = socket
                    return socket
                }
                chunk.amiVoice = connection
                try await connection.sendAudio(Data(count: 32_000))
                let socket = try #require(capturedSocket)
                socket.feed("S 100")
                socket.feed(#"U {"text":"途中経過"}"#)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while connection.assembler.interim.isEmpty && ContinuousClock.now < deadline {
                    await Task.yield()
                }
                interruptSession.interrupt("システム中断")
            }
        }
        #expect(finishedPartial)
        #expect(finishedText.contains("途中経過"))
        #expect(finishedText.contains("システム中断"))
        #expect(capturedSocket?.closeCodes.isEmpty == false)
        let interruptedMic = try #require(interruptEvents.first { $0.audioSeconds == 1.0 })
        #expect(interruptedMic.engine == .amivoice)
        #expect(interruptedMic.speechSeconds == nil)
        #expect(interruptedMic.engineVariant == AmiVoiceEngine.e2eJapaneseGeneral.rawValue)
        #expect(interruptedMic.outcome == .cancelled)
    }
}

@MainActor struct MicrophoneIntegrityTests {
    @Test func resamplerTailReachesRecognitionStreamOnlyOnNormalStop() async throws {
        for rate in [44_100.0, 48_000.0] {
            let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let frames = AVAudioFrameCount(rate / 100)
            let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames))
            input.frameLength = frames
            for i in 0..<Int(frames) { input.floatChannelData![0][i] = 0.25 }
            // Independently measure ordinary conversion on this OS, without EOS.
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let reference = try #require(AVAudioConverter(from: inputFormat, to: format))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192))
            var ordinaryBytes = 0
            for _ in 0..<100 {
                var supplied = false
                var error: NSError?
                _ = reference.convert(to: buffer, error: &error) { _, state in
                    if supplied { state.pointee = .noDataNow; return nil }
                    supplied = true
                    state.pointee = .haveData
                    return input
                }
                if let error { throw error }
                ordinaryBytes += Int(buffer.frameLength) * 2
            }
            #expect(ordinaryBytes > 0 && ordinaryBytes < 32_000)
            for end in [CaptureEnd.normal, .interrupted, .cancelled] {
                // Use the same bounded chunk stream that feeds meeting recognition.
                let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(480))
                let capture = SystemAudioCapture(onAudio: { continuation.yield($0) },
                                                 onFailure: { Issue.record("capture failed") })
                for _ in 0..<100 { try capture.convert(input) }
                async let firstStop = capture.stop(end)
                async let secondStop = capture.stop(end)
                let results = await [firstStop, secondStop]
                #expect(results == [true, true])
                continuation.finish()
                var bytes = 0
                for await packet in stream { bytes += packet.count }
                if end == .normal {
                    #expect(bytes == 32_000)
                } else {
                    #expect(bytes == ordinaryBytes)
                }
            }
        }
    }

    @Test func admittedMismatchedTailAndGapSurviveStop() throws {
        let expected = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        for (mismatch, gap) in [(true, false), (false, true), (false, false)] {
            let gate = MicrophoneStartupGate()
            gate.observeConvertedBuffer(frames: 800, at: 0)
            gate.observeConvertedBuffer(frames: 800, at: 0.2)
            #expect(gate.commit(at: 0.2, deadline: 2.5, engineRunning: true))
            let capture = MicrophoneCapture(startupGate: gate)
            let token = try #require(gate.captureTokenForTap(tapGeneration: gate.currentTapGeneration))
            #expect(gate.noteTapArrival(token, at: gap ? 1.25 : 0.3) == gap)
            gate.stop()
            let format = mismatch ? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)! : expected
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
            buffer.frameLength = 16
            let accepted = capture.acceptsForConversion(buffer, token: token, expected: expected, onDeviceChanged: {})
            #expect(accepted == (!mismatch && !gap))
            #expect(capture.lostBufferCount == (mismatch || gap ? 1 : 0))
            #expect(gate.recordingWasInterrupted == gap)
        }
    }

    @Test func enumerationRetriesOnlyWithinStartupBudget() throws {
        let policy = MicrophoneStartupRetryPolicy()
        #expect(policy.maximumAttempts == 4 && policy.totalTimeout == 10 && policy.attemptTimeout == 2.5)
        for failures in [1, 4] {
            var elapsed = 0.0
            var attempts = 0
            var selected: MicrophoneSelectionTarget?
            var lastError: Error?
            while policy.remaining(at: elapsed) > 0 {
                attempts += 1
                do {
                    let ids = try MicrophoneDevices.enumerate(readSize: { size in
                        size = 4
                        return attempts <= failures && attempts.isMultiple(of: 2) ? -1 : 0
                    }, readData: { _, pointer in
                        guard attempts > failures else { return -1 }
                        pointer.storeBytes(of: UInt32(7), as: UInt32.self)
                        return 0
                    })
                    let enumerated = ids.map { MicrophoneDeviceOption(uid: "mic", name: "mic", deviceID: $0) }
                    selected = try MicrophoneSelectionPolicy.resolve(uid: "mic", devices: enumerated, systemDefaultID: 7)
                    break
                } catch {
                    lastError = error
                    elapsed += policy.timeoutForNextAttempt(elapsed: elapsed)
                    guard let delay = MicrophoneCapture.retryDelay(for: error, policy: policy,
                        attempts: attempts, elapsed: elapsed) else { break }
                    elapsed += delay
                }
            }
            #expect(attempts == (failures == 1 ? 2 : 4))
            #expect((selected?.uid == "mic") == (failures == 1))
            if failures == 4 {
                #expect(elapsed == 10)
                guard case .enumerationFailed? = lastError as? MicrophoneDevices.DeviceError else {
                    Issue.record("Persistent enumeration failure lost its cause")
                    return
                }
            }
        }
        let empty = try MicrophoneDevices.enumerate(readSize: { $0 = 0; return 0 }, readData: { _, _ in
            Issue.record("Empty HAL list attempted a data read")
            return -1
        })
        #expect(empty.isEmpty)
        #expect(MicrophoneCapture.retryDelay(for: MicrophoneSelectionError.noSystemInput,
            policy: policy, attempts: 1, elapsed: 0) == nil)
    }
}
#endif
