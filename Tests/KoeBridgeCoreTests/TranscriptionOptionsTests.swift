import Foundation
import Testing
@testable import KoeBridgeCore

struct TranscriptionOptionsTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "KoeBridge.TranscriptionOptionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test func freshInstallationStartsWithAllOptionalAidsOff() {
        withDefaults { defaults in
            let options = TranscriptionOptions.load(from: defaults, hasLegacyUsage: false)
            #expect(options == TranscriptionOptions())
            #expect(defaults.integer(forKey: TranscriptionOptions.PreferenceKey.version) == 1)
            #expect(defaults.object(forKey: "vocabulary") == nil)
        }
    }

    @Test func legacyStylesPreserveTheirEffectiveVocabularySelection() {
        for style in TranscriptionStyle.allCases {
            withDefaults { defaults in
                defaults.set(style.rawValue, forKey: "transcriptionStyle")
                defaults.set("My_Product\n日本語の用語", forKey: "vocabulary")
                let options = TranscriptionOptions.load(from: defaults, hasLegacyUsage: false)
                #expect(options.registeredVocabularyEnabled)
                #expect(options.topicVocabularyEnabled == (style == .agent))
                #expect(!options.textContextCheckEnabled)
                #expect(!options.audioRecheckEnabled)
                #expect(defaults.string(forKey: "vocabulary") == "My_Product\n日本語の用語")
                #expect(defaults.string(forKey: "transcriptionStyle") == style.rawValue)
            }
        }
    }

    @Test func legacyUsageWithoutPreferencesStillKeepsRegisteredTerms() {
        withDefaults { defaults in
            let options = TranscriptionOptions.load(from: defaults, hasLegacyUsage: true)
            #expect(options.registeredVocabularyEnabled)
            #expect(!options.topicVocabularyEnabled)
            #expect(!options.textContextCheckEnabled)
            #expect(!options.audioRecheckEnabled)
        }
    }

    @Test func storedLegacyFalseIsStillEvidenceOfAnExistingInstallation() {
        withDefaults { defaults in
            defaults.set(false, forKey: "smart")
            let options = TranscriptionOptions.load(from: defaults, hasLegacyUsage: false)
            #expect(options.registeredVocabularyEnabled)
            #expect(!options.topicVocabularyEnabled)
            #expect(defaults.object(forKey: "smart") != nil)
            #expect(!defaults.bool(forKey: "smart"))
        }
    }

    @Test func explicitFalseBeforeMigrationWinsOverLegacyDefaults() {
        withDefaults { defaults in
            defaults.set("agent", forKey: "transcriptionStyle")
            defaults.set(false, forKey: "registeredVocabularyEnabled")
            defaults.set(false, forKey: "topicVocabularyEnabled")
            defaults.set(true, forKey: "textContextCheckEnabled")
            defaults.set("always", forKey: "audioRecheckPolicy")
            let options = TranscriptionOptions.load(from: defaults, hasLegacyUsage: true)
            #expect(!options.registeredVocabularyEnabled)
            #expect(!options.topicVocabularyEnabled)
            #expect(options.textContextCheckEnabled)
            #expect(!options.audioRecheckEnabled)
            #expect(options.audioRecheckPolicy == .always)
        }
    }

    @Test func migrationRunsOnceAndNeverReenablesAnUncheckedAid() {
        withDefaults { defaults in
            defaults.set("agent", forKey: "transcriptionStyle")
            defaults.set("Keep this text", forKey: "vocabulary")
            _ = TranscriptionOptions.load(from: defaults, hasLegacyUsage: true)
            TranscriptionOptions().save(to: defaults)
            // An absent field after a completed migration also means disabled.
            defaults.removeObject(forKey: "topicVocabularyEnabled")
            let restored = TranscriptionOptions.load(from: defaults, hasLegacyUsage: true)
            #expect(restored == TranscriptionOptions())
            #expect(defaults.string(forKey: "vocabulary") == "Keep this text")
        }
    }

    @Test func allCheckboxCombinationsAndSchedulePersistIndependently() {
        withDefaults { defaults in
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
                    defaults.set("agent", forKey: "transcriptionStyle")
                    #expect(TranscriptionOptions.load(from: defaults, hasLegacyUsage: true) == chosen)
                }
            }
        }
    }

    @Test func unknownScheduleFallsBackWithoutTurningOnAudioRecheck() {
        withDefaults { defaults in
            defaults.set("unsupported", forKey: "audioRecheckPolicy")
            let options = TranscriptionOptions.load(from: defaults, hasLegacyUsage: false)
            #expect(options.audioRecheckPolicy == .whenSuspicious)
            #expect(!options.audioRecheckEnabled)
        }
    }
}
