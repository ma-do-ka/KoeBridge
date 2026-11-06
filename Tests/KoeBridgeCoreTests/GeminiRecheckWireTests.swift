import Foundation
import Testing
@testable import KoeBridgeCore

struct GeminiRecheckWireTests {
    @Test func waveHeaderAndSelectedVocabularyAreExact() throws {
        let pcm = Data([0, 1, 255, 127])
        let wave = try GeminiRecheckWire.wav(pcm16LE: pcm)
        #expect(wave.count == 48)
        #expect(String(data: wave.prefix(4), encoding: .ascii) == "RIFF")
        #expect(Array(wave[4..<8]) == [40, 0, 0, 0])
        #expect(Array(wave[22..<24]) == [1, 0])
        #expect(Array(wave[24..<28]) == [128, 62, 0, 0])
        #expect(wave.suffix(4) == pcm)
        let body = try GeminiRecheckWire.request(pcm16LE: pcm, vocabulary: [], style: .agent, japaneseHint: true)
        let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let generation = try #require(root["generationConfig"] as? [String: Any])
        let config = try #require(generation["audioTranscriptionConfig"] as? [String: Any])
        #expect(config["customVocabulary"] == nil)
        #expect(config["mode"] as? String == "VERBATIM")
        #expect(config["languageCodes"] as? [String] == ["ja-JP"])
        #expect(root["systemInstruction"] == nil)
    }

    @Test func noTruncationOrEmptyAudioRequests() {
        #expect(throws: GeminiRecheckWire.RecheckError.self) { try GeminiRecheckWire.wav(pcm16LE: Data()) }
        #expect(throws: GeminiRecheckWire.RecheckError.self) { try GeminiRecheckWire.wav(pcm16LE: Data([1])) }
        #expect(throws: GeminiRecheckWire.RecheckError.self) {
            try GeminiRecheckWire.wav(pcm16LE: Data(repeating: 0, count: GeminiRecheckWire.maximumPCMBytes + 2))
        }
    }

    @Test func onlyConfirmedSingleCandidateCanBeUsed() throws {
        let valid = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"途中の推論","thought":true},{"text":"設定します。"}]}}]}"#.utf8)
        #expect(try GeminiRecheckWire.response(valid) == "設定します。")
        for raw in [#"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"途中"}]}}]}"#,
                    #"{"candidates":[{"content":{"parts":[{"text":"未確定"}]}}]}"#,
                    #"{"candidates":[]}"#, #"{"error":{"message":"private content"}}"#] {
            #expect(throws: GeminiRecheckWire.RecheckError.self) { try GeminiRecheckWire.response(Data(raw.utf8)) }
        }
    }
}
