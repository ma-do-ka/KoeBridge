#if os(macOS)
import Foundation
import AVFoundation
import Speech
import KoeBridgeCore

/// Offline fallback for macOS 15+. Not all locales/devices have an on-device model.
/// Never silently invoke Apple's server-side recognition.
@MainActor final class AppleLocalTranscriber: LocalTranscribing {
    let requiresSpeechAuthorization = true
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var state = LocalRecognitionState()
    var transcript: String { state.transcript }
    var onUpdate: ((String) -> Void)?
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16_000, channels: 1, interleaved: true)!

    func start() async throws {
        guard state.beginAuthorization() else {
            if state.phase == .cancelled { throw CancellationError() }
            throw LocalError.unavailable
        }
        do {
            try Task.checkCancellation()
            let authorization = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
            // Permission may return after the take has been cancelled. Do not
            // create an orphan recognizer or revive that take's callbacks.
            try Task.checkCancellation()
            guard state.phase != .cancelled else { throw CancellationError() }
            guard authorization == .authorized else { throw LocalError.permission }
            guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                throw LocalError.unavailable
            }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.requiresOnDeviceRecognition = true
            req.shouldReportPartialResults = true
            guard state.beginRecognition() else { throw CancellationError() }
            request = req
            recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self, self.state.acceptsUpdates else { return }
                    var updated = false
                    if let result {
                        updated = self.state.receive(result.bestTranscription.formattedString,
                                                     isFinal: result.isFinal)
                    }
                    if let error { self.state.receiveFailure(error.localizedDescription) }
                    if updated { self.onUpdate?(self.transcript) }
                }
            }
        } catch {
            cancel()
            throw error
        }
    }

    func appendPCM16(_ data: Data) throws {
        if state.phase == .cancelled { throw CancellationError() }
        if let failure = state.failure { throw LocalError.recognitionFailure(failure) }
        guard let request else { throw LocalError.unavailable }
        guard !data.isEmpty else { return }
        // Some on-device recognizers finish a task early. Never keep accepting
        // unheard tail audio and later submit the earlier prefix as a full take.
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
        request.append(buffer)
    }

    func endAudioAndAwaitFinal() async throws -> String {
        if state.phase == .cancelled { throw CancellationError() }
        guard let request else { throw LocalError.unavailable }
        if state.endAudio() { request.endAudio() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while state.phase == .finishing && ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        if state.phase == .cancelled { throw CancellationError() }
        if let failure = state.failure { throw LocalError.recognitionFailure(failure) }
        // A partial hypothesis is not a safe final transcript. The controller
        // saves the partial for manual recovery rather than pasting it as final.
        guard state.isFinal else { throw LocalError.finalizationTimeout }
        guard !transcript.isEmpty else { throw LocalError.empty(nil) }
        return transcript
    }

    func cancel() {
        // Mark cancellation before the framework can issue its final callback.
        state.cancel()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        onUpdate = nil
    }

    enum LocalError: Error, LocalizedError {
        case permission, unavailable, empty(String?), finalizationTimeout, recognitionFailure(String), endedBeforeAudio
        var errorDescription: String? {
            switch self {
            case .permission: return "macOSの音声認識許可が必要です"
            case .unavailable: return "このMacでは日本語のオンデバイス音声認識が利用できません。OS・言語パックを確認してください"
            case .empty(let e): return "ローカル音声認識の結果がありません\(e.map { ": \($0)" } ?? "")"
            case .finalizationTimeout: return "ローカル認識が5秒以内に確定しませんでした。途中結果は履歴に保存します"
            case .recognitionFailure(let reason): return "ローカル音声認識エラー: \(reason)"
            case .endedBeforeAudio: return "音声の末尾より先にAppleの認識が終了しました。途中結果を履歴に保存します"
            }
        }
    }
}
#endif
