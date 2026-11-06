import Foundation
import Testing
@testable import KoeBridgeCore

struct TranscriptionStyleTests {
    @Test func legacySmartPreferenceIsMigratedWithoutSurprise() {
        #expect(TranscriptionStyle.restoring(storedStyle: nil, legacySmart: false) == .verbatim)
        #expect(TranscriptionStyle.restoring(storedStyle: nil, legacySmart: true) == .readable)
        #expect(TranscriptionStyle.restoring(storedStyle: "agent", legacySmart: true) == .agent)
        #expect(TranscriptionStyle.restoring(storedStyle: "readable", legacySmart: false) == .readable)
        #expect(TranscriptionStyle.restoring(storedStyle: "unknown", legacySmart: true) == .readable)
    }

    @Test func agentWireUsesSupportedVerbatimModeAndPrioritizesUserTerms() throws {
        let selectedTerms = AgentVocabulary.terms(user: ["MY_CUSTOM_TOOL", "n8n", "MY_CUSTOM_TOOL"],
                                                  registeredEnabled: true, topicEnabled: true)
        let raw = try GeminiWire.setup(vocabulary: selectedTerms,
                                       style: .agent, japaneseHint: true)
        let root = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let setup = try #require(root["setup"] as? [String: Any])
        let audio = try #require(setup["inputAudioTranscription"] as? [String: Any])
        #expect(audio["mode"] as? String == "VERBATIM")
        #expect(audio["languageCodes"] as? [String] == ["ja-JP"])
        let vocab = try #require(audio["customVocabulary"] as? [String])
        #expect(vocab.first == "MY_CUSTOM_TOOL")
        #expect(vocab.filter { $0 == "n8n" }.count == 1)
        #expect(vocab.contains("GitHub Actions"))
        #expect(vocab.count <= 100)
        #expect(setup["systemInstruction"] == nil)
        #expect(setup["generationConfig"] != nil)
    }

    @Test func noStyleImplicitlyEnablesVocabulary() throws {
        for style in TranscriptionStyle.allCases {
            let json = try GeminiWire.setup(vocabulary: ["GitHub", "n8n", "GitHub"],
                                            style: style, japaneseHint: true)
            let root = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let outer = try #require(root["setup"] as? [String: Any])
            let audio = try #require(outer["inputAudioTranscription"] as? [String: Any])
            #expect(audio["mode"] as? String == style.liveMode)
            #expect(audio["customVocabulary"] as? [String] == ["GitHub", "n8n"])

            let emptyJSON = try GeminiWire.setup(vocabulary: [], style: style, japaneseHint: false)
            let emptyRoot = try #require(JSONSerialization.jsonObject(with: Data(emptyJSON.utf8)) as? [String: Any])
            let emptySetup = try #require(emptyRoot["setup"] as? [String: Any])
            let emptyAudio = try #require(emptySetup["inputAudioTranscription"] as? [String: Any])
            #expect(emptyAudio["customVocabulary"] == nil)
        }
    }

    @Test func agentFormatterOnlyInsertsNewlinesAndPreservesTechnicalLiterals() {
        let spoken = "Issue #178を直す。次に--forceは使わず、src/worker.tsを修正。必ず0件の失敗を確認。最後にhttps://example.com/api?v=1.2を参照。"
        let formatted = AgentInstructionFormatting.format(spoken)
        #expect(formatted.contains("。\n次に"))
        #expect(formatted.contains("。\n必ず"))
        #expect(formatted.contains("。\n最後に"))
        #expect(formatted.replacingOccurrences(of: "\n", with: "") == spoken)
        #expect(AgentInstructionFormatting.format(formatted) == formatted)
        // Direct typing deliberately converts newlines into spaces to avoid
        // accidentally submitting a chat prompt with Enter.
        let safe = UnicodeTypingPlan.safeText(formatted)
        #expect(safe.contains("--force"))
        #expect(safe.contains("src/worker.ts"))
        #expect(safe.contains("https://example.com/api?v=1.2"))
        #expect(!safe.contains("\n"))
    }

    @Test func vocabularyHonorsUserPriorityAndDeduplicatesWithinCap() {
        let chosen = (0..<110).map { "term\($0)" }
        let terms = AgentVocabulary.terms(user: chosen, registeredEnabled: true, topicEnabled: true)
        #expect(terms.count == 100)
        #expect(terms.first == "term0")
        #expect(terms.last == "term99")
        #expect(AgentVocabulary.terms(user: ["GitHub", "github", " n8n "],
                                      registeredEnabled: true, topicEnabled: true).filter { $0.lowercased() == "github" }.count == 1)
        #expect(AgentVocabulary.terms(user: ["test"], registeredEnabled: true, topicEnabled: true, maximum: 0).isEmpty)
        #expect(AgentVocabulary.terms(user: chosen, registeredEnabled: true, topicEnabled: true, maximum: 500).count == 100)
    }

    @Test func vocabularyCheckboxesSelectEachSourceIndependently() {
        let user = [" custom_TOOL ", "n8n", "", "custom_TOOL"]
        #expect(AgentVocabulary.terms(user: user, registeredEnabled: false, topicEnabled: false).isEmpty)
        #expect(AgentVocabulary.terms(user: user, registeredEnabled: true, topicEnabled: false) == ["custom_TOOL", "n8n"])
        let topicOnly = AgentVocabulary.terms(user: user, registeredEnabled: false, topicEnabled: true)
        #expect(topicOnly == AgentVocabulary.defaults)
        #expect(!topicOnly.contains("custom_TOOL"))
        let both = AgentVocabulary.terms(user: user, registeredEnabled: true, topicEnabled: true)
        #expect(Array(both.prefix(2)) == ["custom_TOOL", "n8n"])
        #expect(both.filter { $0 == "n8n" }.count == 1)
        #expect(both.contains("GitHub Actions"))
    }
}
