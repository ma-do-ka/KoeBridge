import Foundation
import CoreFoundation

/// Only the numeric status crosses the provider trust boundary.
public struct GeminiProviderError: LocalizedError, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case authentication, rateLimited, unavailable, rejected
    }

    public let code: Int?
    public init(code: Int?) { self.code = code }

    public var kind: Kind {
        switch code {
        case 401, 403: return .authentication
        case 429: return .rateLimited
        case 500, 502, 503, 504: return .unavailable
        default: return .rejected
        }
    }

    public var diagnostic: String { "kind=\(kind.rawValue) code=\(code.map(String.init) ?? "unknown")" }

    public var errorDescription: String? {
        switch kind {
        case .authentication: return "APIキーとアクセス権を確認してください。"
        case .rateLimited: return "利用上限に達しました。時間をおいてもう一度お試しください。"
        case .unavailable: return "サーバーを利用できません。時間をおいてもう一度お試しください。"
        case .rejected: return "リクエストが拒否されました。"
        }
    }
}

/// A single decoded server message. Transcription, segment identity and usage
/// must come from the same frame; receiving code does not reparse its JSON.
public struct GeminiServerFrame: Equatable, Sendable {
    public let events: [TranscribeEvent]
    public let finalSegmentIdentity: String?
    public let transcriptionFinished: Bool
    public let tokenUsage: GeminiTokenUsage?
    /// Schema category only. This never includes transcript or API error text.
    public let announcesGoAway: Bool
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
            events.append(.providerError(GeminiProviderError(code: error["code"] as? Int)))
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
        announcesGoAway = root["goAway"] != nil
        diagnosticKind = Self.kind(root, content: content)
    }

    private static func usage(_ metadata: [String: Any]?) -> GeminiTokenUsage? {
        guard let metadata else { return nil }
        func valid(_ key: String) -> Int? {
            guard let number = metadata[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = number as? Int, GeminiTokenUsage.counterRange.contains(value) else { return nil }
            return value
        }
        guard let total = valid("totalTokenCount") else { return nil }
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
