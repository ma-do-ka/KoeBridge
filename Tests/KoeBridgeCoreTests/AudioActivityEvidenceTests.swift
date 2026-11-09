import Foundation
import Testing
@testable import KoeBridgeCore
#if os(macOS)
@preconcurrency import AVFoundation
#endif

struct AudioActivityEvidenceTests {
    @Test func preRollGeometryPreservesOnsetAndReportsActualRelease() {
        for (start, releasedFrom) in [(2.0, 1.0), (0.5, 0.0)] {
            var proof = SpeechVerification()
            proof.started()
            proof.observe(confidence: 0.95, start: start, duration: 0.5)
            var buffer = SpeechAdmissionBuffer()
            let audio = Data(repeating: 1, count: 96_000)
            #expect(buffer.openGeometry == nil)
            let released = buffer.append(audio, proof: proof)
            #expect(released == audio.subdata(in: Int(releasedFrom * 32_000)..<audio.count))
            #expect(buffer.openGeometry?.firstSpeechStart == start)
            #expect(buffer.openGeometry?.releasedFrom == releasedFrom)
            #expect(buffer.openGeometry?.bufferedDuration == 3.0)
            let geometry = buffer.openGeometry
            let pause = Data(repeating: 0, count: 3_200)
            #expect(buffer.append(pause, proof: SpeechVerification()) == pause)
            #expect(buffer.openGeometry == geometry)
        }
    }
    @Test func openGeometryReportsFallbackAndFinishConfirmation() {
        var proof = SpeechVerification()
        proof.started()
        proof.observe(confidence: 0.95, start: 10, duration: 0.5)
        var buffer = SpeechAdmissionBuffer()
        let audio = Data(repeating: 2, count: 3_200)
        #expect(buffer.append(audio, proof: SpeechVerification()) == nil)
        #expect(buffer.finish(proof: proof, isDigitalSilence: false) == audio)
        #expect(buffer.openGeometry?.releasedFrom == 0)
        #expect(buffer.openGeometry?.bufferedDuration == 0.1)
        #expect(buffer.finish(proof: proof, isDigitalSilence: false) == nil)
    }
    @Test func heldFeedbackExplainsHoldAndCopyAndPreservesOwnership() {
        #expect(OverlayFeedback.heldForReview.message.contains("保留"))
        #expect(OverlayFeedback.heldForReview.message.contains("コピー"))
        let id = UUID()
        #expect(OverlayFeedback.mayUpdate(owner: id, resolved: id, newRecordingActive: false))
        #expect(!OverlayFeedback.mayUpdate(owner: id, resolved: id, newRecordingActive: true))
        #expect(!OverlayFeedback.mayUpdate(owner: UUID(), resolved: id, newRecordingActive: false))
        #expect(!OverlayFeedback.mayUpdate(owner: nil, resolved: id, newRecordingActive: false))
    }
    private func sample(_ samples: [Float], splitAt: Int? = nil) -> AudioActivityEvidence {
        var meter = AudioActivityMeter()
        if let splitAt {
            Array(samples.prefix(splitAt)).withUnsafeBufferPointer { meter.observe($0) }
            Array(samples.dropFirst(splitAt)).withUnsafeBufferPointer { meter.observe($0) }
        } else { samples.withUnsafeBufferPointer { meter.observe($0) } }
        return meter.evidence
    }
    private func modulatedTone(_ amplitude: Float) -> [Float] {
        (0..<16_000).map { index in
            guard (3_200..<10_000).contains(index) else { return 0 }
            return Float(sin(Double(index) / 9.5)) * amplitude * (0.4 + Float(index % 1_200) / 1_200)
        }
    }
    private func proof(_ score: Double = 0.95, start: Double = 0) -> SpeechVerification {
        var proof = SpeechVerification()
        proof.started(); proof.observe(confidence: score, start: start, duration: 0.5)
        return proof
    }
    @Test func silenceDoesNotAuthorizeModelText() {
        let silence = sample(Array(repeating: 0, count: 48_000))
        #expect(silence.classification == .nearSilence)
        #expect(AudioActivityPolicy.shouldDiscardQuietTake(silence, pcmBytes: 96_000, hasTranscript: false))
        #expect(!AudioActivityPolicy.shouldDiscardQuietTake(silence, pcmBytes: 96_000, hasTranscript: true))
        #expect(!AudioActivityPolicy.mayShowInterim(silence))
    }
    @Test func fluctuatingNoiseThatPassedBuild29CannotAuthorizeSpeech() {
        let noise = sample(modulatedTone(0.03))
        #expect(noise.activeFrames >= 4 && noise.longestActiveRun >= 3)
        #expect(noise.maximumFrameRMS >= 0.0025 && noise.modulation >= 0.12)
        #expect(noise.classification == .uncertain)
        #expect(AudioActivityPolicy.requiresReview(noise))
        #expect(!AudioActivityPolicy.mayShowInterim(noise))
    }
    @Test func steadyHumAndSingleClickRemainUnconfirmed() {
        #expect(sample(Array(repeating: 0.005, count: 16_000)).classification == .uncertain)
        var samples = Array(repeating: Float.zero, count: 16_000)
        samples[100] = 0.8
        #expect(sample(samples).classification == .uncertain)
    }
    @Test func verifiedSpeechDoesNotNeedTheOldLoudnessThreshold() {
        for amplitude in [Float(0.0006), 0.007, 0.018] {
            let energy = sample(modulatedTone(amplitude))
            #expect(AudioActivityPolicy.requiresReview(energy))
            let independentlyVerified = energy.withSpeechVerification(proof())
            #expect(!AudioActivityPolicy.requiresReview(independentlyVerified))
            #expect(AudioActivityPolicy.mayShowInterim(independentlyVerified))
        }
    }
    @Test func faintSpeechAndIncompleteTailAreNeverDiscardedAsSilence() {
        let low = sample(modulatedTone(0.0006))
        #expect(!AudioActivityPolicy.shouldDiscardQuietTake(low, pcmBytes: 32_000, hasTranscript: false))
        var tail = Array(repeating: Float.zero, count: 3_200)
        tail.append(0.01)
        let observed = sample(tail)
        #expect(observed.peak > 0 && observed.maximumFrameRMS > 0)
        #expect(!AudioActivityPolicy.shouldDiscardQuietTake(observed, pcmBytes: 6_402, hasTranscript: false))
    }
    @Test func chunkBoundariesDoNotChangeEvidence() {
        let samples = modulatedTone(0.008)
        #expect(sample(samples, splitAt: 49) == sample(samples))
        #expect(sample(samples, splitAt: 3_999) == sample(samples))
    }
    @Test func invalidSamplesNeverAuthorizeTypingEvenWithClassifierProof() {
        var samples = modulatedTone(0.02)
        samples[500] = .nan
        #expect(sample(samples).withSpeechVerification(proof()).classification == .uncertain)
        #expect(sample(Array(repeating: 0.008, count: 200)).classification == .unavailable)
    }
    @Test func pendingFailedAndTimedOutClassifiersNeverOpenTheGate() {
        let energy = sample(modulatedTone(0.02))
        #expect(AudioActivityPolicy.requiresReview(energy.withSpeechVerification(SpeechVerification())))
        var failed = proof(); failed.fail()
        var timedOut = proof(); timedOut.timeOut()
        for evidence in [failed, timedOut] {
            #expect(!evidence.allowsTranscript)
            #expect(AudioActivityPolicy.requiresReview(energy.withSpeechVerification(evidence)))
        }
    }
    @Test func duplicateWindowsAndLateCallbacksCannotManufactureSpeech() {
        var state = proof(0.7)
        #expect(!state.allowsTranscript)
        state.observe(confidence: 0.7, start: 0, duration: 0.5)
        #expect(!state.allowsTranscript)
        state.observe(confidence: 0.7, start: 0.25, duration: 0.5)
        #expect(state.allowsTranscript)
        state.timeOut()
        state.observe(confidence: 1, start: 1, duration: 0.5)
        state.complete()
        #expect(!state.allowsTranscript)
        var malformed = proof(0.7)
        malformed.observe(confidence: .nan, start: 0.5, duration: 0.5)
        #expect(malformed.state == .failed)
    }
    @Test func preSpeechAudioWaitsAndFirstSyllableAndPausesArePreserved() {
        var admission = SpeechAdmissionBuffer()
        let initial = Data(repeating: 1, count: 48_000)
        #expect(admission.append(initial, proof: SpeechVerification()) == nil)
        let admitted = admission.append(Data(repeating: 2, count: 1_600), proof: proof(start: 1))
        #expect(admitted == initial + Data(repeating: 2, count: 1_600))
        let pause = Data(repeating: 0, count: 32_000)
        #expect(admission.append(pause, proof: SpeechVerification()) == pause)
        #expect(admission.finish(proof: proof(), isDigitalSilence: false) == nil)
    }
    @Test func uncertainAudioIsRecoverableOnceButDigitalSilenceIsNotSent() {
        let audio = Data(repeating: 4, count: 3_200)
        var review = SpeechAdmissionBuffer()
        #expect(review.append(audio, proof: SpeechVerification()) == nil)
        #expect(review.finish(proof: SpeechVerification(), isDigitalSilence: false) == audio)
        #expect(review.finish(proof: proof(), isDigitalSilence: false) == nil)
        var silent = SpeechAdmissionBuffer()
        _ = silent.append(Data(repeating: 0, count: 32_000), proof: SpeechVerification())
        #expect(silent.finish(proof: SpeechVerification(), isDigitalSilence: true) == nil)
    }
    @Test func leadingAudioStorageIsBounded() {
        var buffer = SpeechAdmissionBuffer()
        let tooMuch = Data(repeating: 0, count: SpeechAdmissionBuffer.maximumBytes + 1)
        #expect(buffer.append(tooMuch, proof: proof()) == nil)
        #expect(buffer.overflowed && !buffer.opened)
        #expect(buffer.finish(proof: proof(), isDigitalSilence: false) == nil)
    }
}

