#if os(macOS)
import Foundation
import AVFoundation
import Speech

/// Offline fallback for macOS 15+. Not all locales/devices have an on-device model.
/// Never silently invoke Apple's server-side recognition.
@MainActor final class AppleLocalTranscriber {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private(set) var transcript = ""
    private var isFinal = false
    private var failure: String?
    var onUpdate: ((String) -> Void)?
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16_000, channels: 1, interleaved: true)!

    func start() async throws {
        let authorization = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard authorization == .authorized else { throw LocalError.permission }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw LocalError.unavailable
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        request = req
        transcript = ""
        isFinal = false
        failure = nil
        recognitionTask = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.isFinal = result.isFinal
                    self.onUpdate?(self.transcript)
                }
                if let error, !self.isFinal { self.failure = error.localizedDescription }
            }
        }
    }

    func appendPCM16(_ data: Data) throws {
        guard let request else { throw LocalError.unavailable }
        // Some on-device recognizers finish a task early. Never keep accepting
        // unheard tail audio and later submit the earlier prefix as a full take.
        guard !isFinal || data.isEmpty else { throw LocalError.endedBeforeAudio }
        let frames = AVAudioFrameCount(data.count / 2)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frames),
              let pointer = buffer.int16ChannelData?.pointee else { return }
        buffer.frameLength = frames
        data.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            memcpy(pointer, base, Int(frames) * MemoryLayout<Int16>.size)
        }
        request.append(buffer)
    }

    func endAudioAndAwaitFinal() async throws -> String {
        request?.endAudio()
        let deadline = Date().addingTimeInterval(5)
        while !isFinal && failure == nil && Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        if let failure { throw LocalError.recognitionFailure(failure) }
        // A partial hypothesis is not a safe final transcript. The controller
        // saves the partial for manual recovery rather than pasting it as final.
        guard isFinal else { throw LocalError.finalizationTimeout }
        guard !transcript.isEmpty else { throw LocalError.empty(nil) }
        return transcript
    }

    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
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
