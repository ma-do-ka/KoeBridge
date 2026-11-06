import Foundation
import KoeBridgeCore

struct TranscriptReviewSelfTests {
    func conservativeTextAndBoundedTime() {
        let checked = TextContextChecking.check("設定について。はあとで考えるという。ことです。")
        check(checked.text == "設定についてはあとで考えるということです。")
        check(checked.changes == 2)
        check(TextContextChecking.check("`という。こと` と「について。は」").changes == 0)
        check(!TextContextChecking.hasMatchingWords(original: "100円を変更しない", candidate: "1000円を変更する"))
        check(!TextContextChecking.hasMatchingWords(original: "foo bar", candidate: "foobar"))
        check(TextContextChecking.hasMatchingWords(original: "設定について。は変更しない。", candidate: "設定については、変更しない。"))
        let stop = Date(timeIntervalSince1970: 100)
        check(TranscriptReviewDeadline.available(stoppedAt: stop, now: stop.addingTimeInterval(12)) == 2.75)
        check(TranscriptReviewDeadline.available(stoppedAt: stop, now: stop.addingTimeInterval(14.8)) == 0)
    }

    func wavRequestAndFinalResponse() throws {
        let pcm = Data([0, 1, 255, 127])
        let wav = try GeminiRecheckWire.wav(pcm16LE: pcm)
        check(wav.count == 48 && wav.suffix(4) == pcm)
        let request = try GeminiRecheckWire.request(pcm16LE: pcm, vocabulary: [], style: .agent, japaneseHint: true)
        let root = try require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let generation = try require(root["generationConfig"] as? [String: Any])
        let config = try require(generation["audioTranscriptionConfig"] as? [String: Any])
        check(config["customVocabulary"] == nil)
        check(config["mode"] as? String == "VERBATIM")
        let complete = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"本文。"}]}}]}"#.utf8)
        try check(try GeminiRecheckWire.response(complete) == "本文。")
        checkThrows(GeminiRecheckWire.RecheckError.self) {
            _ = try GeminiRecheckWire.response(Data(#"{"candidates":[{"finishReason":"MAX_TOKENS"}]}"#.utf8))
        }
    }

    func mixedLiteralBoundariesKeepStableUnicodeOffsets() {
        let literal = "👩🏽‍💻 `という。こと` src/という。こと.swift 「について。は」"
        let source = "設定について。は変更するという。ことです。\(literal) 次の案に関して。は担当として。は確認します。という。ものです。"
        let expected = "設定については変更するということです。\(literal) 次の案に関しては担当としては確認します。というものです。"
        let result = TextContextChecking.check(source)
        check(result.text == expected)
        check(result.changes == 5)
        check(TextContextChecking.check(result.text).changes == 0)
        check(TextContextChecking.hasMatchingWords(original: source, candidate: result.text))

        let quoted = "👩🏽‍💻「作業。次に確認」 src/手順。必ず確認.swift"
        let instructions = "開始。必ず確認。次に\(quoted) を参照。その後実行。最後に確認。"
        let formatted = AgentInstructionFormatting.format(instructions)
        check(formatted == "開始。\n必ず確認。\n次に\(quoted) を参照。\nその後実行。\n最後に確認。")
        check(AgentInstructionFormatting.format(formatted) == formatted)
        check(formatted.replacingOccurrences(of: "\n", with: "") == instructions)
    }
}
