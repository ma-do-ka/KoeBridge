import Foundation
import Testing
@testable import KoeBridgeCore

struct SettingsPersistenceTests {
    @Test func navigationLeavesExistingPreferencesAndPayloadsUntouched() throws {
        let suite = "KoeBridge.Build56." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = AppProfile(bundleIdentifier: "example.editor", displayName: "Editor",
                                 engine: nil, registeredVocabularyEnabled: false,
                                 textContextCheckEnabled: nil, audioRecheckAlways: nil)
        let profiles = try JSONEncoder().encode([profile])
        let snippets = try JSONEncoder().encode([SnippetRule(trigger: "署名", template: "{{DATE}}")])
        let presets = try JSONEncoder().encode([TransformPreset(name: "整形", steps: ["丁寧に", "短く"])])
        let seeded: [String: Any] = [
            "engine": "local", "smart": true, "transcriptionStyle": "readable",
            "recordingShortcut": "f8", "autoPaste": false,
            "voiceCommandsEnabled": true, "voiceCommand.newline": false,
            "retainAudioEnabled": true, "meetingModeEnabled": false,
            "permissionsIntroRequestedV044": true, "transcriptionOptionsVersion": 1,
            "registeredVocabularyEnabled": false, "topicVocabularyEnabled": true,
            "textContextCheckEnabled": false, "audioRecheckEnabled": false,
            "audioRecheckPolicy": "always", "vocabulary": "KoeBridge",
            "appProfiles": profiles, "snippets": snippets, "transformPresets": presets
        ]
        seeded.forEach { defaults.set($0.value, forKey: $0.key) }
        let before = try #require(defaults.persistentDomain(forName: suite))
        var navigation = SettingsNavigation()
        for entry in SettingsSearchCatalog.entries { navigation.focus(entry) }
        for page in SettingsSection.allCases { navigation.select(page) }
        navigation.back(); navigation.forward()
        let options = TranscriptionOptions.load(from: defaults, hasLegacyUsage: true)
        #expect(!options.registeredVocabularyEnabled)
        #expect(options.topicVocabularyEnabled)
        #expect(options.audioRecheckPolicy == .always)
        #expect(NSDictionary(dictionary: before).isEqual(to: try #require(defaults.persistentDomain(forName: suite))))
        let restored = try JSONDecoder().decode([AppProfile].self, from: try #require(defaults.data(forKey: "appProfiles")))
        #expect(restored == [profile])
        #expect(restored[0].engine == nil && restored[0].textContextCheckEnabled == nil)
        #expect(restored[0].registeredVocabularyEnabled == false)
        #expect(try JSONDecoder().decode([SnippetRule].self, from: try #require(defaults.data(forKey: "snippets"))).first?.template == "{{DATE}}")
        #expect(try JSONDecoder().decode([TransformPreset].self, from: try #require(defaults.data(forKey: "transformPresets"))).first?.steps == ["丁寧に", "短く"])
        #expect(defaults.bool(forKey: "smart"))
        #expect(!defaults.bool(forKey: "voiceCommand.newline"))
        #expect(defaults.bool(forKey: "retainAudioEnabled"))
    }

    @Test func missingAndFalseOptionsStillMigrateDifferently() throws {
        let suite = "KoeBridge.Build56.migration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "smart")
        defaults.set(false, forKey: "topicVocabularyEnabled")
        let options = TranscriptionOptions.load(from: defaults, hasLegacyUsage: true)
        #expect(options.registeredVocabularyEnabled) // Missing inherits legacy default.
        #expect(!options.topicVocabularyEnabled) // Explicit false survives.
        #expect(defaults.integer(forKey: "transcriptionOptionsVersion") == 1)
        #expect(TranscriptionOptions.load(from: defaults, hasLegacyUsage: true) == options)
        #expect(defaults.bool(forKey: "smart")) // Compatibility mirror is not a new control.
    }
}
