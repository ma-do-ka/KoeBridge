import Foundation
import Testing
@testable import KoeBridgeCore

struct GeminiWireTests {
    @Test func setupAndAudioMatchGoogleWireFormat() throws {
        let setup = try GeminiWire.setup(vocabulary: ["GitHub", "n8n", "GitHub"], smart: false, japaneseHint: true)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(setup.utf8)) as? [String: Any])
        let dict = try #require(obj["setup"] as? [String: Any])
        #expect(dict["model"] as? String == "models/gemini-3.5-transcribe-live")
        let transcription = try #require(dict["inputAudioTranscription"] as? [String: Any])
        #expect(transcription["mode"] as? String == "VERBATIM")
        #expect(transcription["customVocabulary"] as? [String] == ["GitHub", "n8n"])
        let audio = try GeminiWire.audio(Data([0, 1, 255]))
        let wire = try #require(JSONSerialization.jsonObject(with: Data(audio.utf8)) as? [String: Any])
        let realtime = try #require(wire["realtimeInput"] as? [String: Any])
        let pcm = try #require(realtime["audio"] as? [String: Any])
        #expect(pcm["mimeType"] as? String == "audio/pcm;rate=16000")
        #expect(pcm["data"] as? String == "AAH/")
    }

    @Test func parseInterimFinalTurnComplete() throws {
        let events = try GeminiWire.parse("""
        {"serverContent":{"interimInputTranscription":{"text":"おは"},"inputTranscription":{"text":"おはよう"},"turnComplete":true}}
        """)
        #expect(events == [.interim("おは"), .final("おはよう"), .turnComplete])
    }

    @Test func setupComplete() throws {
        let events = try GeminiWire.parse("{\"setupComplete\":{}}")
        #expect(events == [.setupComplete])
    }

    @Test func assemblerJapaneseSegmentsAndEnglish() {
        var a = TranscriptAssembler()
        a.apply(.interim("おは"))
        #expect(a.displayText == "おは")
        a.apply(.final("おはよう"))
        a.apply(.final("ございます"), segmentIdentity: "1s|2s|")
        a.apply(.final("ございます"), segmentIdentity: "1s|2s|")
        #expect(a.committedText == "おはようございます")
        a.apply(.final("GitHub"))
        a.apply(.final("API"))
        #expect(a.committedText == "おはようございますGitHub API")
        a.apply(.interim("を使う"))
        #expect(a.displayText == "おはようございますGitHub APIを使う")
    }

    @Test func recoveryRetainsUncommittedInstructionsWithoutAutotypingThem() {
        var assembler = TranscriptAssembler()
        assembler.apply(.final("GitHubのIssueを確認する。"))
        assembler.apply(.interim("続いてテストし、PRを作成する。"))
        #expect(assembler.committedText == "GitHubのIssueを確認する。")
        #expect(assembler.recoveryText == "GitHubのIssueを確認する。続いてテストし、PRを作成する。")
        assembler.apply(.interim("続いてテストし、PRを作成する。その後は停止。"))
        #expect(assembler.recoveryText == "GitHubのIssueを確認する。続いてテストし、PRを作成する。その後は停止。")
        assembler.apply(.final("続いてテストし、PRを作成する。その後は停止。"))
        #expect(assembler.recoveryText == assembler.committedText)
        #expect(assembler.interim.isEmpty)
    }

    @Test func overlappingSegmentsDoNotEraseSpokenWords() {
        var a = TranscriptAssembler()
        a.apply(.final("今日は"))
        a.apply(.final("今日は晴れ"))
        // Shared text is not a cumulative-transcript contract or a segment ID.
        #expect(a.committedText == "今日は今日は晴れ")
    }

    @Test func segmentAssemblyPreservesNumbersNamesAndNegations() {
        var a = TranscriptAssembler()
        for segment in ["GitHubのPRは", "123番、金額は", "30,000円ではありません。", "3,000円です。", "マージしないでください。"] {
            a.apply(.final(segment))
        }
        #expect(a.committedText == "GitHubのPRは123番、金額は30,000円ではありません。3,000円です。マージしないでください。")
    }

    @Test func finalSegmentMetadataIsOptionalAndContentFree() {
        let raw = """
        {"serverContent":{"inputTranscription":{"text":"PRIVATE","startOffset":"0s","endOffset":"1.25s","finished":true}}}
        """
        #expect(GeminiWire.finalSegmentIdentity(raw) == "0s|1.25s|")
        #expect(GeminiWire.transcriptionFinished(raw))
        let noOffsets = """
        {"serverContent":{"inputTranscription":{"text":"PRIVATE"}}}
        """
        #expect(GeminiWire.finalSegmentIdentity(noOffsets) == nil)
        #expect(!GeminiWire.transcriptionFinished(noOffsets))
        let missingEnd = """
        {"serverContent":{"inputTranscription":{"startOffset":"0s"}}}
        """
        #expect(GeminiWire.finalSegmentIdentity(missingEnd) == nil)
        let emptyTerminal = """
        {"serverContent":{"inputTranscription":{"finished":true}}}
        """
        #expect(GeminiWire.transcriptionFinished(emptyTerminal))
        #expect(!GeminiWire.transcriptionFinished("garbled"))
    }

    @Test func diagnosticFrameKindOmitsContent() {
        let raw = """
        {"serverContent":{"modelTurn":{"parts":[{"text":"PRIVATE"}]}}}
        """
        #expect(GeminiWire.frameKind(raw) == "serverContent.other")
        #expect(!GeminiWire.frameKind(raw).contains("PRIVATE"))
        #expect(GeminiWire.frameKind("{\"goAway\":{}}") == "goAway")
    }
}
