#if os(macOS)
import Foundation
import KoeBridgeCore

enum GeminiAudioRechecker {
    struct Result {
        let text: String
        let usage: GeminiTokenUsage?
    }

    static func recognize(pcm16LE: Data, vocabulary: [String], style: TranscriptionStyle,
                          japaneseHint: Bool, apiKey: String, timeout: TimeInterval, context: String? = nil) async throws -> Result {
        try Task.checkCancellation()
        let body = try GeminiRecheckWire.request(pcm16LE: pcm16LE, vocabulary: vocabulary, style: style,
                                                japaneseHint: japaneseHint, context: context)
        let data = try await GeminiTransfer.send(body: body, endpoint: GeminiRecheckWire.endpoint,
                                                apiKey: apiKey, timeout: timeout)
        let text = try GeminiRecheckWire.response(data)
        let usage = String(data: data, encoding: .utf8).flatMap(GeminiWire.parseTokenUsage)
        return Result(text: text, usage: usage)
    }
}
#endif
