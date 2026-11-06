import Foundation

/// A single decoded server message. Transcription, segment identity and usage
/// must come from the same frame; receiving code does not reparse its JSON.
public struct GeminiServerFrame: Equatable, Sendable {
    public let events: [TranscribeEvent]
    public let finalSegmentIdentity: String?
    public let transcriptionFinished: Bool
    public let tokenUsage: GeminiTokenUsage?
    /// Schema category only. This never includes transcript or API error text.
    public let diagnosticKind: String

    public init(data: Data) throws {
        // Binary WebSocket messages carry the same UTF-8 JSON as text frames.
        // Invalid bytes are a receive failure, not a silently empty message.
        guard String(data: data, encoding: .utf8) != nil,
              let value = try? JSONSerialization.jsonObject(with: data),
              let root = value as? [String: Any] else { throw WireError.invalidJSON }
        let content = root["serverContent"] as? [String: Any]
        let transcription = content?["inputTranscription"] as? [String: Any]

        var events: [TranscribeEvent] = []
        if root["setupComplete"] != nil { events.append(.setupComplete) }
        if let error = root["error"] as? [String: Any] {
            events.append(.error((error["message"] as? String) ?? "API エラー"))
        }
        if let partial = content?["interimInputTranscription"] as? [String: Any],
           let text = partial["text"] as? String, !text.isEmpty {
            events.append(.interim(text))
        }
        if let text = transcription?["text"] as? String, !text.isEmpty {
            events.append(.final(text))
        }
        if content?["turnComplete"] as? Bool == true { events.append(.turnComplete) }
        // `type` is the raw WebSocket key. SDK property voiceActivityType is
        // not a wire alias. Segment finished/generationComplete are not an
        // acknowledgement of the client's manual activityEnd.
        if let activity = root["voiceActivity"] as? [String: Any],
           activity["type"] as? String == "ACTIVITY_END" {
            events.append(.activityEnd)
        }
        self.events = events

        if let start = transcription?["startOffset"] as? String, !start.isEmpty,
           let end = transcription?["endOffset"] as? String, !end.isEmpty {
            finalSegmentIdentity = start + "|" + end + "|" + ((transcription?["speakerLabel"] as? String) ?? "")
        } else {
            finalSegmentIdentity = nil
        }
        transcriptionFinished = transcription?["finished"] as? Bool == true
        tokenUsage = Self.usage(root["usageMetadata"] as? [String: Any])
        diagnosticKind = Self.kind(root, content: content)
    }

    private static func usage(_ metadata: [String: Any]?) -> GeminiTokenUsage? {
        guard let metadata, let total = metadata["totalTokenCount"] as? Int, total >= 0 else { return nil }
        func valid(_ key: String) -> Int? {
            guard let value = metadata[key] as? Int, value >= 0 else { return nil }
            return value
        }
        return GeminiTokenUsage(promptTokens: valid("promptTokenCount"),
                                responseTokens: valid("candidatesTokenCount"),
                                totalTokens: total)
    }

    private static func kind(_ root: [String: Any], content: [String: Any]?) -> String {
        if root["setupComplete"] != nil { return "setupComplete" }
        if root["usageMetadata"] != nil && root["serverContent"] == nil { return "usageMetadata" }
        if root["error"] != nil { return "error" }
        if root["goAway"] != nil { return "goAway" }
        if root["sessionResumptionUpdate"] != nil { return "sessionResumptionUpdate" }
        if root["voiceActivity"] != nil { return "voiceActivity" }
        if let content {
            if content["interimInputTranscription"] != nil { return "serverContent.interimInputTranscription" }
            if content["inputTranscription"] != nil { return "serverContent.inputTranscription" }
            if content["turnComplete"] != nil { return "serverContent.turnComplete" }
            return "serverContent.other"
        }
        return "other"
    }
}
