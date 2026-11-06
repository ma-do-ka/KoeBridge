import Foundation
import KoeBridgeCore

struct TranscriptionStyleSelfTests {
    func preservesLegacyChoiceAndNewMode() {
        check(TranscriptionStyle.restoring(storedStyle: nil, legacySmart: true) == .readable)
        check(TranscriptionStyle.restoring(storedStyle: nil, legacySmart: false) == .verbatim)
        check(TranscriptionStyle.restoring(storedStyle: "agent", legacySmart: true) == .agent)
        check(TranscriptionStyle.restoring(storedStyle: "invalid", legacySmart: true) == .readable)
    }

    func agentModeUsesSupportedGeminiWire() throws {
        let wordsToSend = AgentVocabulary.terms(user: ["MY_CUSTOM_TOOL", "n8n"],
                                                registeredEnabled: true, topicEnabled: true)
        let payload = try GeminiWire.setup(vocabulary: wordsToSend,
                                           style: .agent, japaneseHint: true)
        let root = try require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let setup = try require(root["setup"] as? [String: Any])
        let config = try require(setup["inputAudioTranscription"] as? [String: Any])
        check(config["mode"] as? String == "VERBATIM")
        let words = try require(config["customVocabulary"] as? [String])
        check(words.first == "MY_CUSTOM_TOOL")
        check(words.contains("GitHub Actions"))
        check(words.count <= 100)
        check(setup["systemInstruction"] == nil)
        let original = try GeminiWire.setup(vocabulary: ["GitHub", "n8n", "GitHub"],
                                            style: .readable, japaneseHint: true)
        let raw = try require(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        let originalSetup = try require(raw["setup"] as? [String: Any])
        let originalAudio = try require(originalSetup["inputAudioTranscription"] as? [String: Any])
        check(originalAudio["mode"] as? String == "SMART")
        check(originalAudio["customVocabulary"] as? [String] == ["GitHub", "n8n"])
        for style in TranscriptionStyle.allCases {
            let empty = try GeminiWire.setup(vocabulary: [], style: style, japaneseHint: false)
            let emptyRoot = try require(JSONSerialization.jsonObject(with: Data(empty.utf8)) as? [String: Any])
            let emptySetup = try require(emptyRoot["setup"] as? [String: Any])
            let emptyAudio = try require(emptySetup["inputAudioTranscription"] as? [String: Any])
            check(emptyAudio["customVocabulary"] == nil)
        }
    }

    func noTechnicalDetailIsDeletedByFormatting() {
        let spoken = "Issue #178を修正。次に--forceを禁止。最後にsrc/a.tsとhttps://example.com/?q=2を確認。"
        let formatted = AgentInstructionFormatting.format(spoken)
        check(formatted.replacingOccurrences(of: "\n", with: "") == spoken)
        check(formatted.contains("。\n次に"))
        check(formatted.contains("。\n最後に"))
        check(AgentInstructionFormatting.format(formatted) == formatted)
        check(AgentVocabulary.terms(user: ["one"], registeredEnabled: true, topicEnabled: true, maximum: 0).isEmpty)
    }
}
