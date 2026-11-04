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
        let r = try GeminiWire.parse("""
        {"serverContent":{"interimInputTranscription":{"text":"おは"},"inputTranscription":{"text":"おはよう"},"turnComplete":true}}
        """)
        #expect(r == [.interim("おは"), .final("おはよう"), .turnComplete])
    }

    @Test func setupComplete() throws {
        #expect(try GeminiWire.parse("{\"setupComplete\":{}}") == [.setupComplete])
    }

    @Test func assemblerJapaneseSegmentsAndEnglish() {
        var a = TranscriptAssembler()
        a.apply(.interim("おは"))
        #expect(a.displayText == "おは")
        a.apply(.final("おはよう"))
        a.apply(.final("ございます"))
        a.apply(.final("ございます"))
        #expect(a.committedText == "おはようございます")
        a.apply(.final("GitHub"))
        a.apply(.final("API"))
        #expect(a.committedText == "おはようございますGitHub API")
        a.apply(.interim("を使う"))
        #expect(a.displayText == "おはようございますGitHub APIを使う")
    }

    @Test func assemblerCumulativeFinal() {
        var a = TranscriptAssembler()
        a.apply(.final("今日は"))
        a.apply(.final("今日は晴れ"))
        #expect(a.committedText == "今日は晴れ")
    }

    @Test func diagnosticFrameKindOmitsContent() {
        let raw = "{\"serverContent\":{\"modelTurn\":{\"parts\":[{\"text\":\"PRIVATE\"}]}}}"
        #expect(GeminiWire.frameKind(raw) == "serverContent.other")
        #expect(!GeminiWire.frameKind(raw).contains("PRIVATE"))
        #expect(GeminiWire.frameKind("{\"goAway\":{}}") == "goAway")
    }
}
