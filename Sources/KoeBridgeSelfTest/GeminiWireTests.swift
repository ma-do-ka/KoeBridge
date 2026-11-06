import Foundation
import KoeBridgeCore

struct GeminiWireTests {
    func setupAndAudioMatchGoogleWireFormat() throws {
        let setup = try GeminiWire.setup(vocabulary: ["GitHub", "n8n", "GitHub"], smart: false, japaneseHint: true)
        let obj = try require(JSONSerialization.jsonObject(with: Data(setup.utf8)) as? [String: Any])
        let dict = try require(obj["setup"] as? [String: Any])
        check(dict["model"] as? String == "models/gemini-3.5-transcribe-live")
        let transcription = try require(dict["inputAudioTranscription"] as? [String: Any])
        check(transcription["mode"] as? String == "VERBATIM")
        check(transcription["customVocabulary"] as? [String] == ["GitHub", "n8n"])
        let audio = try GeminiWire.audio(Data([0, 1, 255]))
        let wire = try require(JSONSerialization.jsonObject(with: Data(audio.utf8)) as? [String: Any])
        let realtime = try require(wire["realtimeInput"] as? [String: Any])
        let pcm = try require(realtime["audio"] as? [String: Any])
        check(pcm["mimeType"] as? String == "audio/pcm;rate=16000")
        check(pcm["data"] as? String == "AAH/")
    }

    func parseInterimFinalTurnComplete() throws {
        let events = try GeminiWire.parse("""
        {"serverContent":{"interimInputTranscription":{"text":"おは"},"inputTranscription":{"text":"おはよう"},"turnComplete":true}}
        """)
        check(events == [.interim("おは"), .final("おはよう"), .turnComplete])
    }

    func setupComplete() throws {
        let events = try GeminiWire.parse("{\"setupComplete\":{}}")
        check(events == [.setupComplete])
    }

    func assemblerJapaneseSegmentsAndEnglish() {
        var a = TranscriptAssembler()
        a.apply(.interim("おは"))
        check(a.displayText == "おは")
        a.apply(.final("おはよう"))
        a.apply(.final("ございます"), segmentIdentity: "1s|2s|")
        a.apply(.final("ございます"), segmentIdentity: "1s|2s|")
        check(a.committedText == "おはようございます")
        a.apply(.final("GitHub"))
        a.apply(.final("API"))
        check(a.committedText == "おはようございますGitHub API")
        a.apply(.interim("を使う"))
        check(a.displayText == "おはようございますGitHub APIを使う")
    }

    func recoveryRetainsUncommittedInstructions() {
        var assembler = TranscriptAssembler()
        assembler.apply(.final("GitHubのIssueを確認する。"))
        assembler.apply(.interim("続いてテストし、PRを作成する。"))
        check(assembler.committedText == "GitHubのIssueを確認する。")
        check(assembler.recoveryText == "GitHubのIssueを確認する。続いてテストし、PRを作成する。")
        assembler.apply(.interim("続いてテストし、PRを作成する。その後は停止。"))
        check(assembler.recoveryText == "GitHubのIssueを確認する。続いてテストし、PRを作成する。その後は停止。")
        assembler.apply(.final("続いてテストし、PRを作成する。その後は停止。"))
        check(assembler.recoveryText == assembler.committedText)
        check(assembler.interim.isEmpty)
    }

    func overlappingSegmentsDoNotEraseSpokenWords() {
        var a = TranscriptAssembler()
        a.apply(.final("今日は"))
        a.apply(.final("今日は晴れ"))
        // Shared text is not a cumulative-transcript contract or a segment ID.
        check(a.committedText == "今日は今日は晴れ")
    }

    func segmentAssemblyPreservesNumbersNamesAndNegations() {
        var a = TranscriptAssembler()
        for segment in ["GitHubのPRは", "123番、金額は", "30,000円ではありません。", "3,000円です。", "マージしないでください。"] {
            a.apply(.final(segment))
        }
        check(a.committedText == "GitHubのPRは123番、金額は30,000円ではありません。3,000円です。マージしないでください。")
    }

    func finalSegmentMetadataIsOptionalAndContentFree() {
        let raw = """
        {"serverContent":{"inputTranscription":{"text":"PRIVATE","startOffset":"0s","endOffset":"1.25s","finished":true}}}
        """
        check(GeminiWire.finalSegmentIdentity(raw) == "0s|1.25s|")
        check(GeminiWire.transcriptionFinished(raw))
        let noOffsets = """
        {"serverContent":{"inputTranscription":{"text":"PRIVATE"}}}
        """
        check(GeminiWire.finalSegmentIdentity(noOffsets) == nil)
        check(!GeminiWire.transcriptionFinished(noOffsets))
        let missingEnd = """
        {"serverContent":{"inputTranscription":{"startOffset":"0s"}}}
        """
        check(GeminiWire.finalSegmentIdentity(missingEnd) == nil)
        let emptyTerminal = """
        {"serverContent":{"inputTranscription":{"finished":true}}}
        """
        check(GeminiWire.transcriptionFinished(emptyTerminal))
        check(!GeminiWire.transcriptionFinished("garbled"))
    }

    func unknownFramesCanBeDiagnosedWithoutLeakingTheirText() {
        let raw = """
        {"serverContent":{"modelTurn":{"parts":[{"text":"PRIVATE"}]}}}
        """
        check(GeminiWire.frameKind(raw) == "serverContent.other")
        check(!GeminiWire.frameKind(raw).contains("PRIVATE"))
        check(GeminiWire.frameKind("{\"goAway\":{}}") == "goAway")
    }
}
