import Foundation

public enum WireError: Error, LocalizedError {
    case invalidJSON
    case invalidResponse
    public var errorDescription: String? { "Gemini APIの応答を解析できません" }
}

public enum TranscribeEvent: Equatable {
    case setupComplete
    case interim(String)
    case final(String)
    case turnComplete
    case error(String)
}

public enum GeminiWire {
    public static let modelID = "gemini-3.5-transcribe-live"
    public static let endpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    public static func setup(vocabulary: [String], smart: Bool, japaneseHint: Bool) throws -> String {
        var audio: [String: Any] = [
            "languageCodes": japaneseHint ? ["ja-JP"] : [],
            "mode": smart ? "SMART" : "VERBATIM"
        ]
        let words = Array(Set(vocabulary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        if !words.isEmpty { audio["customVocabulary"] = Array(words.prefix(100)) }
        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(modelID)",
                "generationConfig": ["responseModalities": ["TEXT"]],
            // Auto-VAD detects speech starts; F8 sends audioStreamEnd on stop.
            // Google's Hybrid VAD path avoids manual activityStart clipping.
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

    public static func parse(_ raw: String) throws -> [TranscribeEvent] {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let root = value as? [String: Any] else {
            throw WireError.invalidJSON
        }
        var events: [TranscribeEvent] = []
        if root["setupComplete"] != nil { events.append(.setupComplete) }
        if let error = root["error"] as? [String: Any] {
            events.append(.error((error["message"] as? String) ?? "API エラー"))
        }
        if let content = root["serverContent"] as? [String: Any] {
            if let partial = content["interimInputTranscription"] as? [String: Any],
               let text = partial["text"] as? String, !text.isEmpty {
                events.append(.interim(text))
            }
            if let final = content["inputTranscription"] as? [String: Any],
               let text = final["text"] as? String, !text.isEmpty {
                events.append(.final(text))
            }
            if content["turnComplete"] as? Bool == true { events.append(.turnComplete) }
        }
        return events
    }

    /// Diagnostic-only schema category. Never logs received transcript or
    /// API error bodies, which may contain private data.
    public static func frameKind(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "invalid_json"
        }
        if root["setupComplete"] != nil { return "setupComplete" }
        if root["error"] != nil { return "error" }
        if root["goAway"] != nil { return "goAway" }
        if root["sessionResumptionUpdate"] != nil { return "sessionResumptionUpdate" }
        if let content = root["serverContent"] as? [String: Any] {
            if content["interimInputTranscription"] != nil { return "serverContent.interimInputTranscription" }
            if content["inputTranscription"] != nil { return "serverContent.inputTranscription" }
            if content["turnComplete"] != nil { return "serverContent.turnComplete" }
            return "serverContent.other"
        }
        return "other"
    }

    private static func json(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else { throw WireError.invalidJSON }
        return result
    }
}
