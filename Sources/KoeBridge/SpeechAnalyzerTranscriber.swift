#if os(macOS)
import Foundation
import AVFoundation
import Speech
import KoeBridgeCore

@available(macOS 26, *)
@MainActor final class SpeechAnalyzerTranscriber: LocalTranscribing {
    private typealias LocalError = AppleLocalTranscriber.LocalError
    let requiresSpeechAuthorization = false
    private var state = LocalRecognitionState()
    var transcript: String { state.transcript }
    var onUpdate: ((RecognitionPreview) -> Void)?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16_000, channels: 1, interleaved: true)!

    func start() async throws {
        guard state.beginAuthorization() else {
            if state.phase == .cancelled { throw CancellationError() }
            throw LocalError.unavailable
        }
        do {
            try checkStartupCancellation()
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
                throw LocalError.unavailable
            }
            try checkStartupCancellation()
            // SpeechTranscriber uses progressiveTranscription; progressiveLongDictation
            // belongs to DictationTranscriber, a different module.
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            do {
                if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try checkStartupCancellation()
                    DiagnosticLog.record("speechAnalyzer asset install")
                    try await installation.downloadAndInstall()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                DiagnosticLog.record("speechAnalyzer failed: \(error.localizedDescription)")
                throw LocalError.recognitionFailure(UserFacingErrorMessage.message(for: error, operation: "ローカル音声認識"))
            }
            try checkStartupCancellation()
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
                  let converter = AVAudioConverter(from: audioFormat, to: format) else {
                throw LocalError.unavailable
            }
            try checkStartupCancellation()
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.converter = converter
            self.continuation = continuation
            self.analyzer = analyzer
            guard state.beginRecognition() else { throw CancellationError() }
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, self.state.acceptsUpdates, !Task.isCancelled else { return }
                        let text = String(result.text.characters)
                        self.receiveSegment(text, finalized: result.isFinal)
                    }
                    guard let self, !Task.isCancelled else { return }
                    if self.state.phase == .finishing {
                        self.receiveSegment("", finalized: true, completesRequest: true)
                    } else if self.state.acceptsAudio {
                        self.state.receiveFailure(LocalError.endedBeforeAudio.localizedDescription)
                    }
                } catch {
                    DiagnosticLog.record("speechAnalyzer results failed: \(error.localizedDescription)")
                    self?.state.receiveFailure(UserFacingErrorMessage.message(for: error, operation: "ローカル音声認識"))
                }
            }
            try await analyzer.start(inputSequence: stream)
            try checkStartupCancellation()
        } catch {
            cancel()
            throw error
        }
    }

    private func checkStartupCancellation() throws {
        try Task.checkCancellation()
        guard state.phase != .cancelled else { throw CancellationError() }
    }

    private func receiveSegment(_ text: String, finalized: Bool, completesRequest: Bool = false) {
        // Notify on every accepted provider update, including stability-only changes.
        if state.receiveSegment(text, finalized: finalized, completesRequest: completesRequest) {
            onUpdate?(state.preview)
        }
    }

    func appendPCM16(_ data: Data) throws {
        if state.phase == .cancelled { throw CancellationError() }
        if let failure = state.failure { throw LocalError.recognitionFailure(failure) }
        guard let continuation, let converter else { throw LocalError.unavailable }
        guard !data.isEmpty else { return }
        guard state.acceptsAudio else { throw LocalError.endedBeforeAudio }
        guard data.count.isMultiple(of: 2), data.count / 2 <= Int(AVAudioFrameCount.max) else {
            throw LocalError.recognitionFailure("音声データの形式が不正です")
        }
        let frames = AVAudioFrameCount(data.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frames),
              let pointer = buffer.int16ChannelData?.pointee else {
            throw LocalError.recognitionFailure("音声データを認識用に準備できませんでした")
        }
        buffer.frameLength = frames
        data.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            memcpy(pointer, base, Int(frames) * MemoryLayout<Int16>.size)
        }
        try convertAndYield(buffer, converter: converter, continuation: continuation)
    }

    // Drain every converter output, including any resampling tail at end of input.
    private func convertAndYield(_ input: AVAudioPCMBuffer?, converter: AVAudioConverter,
                                 continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        let capacity = ceil(Double(input?.frameLength ?? 1024) * converter.outputFormat.sampleRate / audioFormat.sampleRate) + 256
        guard capacity <= Double(AVAudioFrameCount.max) else {
            throw LocalError.recognitionFailure("音声データの形式が不正です")
        }
        var supplied = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                                frameCapacity: AVAudioFrameCount(capacity)) else {
                throw LocalError.recognitionFailure("音声データを認識用に準備できませんでした")
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let input, !supplied {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            if let error {
                DiagnosticLog.record("speechAnalyzer audio conversion failed: \(error.localizedDescription)")
                throw LocalError.recognitionFailure(UserFacingErrorMessage.message(for: error, operation: "音声データの変換"))
            }
            if status == .error { throw LocalError.recognitionFailure("音声データを変換できませんでした") }
            if output.frameLength > 0 {
                if case .terminated = continuation.yield(AnalyzerInput(buffer: output)) {
                    throw LocalError.endedBeforeAudio
                }
            }
            if status != .haveData { return }
        }
    }

    func endAudioAndAwaitFinal() async throws -> String {
        if state.phase == .cancelled { throw CancellationError() }
        guard let analyzer, let continuation, let converter else { throw LocalError.unavailable }
        if state.endAudio() {
            do {
                try convertAndYield(nil, converter: converter, continuation: continuation)
            } catch {
                DiagnosticLog.record("speechAnalyzer audio drain failed: \(error.localizedDescription)")
                state.receiveFailure((error as? LocalError)?.errorDescription
                    ?? UserFacingErrorMessage.message(for: error, operation: "音声データの変換"))
                continuation.finish()
                throw error
            }
            continuation.finish()
            // Keep the framework await inside the same five-second deadline as
            // the results stream. A hung finalize must never return a partial.
            finalizationTask = Task { [weak self] in
                do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
                catch {
                    DiagnosticLog.record("speechAnalyzer finalization failed: \(error.localizedDescription)")
                    self?.state.receiveFailure(UserFacingErrorMessage.message(for: error, operation: "ローカル音声認識の確定"))
                }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while state.phase == .finishing && ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        if state.phase == .cancelled { throw CancellationError() }
        if let failure = state.failure { throw LocalError.recognitionFailure(failure) }
        guard state.isFinal else { throw LocalError.finalizationTimeout }
        guard !transcript.isEmpty else { throw LocalError.empty(nil) }
        return transcript
    }

    func cancel() {
        // Mark cancellation before the framework can issue its final callback.
        state.cancel()
        resultsTask?.cancel()
        resultsTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        continuation?.finish()
        continuation = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        converter = nil
        onUpdate = nil
    }
}
#endif
