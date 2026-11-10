import Foundation

/// Flat optional overrides: nil inherits the global setting.
public struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var bundleIdentifier: String
    public var displayName: String
    public var isEnabled: Bool
    public var engine: String?
    public var style: String?
    public var additionalVocabulary: String
    public var registeredVocabularyEnabled: Bool?
    public var topicVocabularyEnabled: Bool?
    public var textContextCheckEnabled: Bool?
    public var audioRecheckEnabled: Bool?
    /// true = always, false = when suspicious, nil = global policy.
    public var audioRecheckAlways: Bool?
    public var postProcessEnabled: Bool?
    public var postProcessMode: String?

    public init(id: UUID = UUID(), bundleIdentifier: String, displayName: String,
                isEnabled: Bool = true, engine: String? = nil, style: String? = nil,
                additionalVocabulary: String = "", registeredVocabularyEnabled: Bool? = nil,
                topicVocabularyEnabled: Bool? = nil, textContextCheckEnabled: Bool? = nil,
                audioRecheckEnabled: Bool? = nil, audioRecheckAlways: Bool? = nil,
                postProcessEnabled: Bool? = nil, postProcessMode: String? = nil) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.engine = engine
        self.style = style
        self.additionalVocabulary = additionalVocabulary
        self.registeredVocabularyEnabled = registeredVocabularyEnabled
        self.topicVocabularyEnabled = topicVocabularyEnabled
        self.textContextCheckEnabled = textContextCheckEnabled
        self.audioRecheckEnabled = audioRecheckEnabled
        self.audioRecheckAlways = audioRecheckAlways
        self.postProcessEnabled = postProcessEnabled
        self.postProcessMode = postProcessMode
    }
}

public enum AppProfileResolver {
    public static func match(profiles: [AppProfile], bundleIdentifier: String?) -> AppProfile? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return profiles.first { $0.isEnabled && $0.bundleIdentifier == bundleIdentifier }
    }

    public static func mergedVocabulary(profileTerms: [String], globalTerms: [String]) -> [String] {
        AgentVocabulary.terms(user: profileTerms + globalTerms, registeredEnabled: true, topicEnabled: false)
    }
}
