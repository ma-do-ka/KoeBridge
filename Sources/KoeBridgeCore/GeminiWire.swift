import Foundation

public enum WireError: Error, LocalizedError {
    case invalidJSON
    case invalidResponse
    public var errorDescription: String? { "Gemini APIの応答を解析できません" }
}

public enum TranscribeEvent: Equatable, Sendable {
    case setupComplete
    case interim(String)
    case final(String)
    case turnComplete
    case activityEnd
    case error(String)
}

public enum GeminiWire {
    public static let modelID = "gemini-3.5-transcribe-live"
    public static let endpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    // Backwards-compatible entry point for existing callers and tests.
    public static func setup(vocabulary: [String], smart: Bool, japaneseHint: Bool) throws -> String {
        try setup(vocabulary: vocabulary, style: smart ? .readable : .verbatim, japaneseHint: japaneseHint)
    }

    public static func setup(vocabulary: [String], style: TranscriptionStyle,
                             japaneseHint: Bool) throws -> String {
        var audio: [String: Any] = [
            "languageCodes": japaneseHint ? ["ja-JP"] : [],
            // Agent is a KoeBridge presentation mode, not a new Gemini mode.
            "mode": style.liveMode
        ]
        // The caller snapshots the user's explicitly selected sources. A
        // presentation style must never re-enable an unchecked source.
        // Preserve priority/order when the combined list reaches the API cap.
        var seen = Set<String>()
        var words: [String] = []
        for raw in vocabulary {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty, seen.insert(word).inserted { words.append(word) }
            if words.count == 100 { break }
        }
        if !words.isEmpty { audio["customVocabulary"] = words }
        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(modelID)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                // A thinking pause is not an endpoint. The client sends one
                // activityStart after setup and one activityEnd on user stop.
                "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
                "inputAudioTranscription": audio
            ]
        ]
        return try json(setup)
    }

    /// Hybrid VAD stop marker. Valid only when automatic VAD is enabled.
    public static func audioStreamEnd() throws -> String {
        try json(["realtimeInput": ["audioStreamEnd": true]])
    }

    public static func activityStart() throws -> String {
        try json(["realtimeInput": ["activityStart": [String: String]() ]])
    }

    public static func audio(_ pcm16LE: Data) throws -> String {
        try json(["realtimeInput": ["audio": ["data": pcm16LE.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }

    public static func activityEnd() throws -> String {
        try json(["realtimeInput": ["activityEnd": [String: String]() ]])
    }

    public static func decode(_ raw: String) throws -> GeminiServerFrame {
        try GeminiServerFrame(data: Data(raw.utf8))
    }

    public static func parse(_ raw: String) throws -> [TranscribeEvent] {
        try decode(raw).events
    }

    /// Identity is available only when the service supplies both utterance
    /// offsets. Text equality alone cannot distinguish a replay from a user
    /// deliberately repeating the same words. These are documented optional
    /// fields; their absence must not suppress a final segment.
    public static func finalSegmentIdentity(_ raw: String) -> String? {
        (try? decode(raw))?.finalSegmentIdentity
    }

    /// Optional completion of a transcription, including a text-free frame.
    /// This can mark one speech segment and does not acknowledge activityEnd.
    public static func transcriptionFinished(_ raw: String) -> Bool {
        (try? decode(raw))?.transcriptionFinished ?? false
    }

    /// The server may send usageMetadata alongside other messages, including
    /// transcription events. Reported counts are not synthesized from audio length.
    public static func parseTokenUsage(_ raw: String) -> GeminiTokenUsage? {
        (try? decode(raw))?.tokenUsage
    }

    /// Diagnostic-only schema category. Never logs received transcript or
    /// API error bodies, which may contain private data.
    public static func frameKind(_ raw: String) -> String {
        (try? decode(raw))?.diagnosticKind ?? "invalid_json"
    }

    private static func json(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else { throw WireError.invalidJSON }
        return result
    }
}
