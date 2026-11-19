#if os(macOS)
import Foundation
import AVFAudio
import Testing
import KoeBridgeCore
@testable import KoeBridge

@MainActor struct MeetingSessionTests {
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
}

@MainActor struct MicrophoneIntegrityTests {
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
