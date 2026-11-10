import Foundation
import KoeBridgeCore

struct PostProcessingTests {
    func policyMatrix() {
        for mode in PostProcessingMode.allCases {
            for enabled in [false, true] {
                for style in TranscriptionStyle.allCases {
                    for transform in [false, true] {
                        for skipped in [false, true] {
                            for noInput in [false, true] {
                                let expected = enabled && mode != .off && style != .agent && !transform && !skipped && !noInput
                                check(PostProcessingPolicy.shouldApply(mode: mode, enabled: enabled, style: style,
                                    isTransform: transform, skipped: skipped, noInput: noInput) == expected)
                            }
                        }
                    }
                }
            }
        }
    }

    func lengthGuard() {
        for originalCount in [0, 1, 59, 60, 61, 200] {
            let original = String(repeating: "あ", count: originalCount)
            let limit = max(originalCount * 3, originalCount + 120)
            check(!PostProcessingPolicy.accepts(original: original, processed: ""))
            for count in [1, limit - 1, limit] {
                check(PostProcessingPolicy.accepts(original: original,
                    processed: String(repeating: "👩🏽‍💻", count: count)))
            }
            check(!PostProcessingPolicy.accepts(original: original,
                processed: String(repeating: "あ", count: limit + 1)))
        }
        let original = String(repeating: "e\u{301}", count: 61)
        check(PostProcessingPolicy.accepts(original: original, processed: String(repeating: "x", count: 183)))
        check(!PostProcessingPolicy.accepts(original: original, processed: String(repeating: "x", count: 184)))
    }

    func requestModes() throws {
        check(GeminiPostProcessWire.endpoint == GeminiTransformWire.endpoint)
        check(GeminiPostProcessWire.endpoint.contains("gemini-2.5-flash:generateContent"))
        let input = " 逐語\t" + String(repeating: "あ", count: 2_001)
        for mode in PostProcessingMode.allCases {
            let data = try GeminiPostProcessWire.request(text: input, mode: mode)
            let root = try require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let config = try require(root["generationConfig"] as? [String: Any])
            check(config["temperature"] as? Int == 0)
            let system = try require(root["systemInstruction"] as? [String: Any])
            let systemParts = try require(system["parts"] as? [[String: Any]])
            check(systemParts.first?["text"] as? String == GeminiPostProcessWire.systemInstruction(mode: mode))
            let contents = try require(root["contents"] as? [[String: Any]])
            check(contents.count == 1)
            check(contents.first?["role"] as? String == "user")
            let parts = try require(contents.first?["parts"] as? [[String: Any]])
            check(parts.count == 1)
            check(parts.first?["text"] as? String == input)
        }
        check(GeminiPostProcessWire.systemInstruction(mode: .tidy).contains("意味・語彙・文体は変えない"))
        check(GeminiPostProcessWire.systemInstruction(mode: .formal).contains("丁寧で整った文体"))
        check(GeminiPostProcessWire.systemInstruction(mode: .tidy) != GeminiPostProcessWire.systemInstruction(mode: .formal))
    }

    func responses() throws {
        let good = Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"secret","thought":true},{"text":"\r\n  \t整えた"},{"text":"文\t \r\n"}]}}]}"#.utf8)
        let parsed = try GeminiPostProcessWire.response(good)
        check(parsed == "  \t整えた文\t ")
        for empty in ["", " \t\r\n"] {
            let data = try JSONSerialization.data(withJSONObject: ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": empty]]]]]])
            let parsed = try GeminiPostProcessWire.response(data)
            check(parsed == nil)
        }
        for invalid in [
            #"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"partial"}]}}]}"#,
            #"{"candidates":[]}"#, #"{"error":{"message":"failed"}}"#, "garbage"
        ] {
            check((try? GeminiPostProcessWire.response(Data(invalid.utf8))) == nil)
        }
        check((try? GeminiPostProcessWire.response(Data(repeating: 0, count: GeminiRecheckWire.maximumResponseBytes + 1))) == nil)
    }
}
