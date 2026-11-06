import Foundation
import KoeBridgeCore

struct TranscriptionOptionsSelfTests {
    func freshInstallAndLegacyChoices() throws {
        let suite = "KoeBridge.OptionsSelfTests.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        check(TranscriptionOptions.load(from: defaults, hasLegacyUsage: false) == TranscriptionOptions())
        for style in TranscriptionStyle.allCases {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(style.rawValue, forKey: "transcriptionStyle")
            defaults.set("My_Product", forKey: "vocabulary")
            let options = TranscriptionOptions.load(from: defaults, hasLegacyUsage: true)
            check(options.registeredVocabularyEnabled)
            check(options.topicVocabularyEnabled == (style == .agent))
            check(!options.textContextCheckEnabled && !options.audioRecheckEnabled)
            check(defaults.string(forKey: "vocabulary") == "My_Product")
        }
    }

    func explicitChoicesSurviveMigrationAndStyleChanges() throws {
        let suite = "KoeBridge.OptionsSelfTests.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("agent", forKey: "transcriptionStyle")
        defaults.set("Keep this text", forKey: "vocabulary")
        defaults.set(false, forKey: "registeredVocabularyEnabled")
        defaults.set(false, forKey: "topicVocabularyEnabled")
        check(TranscriptionOptions.load(from: defaults, hasLegacyUsage: true) == TranscriptionOptions())
        for mask in 0..<16 {
            for policy in AudioRecheckPolicy.allCases {
                let chosen = TranscriptionOptions(
                    registeredVocabularyEnabled: mask & 1 != 0,
                    topicVocabularyEnabled: mask & 2 != 0,
                    textContextCheckEnabled: mask & 4 != 0,
                    audioRecheckEnabled: mask & 8 != 0,
                    audioRecheckPolicy: policy
                )
                chosen.save(to: defaults)
                defaults.set("readable", forKey: "transcriptionStyle")
                check(TranscriptionOptions.load(from: defaults, hasLegacyUsage: true) == chosen)
            }
        }
        check(defaults.string(forKey: "vocabulary") == "Keep this text")
    }

    func vocabularySelectionIsIndependentAndBounded() {
        let user = [" My_Tool ", "n8n", "", "My_Tool"]
        check(AgentVocabulary.terms(user: user, registeredEnabled: false, topicEnabled: false).isEmpty)
        check(AgentVocabulary.terms(user: user, registeredEnabled: true, topicEnabled: false) == ["My_Tool", "n8n"])
        check(AgentVocabulary.terms(user: user, registeredEnabled: false, topicEnabled: true) == AgentVocabulary.defaults)
        let both = AgentVocabulary.terms(user: user, registeredEnabled: true, topicEnabled: true)
        check(Array(both.prefix(2)) == ["My_Tool", "n8n"])
        check(both.filter { $0 == "n8n" }.count == 1)
        let overflow = AgentVocabulary.terms(user: (0..<110).map { "term\($0)" },
                                             registeredEnabled: true, topicEnabled: true, maximum: 500)
        check(overflow.count == 100 && overflow.last == "term99")
    }
}
