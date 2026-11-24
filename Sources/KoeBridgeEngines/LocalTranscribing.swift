#if os(macOS)
import Foundation
import AVFAudio
import KoeBridgeCore

@MainActor public protocol LocalTranscribing: AnyObject {
    var transcript: String { get }
    var onUpdate: ((RecognitionPreview) -> Void)? { get set }
    var requiresSpeechAuthorization: Bool { get }
    func start() async throws
    func appendPCM16(_ data: Data) throws
    func appendRecoveryPCM(_ data: Data, range: Range<Int>) async throws
    func endAudioAndAwaitFinal() async throws -> String
    func cancel()
}

enum LocalPCM {
    static func buffer(_ data: Data, range: Range<Int>, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        typealias LocalError = AppleLocalTranscriber.LocalError
        guard range.count.isMultiple(of: 2), range.count / 2 <= Int(AVAudioFrameCount.max) else {
            throw LocalError.recognitionFailure("音声データの形式が不正です")
        }
        let frames = AVAudioFrameCount(range.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let pointer = buffer.int16ChannelData?.pointee else {
            throw LocalError.recognitionFailure("音声データを認識用に準備できませんでした")
        }
        buffer.frameLength = frames
        data.withUnsafeBytes { src in
            guard let base = src.baseAddress else { return }
            memcpy(pointer, base.advanced(by: range.lowerBound - data.startIndex), range.count)
        }
        return buffer
    }
    static func recoveryBuffer(_ data: Data, range: Range<Int>, format: AVAudioFormat) async throws -> AVAudioPCMBuffer {
        try buffer(data, range: range, format: format)
    }
}

@MainActor public enum LocalTranscriberFactory {
    public static func make() -> LocalTranscribing {
        if #available(macOS 26, *) {
            EngineDiagnostics.record("local backend: speechAnalyzer")
            return SpeechAnalyzerTranscriber()
        }
        EngineDiagnostics.record("local backend: sfSpeech")
        return AppleLocalTranscriber()
    }
}
#endif
