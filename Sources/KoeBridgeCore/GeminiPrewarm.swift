import Foundation

public struct GeminiPrewarmSnapshot: Equatable, Sendable {
    public var vocabulary: [String]
    public var style: TranscriptionStyle
    public var japaneseHint: Bool
    public var apiKeyFingerprint: String

    public init(vocabulary: [String], style: TranscriptionStyle, japaneseHint: Bool,
                apiKeyFingerprint: String) {
        self.vocabulary = vocabulary
        self.style = style
        self.japaneseHint = japaneseHint
        self.apiKeyFingerprint = apiKeyFingerprint
    }

    /// Stable FNV-1a identifier for in-memory equality only. Never log or persist.
    public static func fingerprint(apiKey: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in apiKey.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return "\(apiKey.utf8.count):\(String(hash, radix: 16))"
    }
}

public enum GeminiPrewarmPolicy {
    public static let maximumWarmAge: TimeInterval = 480

    public static func isUsable(snapshot: GeminiPrewarmSnapshot, current: GeminiPrewarmSnapshot,
                                warmedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(warmedAt)
        return snapshot == current && age >= 0 && age < maximumWarmAge
    }
}
