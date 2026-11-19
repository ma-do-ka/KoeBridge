import Foundation

/// The schedule is exclusive; the two additional checks are independent.
public enum AudioRecheckPolicy: String, CaseIterable, Codable, Sendable, Identifiable {
    case whenSuspicious
    case always

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .whenSuspicious: return "疑わしい箇所があるとき"
        case .always: return "毎回"
        }
    }
}

/// A snapshot of the user's explicitly selected recognition aids.
/// A transcription style never enables one of these options implicitly.
public struct TranscriptionOptions: Codable, Equatable, Sendable {
    public var registeredVocabularyEnabled: Bool
    public var topicVocabularyEnabled: Bool
    public var textContextCheckEnabled: Bool
    public var audioRecheckEnabled: Bool
    public var audioRecheckPolicy: AudioRecheckPolicy

    public init(
        registeredVocabularyEnabled: Bool = false,
        topicVocabularyEnabled: Bool = false,
        textContextCheckEnabled: Bool = false,
        audioRecheckEnabled: Bool = false,
        audioRecheckPolicy: AudioRecheckPolicy = .whenSuspicious
    ) {
        self.registeredVocabularyEnabled = registeredVocabularyEnabled
        self.topicVocabularyEnabled = topicVocabularyEnabled
        self.textContextCheckEnabled = textContextCheckEnabled
        self.audioRecheckEnabled = audioRecheckEnabled
        self.audioRecheckPolicy = audioRecheckPolicy
    }

    public enum PreferenceKey {
        public static let registeredVocabularyEnabled = "registeredVocabularyEnabled"
        public static let topicVocabularyEnabled = "topicVocabularyEnabled"
        public static let textContextCheckEnabled = "textContextCheckEnabled"
        public static let audioRecheckEnabled = "audioRecheckEnabled"
        public static let audioRecheckPolicy = "audioRecheckPolicy"
        public static let version = "transcriptionOptionsVersion"
    }

    /// Migrates the old effective vocabulary selection once. Older versions
    /// always sent registered terms, and agent style also sent the IT terms.
    /// The caller can identify an existing installation even when the user
    /// never changed a preference (for example, by an existing API key).
    /// Explicit new false values always win over legacy behavior.
    public static func load(from defaults: UserDefaults = .standard, hasLegacyUsage: Bool) -> Self {
        let needsMigration = defaults.integer(forKey: PreferenceKey.version) < 1
        let legacyKeys = [
            "engine", "transcriptionStyle", "smart", "japanese", "autoPaste", "vocabulary",
            "recordingShortcut", "diagnosticsEnabled",
            "permissionsIntroRequestedV044", "checkUpdatesAutomatically",
            "lastAutomaticUpdateCheckAttemptAt", "lastSuccessfulUpdateCheckAt"
        ]
        let isLegacyInstallation = hasLegacyUsage || legacyKeys.contains {
            defaults.object(forKey: $0) != nil
        }
        let legacyStyle = TranscriptionStyle.restoring(
            storedStyle: defaults.string(forKey: "transcriptionStyle"),
            legacySmart: defaults.bool(forKey: "smart")
        )

        func flag(_ key: String, legacyDefault: Bool = false) -> Bool {
            if defaults.object(forKey: key) != nil {
                return defaults.bool(forKey: key)
            }
            return needsMigration && isLegacyInstallation && legacyDefault
        }

        let options = Self(
            registeredVocabularyEnabled: flag(PreferenceKey.registeredVocabularyEnabled, legacyDefault: true),
            topicVocabularyEnabled: flag(PreferenceKey.topicVocabularyEnabled, legacyDefault: legacyStyle == .agent),
            textContextCheckEnabled: flag(PreferenceKey.textContextCheckEnabled),
            audioRecheckEnabled: flag(PreferenceKey.audioRecheckEnabled),
            audioRecheckPolicy: defaults.string(forKey: PreferenceKey.audioRecheckPolicy)
                .flatMap(AudioRecheckPolicy.init(rawValue:)) ?? .whenSuspicious
        )
        if needsMigration { options.save(to: defaults) }
        return options
    }

    /// Registered text is deliberately stored separately and is never cleared
    /// when its checkbox is disabled.
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(registeredVocabularyEnabled, forKey: PreferenceKey.registeredVocabularyEnabled)
        defaults.set(topicVocabularyEnabled, forKey: PreferenceKey.topicVocabularyEnabled)
        defaults.set(textContextCheckEnabled, forKey: PreferenceKey.textContextCheckEnabled)
        defaults.set(audioRecheckEnabled, forKey: PreferenceKey.audioRecheckEnabled)
        defaults.set(audioRecheckPolicy.rawValue, forKey: PreferenceKey.audioRecheckPolicy)
        defaults.set(1, forKey: PreferenceKey.version)
    }
}

/// Keep the decoded rows bound to the defaults value they came from.
public struct SettingsArray<Row: Codable> {
    public enum State { case unset, loaded, corrupt }
    private let key: String
    private let defaults: UserDefaults
    private var original: NSObject?
    public private(set) var state: State = .unset
    public private(set) var rows: [Row] = []

    public init(_ key: String, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        reload()
    }

    private mutating func reload() {
        original = defaults.object(forKey: key) as? NSObject
        rows = []
        guard let original else { state = .unset; return }
        guard let data = original as? Data,
              let decoded = try? JSONDecoder().decode([Row].self, from: data) else {
            state = .corrupt
            return
        }
        rows = decoded
        state = .loaded
    }

    @discardableResult public mutating func save(_ updated: [Row]) -> Bool {
        guard original == defaults.object(forKey: key) as? NSObject else { reload(); return false }
        guard state != .corrupt, let data = try? JSONEncoder().encode(updated) else { return false }
        defaults.set(data, forKey: key)
        original = data as NSData
        rows = updated
        state = .loaded
        return true
    }

    public mutating func resetCorruptValue() {
        if state == .corrupt, original == defaults.object(forKey: key) as? NSObject {
            defaults.removeObject(forKey: key)
        }
        reload()
    }
}
