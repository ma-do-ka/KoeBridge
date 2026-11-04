import Foundation
import Testing
@testable import KoeBridgeCore

struct GeminiFailureTests {
    @Test func liveAPIErrorReported() throws {
        let parsed = try GeminiWire.parse("""
            {"error":{"code":429,"message":"RESOURCE_EXHAUSTED"}}
            """)
        #expect(parsed == [.error("RESOURCE_EXHAUSTED")])
    }

    @Test func liveAPIUnknownMessageIsIgnored() throws {
        #expect(try GeminiWire.parse("""
            {"serverContent":{"waitingForInput":true},"sessionResumptionUpdate":{"newHandle":"test"}}
            """).isEmpty)
    }

    @Test func missingServerTextDoesNotCrash() throws {
        let parsed = try GeminiWire.parse("""
            {"serverContent":{"inputTranscription":{},"interimInputTranscription":{}}}
            """)
        #expect(parsed.isEmpty)
    }

    @Test func emptyInputIsError() {
        #expect(throws: WireError.self) { _ = try GeminiWire.parse("not JSON") }
    }

    @Test func manualVADStartAndEndAreRealJSON() throws {
        for value in [try GeminiWire.activityStart(), try GeminiWire.activityEnd()] {
            let obj = try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
            #expect(obj["realtimeInput"] != nil)
        }
    }

    @Test func hybridVADUsesAutomaticDetectionAndAudioStreamEnd() throws {
        let setup = try GeminiWire.setup(vocabulary: [], smart: false, japaneseHint: true)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(setup.utf8)) as? [String: Any])
        let dict = try #require(obj["setup"] as? [String: Any])
        #expect(dict["realtimeInputConfig"] == nil)
        let end = try GeminiWire.audioStreamEnd()
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(end.utf8)) as? [String: Any])
        let input = try #require(parsed["realtimeInput"] as? [String: Any])
        #expect(input["audioStreamEnd"] as? Bool == true)
    }

    @Test func largeVocabularyIsCappedAtOneHundred() throws {
        let values = (0..<400).map { "term\($0)" }
        let setup = try GeminiWire.setup(vocabulary: values, smart: false, japaneseHint: true)
        let obj = try #require(JSONSerialization.jsonObject(with: Data(setup.utf8)) as? [String: Any])
        let outer = try #require(obj["setup"] as? [String: Any])
        let config = try #require(outer["inputAudioTranscription"] as? [String: Any])
        #expect((config["customVocabulary"] as? [String])?.count == 100)
    }
}
