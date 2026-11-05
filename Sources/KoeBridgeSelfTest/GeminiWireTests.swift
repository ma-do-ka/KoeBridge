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
        let r = try GeminiWire.parse("""
        {"serverContent":{"interimInputTranscription":{"text":"おは"},"inputTranscription":{"text":"おはよう"},"turnComplete":true}}
        """)
        check(r == [.interim("おは"), .final("おはよう"), .turnComplete])
    }

    func setupComplete() throws {
        try check(try GeminiWire.parse("{\"setupComplete\":{}}") == [.setupComplete])
    }

    func assemblerJapaneseSegmentsAndEnglish() {
        var a = TranscriptAssembler()
        a.apply(.interim("おは"))
        check(a.displayText == "おは")
        a.apply(.final("おはよう"))
        a.apply(.final("ございます"))
        a.apply(.final("ございます"))
        check(a.committedText == "おはようございます")
        a.apply(.final("GitHub"))
        a.apply(.final("API"))
        check(a.committedText == "おはようございますGitHub API")
        a.apply(.interim("を使う"))
        check(a.displayText == "おはようございますGitHub APIを使う")
    }

    func recoveryRetainsUncommittedInstructions() {
        var a = TranscriptAssembler()
        a.apply(.final("GitHubを確認。"))
        a.apply(.interim("テストを実行してPRを作成。"))
        check(a.committedText == "GitHubを確認。")
        check(a.recoveryText == "GitHubを確認。テストを実行してPRを作成。")
        a.apply(.interim("GitHubを確認。テストを実行してPRを作成。"))
        check(a.recoveryText == "GitHubを確認。テストを実行してPRを作成。")
    }

    func assemblerCumulativeFinal() {
        var a = TranscriptAssembler()
        a.apply(.final("今日は"))
        a.apply(.final("今日は晴れ"))
        check(a.committedText == "今日は晴れ")
    }

    func unknownFramesCanBeDiagnosedWithoutLeakingTheirText() {
        let unexpected = "{\"serverContent\":{\"modelTurn\":{\"parts\":[{\"text\":\"PRIVATE\"}]}}}"
        check(GeminiWire.frameKind(unexpected) == "serverContent.other")
        check(GeminiWire.frameKind("{\"goAway\":{}}") == "goAway")
        check(GeminiWire.frameKind("garbled") == "invalid_json")
        check(GeminiWire.frameKind(unexpected).contains("PRIVATE") == false)
    }
}
