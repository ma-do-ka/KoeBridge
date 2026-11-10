#if os(macOS)
import Foundation
import KoeBridgeCore

@MainActor protocol LocalTranscribing: AnyObject {
    var transcript: String { get }
    var onUpdate: ((RecognitionPreview) -> Void)? { get set }
    var requiresSpeechAuthorization: Bool { get }
    func start() async throws
    func appendPCM16(_ data: Data) throws
    func endAudioAndAwaitFinal() async throws -> String
    func cancel()
}

@MainActor enum LocalTranscriberFactory {
    static func make() -> LocalTranscribing {
        if #available(macOS 26, *) {
            DiagnosticLog.record("local backend: speechAnalyzer")
            return SpeechAnalyzerTranscriber()
        }
        DiagnosticLog.record("local backend: sfSpeech")
        return AppleLocalTranscriber()
    }
}
#endif