#if os(macOS)
@Suite(.serialized)
struct NativeSpeechClassifierIntegrationTests {
    private func classify(_ samples: [Float]) async throws -> SpeechVerification {
        let detector = NativeSpeechDetector()
        defer { detector.cancel() }
        let deadline = Date().addingTimeInterval(15)
        while detector.evidence.state == .pending && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(detector.evidence.state == .running)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                channels: 1, interleaved: false))
        var offset = 0
        while offset < samples.count {
            let count = min(1_600, samples.count - offset)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let destination = try #require(buffer.floatChannelData?[0])
            for index in 0..<count { destination[index] = samples[offset + index] }
            detector.append(buffer)
            offset += count
            try await Task.sleep(for: .milliseconds(40))
        }
        return await withCheckedContinuation { continuation in
            detector.finish { continuation.resume(returning: $0) }
        }
    }
    private func synthesizedGitHub() async throws -> [Float] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("voice.aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", "145", "-o", file.path, "GitHub. Please check the documentation."]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let limit = Date().addingTimeInterval(15)
        while process.isRunning && Date() < limit { try await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { process.terminate() }
        try #require(!process.isRunning && process.terminationStatus == 0)
        let audio = try AVAudioFile(forReading: file)
        try #require(audio.length > 0 && audio.length < 2_000_000)
        let source = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: source)
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: source.format, to: output))
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * 16_000 / source.format.sampleRate)) + 4_096
        let target = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity))
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: target, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return source
        }
        try #require(error == nil && target.frameLength > 0)
        let floats = try #require(target.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: floats, count: Int(target.frameLength)))
    }
    @Test func realClassifierRejectsNonSpeechAndAcceptsASpokenGitHub() async throws {
        let silence = try await classify(Array(repeating: 0, count: 32_000))
        #expect(silence.state == .completed && silence.windows > 0)
        #expect(!silence.allowsTranscript)
        let tone: [Float] = (0..<48_000).map { i in
            let envelope = i < 8_000 ? 0.0 : (0.015 + 0.012 * sin(Double(i) / 2_000))
            return Float(sin(Double(i) * 2 * .pi * 220 / 16_000) * envelope)
        }
        let noise = try await classify(tone)
        #expect(noise.state == .completed && !noise.allowsTranscript)
        let voiceSamples = try await synthesizedGitHub()
        let voice = try await classify(voiceSamples)
        #expect(voice.state == .completed && voice.allowsTranscript)
        let quiet = try await classify(voiceSamples.map { $0 * 0.1 })
        #expect(quiet.state == .completed && quiet.allowsTranscript)
        print("Native classifier fixtures: silence=\(silence.maximumConfidence) tone=\(noise.maximumConfidence) speech=\(voice.maximumConfidence) quiet=\(quiet.maximumConfidence)")
    }
}
#endif
