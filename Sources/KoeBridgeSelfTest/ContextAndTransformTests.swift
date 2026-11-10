import Foundation
import KoeBridgeCore

struct ContextAndTransformTests {
    func contextCapsPreserveStartAndUnicode() {
        check(ContextTextPolicy.selected("").isEmpty)
        check(ContextTextPolicy.selected("abc") == "abc")
        let long = String(repeating: "あ", count: 2_001)
        check(ContextTextPolicy.selected(long) == String(repeating: "あ", count: 2_000))
        let emoji = String(repeating: "👩🏽‍💻", count: 2_100)
        check(ContextTextPolicy.selected(emoji).count == 2_000)
        check(ContextTextPolicy.surrounding(long, selection: nil).count == 2_000)
        let text = String(repeating: "a", count: 5_000) + "CARET" + String(repeating: "b", count: 5_000)
        let window = ContextTextPolicy.surrounding(text, selection: .init(location: 5_000, length: 0))
        check(window.count == 2_000)
        check(window.hasPrefix(String(repeating: "a", count: 1_000)))
        check(window.contains("CARET"))
        check(ContextTextPolicy.surrounding(text, selection: .init(location: 99_999, length: 0)) == ContextTextPolicy.selected(text))
        check(ContextTextPolicy.surrounding(text, selection: .init(location: 0, length: 3)) == ContextTextPolicy.selected(text))
        check(ContextTextPolicy.surrounding(emoji, selection: .init(location: 7_001, length: 0)).count <= 2_000)
    }

    func recheckContextIsOptionalAdditionalPart() throws {
        let pcm = Data([0, 1])
        let baseline = try GeminiRecheckWire.request(pcm16LE: pcm, vocabulary: [], style: .agent, japaneseHint: true)
        let absent = try GeminiRecheckWire.request(pcm16LE: pcm, vocabulary: [], style: .agent, japaneseHint: true, context: nil)
        check(baseline == absent)
        let root = try require(JSONSerialization.jsonObject(with: baseline) as? [String: Any])
        let contents = try require(root["contents"] as? [[String: Any]])
        let original = try require(contents.first?["parts"] as? [[String: Any]])
        check(original.count == 1)
        let injected = try GeminiRecheckWire.request(pcm16LE: pcm, vocabulary: [], style: .agent, japaneseHint: true, context: "選択テキスト: KoeBridge")
        let nextRoot = try require(JSONSerialization.jsonObject(with: injected) as? [String: Any])
        let nextContents = try require(nextRoot["contents"] as? [[String: Any]])
        let parts = try require(nextContents.first?["parts"] as? [[String: Any]])
        check(parts.count == 2)
        check(NSDictionary(dictionary: original[0]).isEqual(to: parts[0]))
        let context = try require(parts.last?["text"] as? String)
        check(context.contains("背景文脈"))
        check(context.contains("選択テキスト: KoeBridge"))
    }

    func transformRequestAndResponse() throws {
        let body = try GeminiTransformWire.request(systemInstruction: "SYSTEM", selectedText: "選択", instruction: "英語にして")
        let root = try require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let system = try require(root["systemInstruction"] as? [String: Any])
        let systemParts = try require(system["parts"] as? [[String: Any]])
        check(systemParts.first?["text"] as? String == "SYSTEM")
        let contents = try require(root["contents"] as? [[String: Any]])
        let parts = try require(contents.first?["parts"] as? [[String: Any]])
        check(parts.count == 2)
        check((parts[0]["text"] as? String)?.hasSuffix("選択") == true)
        check((parts[1]["text"] as? String)?.hasSuffix("英語にして") == true)
        let good = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"private thought","thought":true},{"text":" rewritten "}]}}]}"#.utf8)
        check(try GeminiTransformWire.response(good) == "rewritten")
        for invalid in [
            #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":" "}]}}]}"#,
            #"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"partial"}]}}]}"#,
            #"{"candidates":[]}"#, #"{"error":{"message":"failed"}}"#, "garbage"
        ] {
            do {
                _ = try GeminiTransformWire.response(Data(invalid.utf8))
                check(false)
            } catch { check(true) }
        }
        do {
            _ = try GeminiTransformWire.response(Data(repeating: 0, count: GeminiRecheckWire.maximumResponseBytes + 1))
            check(false)
        } catch { check(true) }
    }
}
