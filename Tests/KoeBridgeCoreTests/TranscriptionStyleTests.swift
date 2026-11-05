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
        let raw = try GeminiWire.setup(vocabulary: ["MY_CUSTOM_TOOL", "n8n", "MY_CUSTOM_TOOL"],
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

    @Test func defaultSettingsRemainUnmodifiedForOtherStyles() throws {
        for style in [TranscriptionStyle.verbatim, .readable] {
            let json = try GeminiWire.setup(vocabulary: ["GitHub", "n8n", "GitHub"],
                                            style: style, japaneseHint: true)
            let root = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let outer = try #require(root["setup"] as? [String: Any])
            let audio = try #require(outer["inputAudioTranscription"] as? [String: Any])
            #expect(audio["mode"] as? String == style.liveMode)
            #expect(audio["customVocabulary"] as? [String] == ["GitHub", "n8n"])
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
        let terms = AgentVocabulary.terms(user: chosen, style: .agent)
        #expect(terms.count == 100)
        #expect(terms.first == "term0")
        #expect(terms.last == "term99")
        #expect(AgentVocabulary.terms(user: ["GitHub", "github", " n8n "],
                                      style: .agent).filter { $0.lowercased() == "github" }.count == 1)
        #expect(AgentVocabulary.terms(user: ["test"], style: .agent, maximum: 0).isEmpty)
    }
}
