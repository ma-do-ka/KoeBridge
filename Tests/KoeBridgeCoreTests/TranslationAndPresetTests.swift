import Foundation
import Testing
@testable import KoeBridgeCore

struct TranslationAndPresetTests {
    @Test func translationDirectionAndInstructions() {
        for text in ["こんにちは", "カタカナ", "漢字", "Hello 日本", "ｶﾅ", "𠮷", "𛀁", "〇", "𚿰"] {
            #expect(TranslationPolicy.direction(for: text) == .jaToEn)
        }
        for text in ["", "Hello", "123 👩🏽‍💻", "café", "한국어"] {
            #expect(TranslationPolicy.direction(for: text) == .enToJa)
        }
        let english = TranslationPolicy.instruction(for: .jaToEn)
        let japanese = TranslationPolicy.instruction(for: .enToJa)
        #expect(english.contains("English"))
        #expect(japanese.contains("Japanese"))
        #expect(english.contains("preserving its meaning"))
        #expect(japanese.contains("Output ONLY the translation"))
        #expect(TranslationDirection(rawValue: "auto") == .auto)
        #expect(TransformMode(rawValue: "spoken") == .spoken)
    }

    @Test func presetValidationAndRoundTrip() throws {
        #expect(!TransformPreset(name: "", steps: ["translate"]).isValid)
        #expect(!TransformPreset(name: " \n", steps: ["translate"]).isValid)
        #expect(!TransformPreset(name: "Example").isValid)
        #expect(!TransformPreset(name: "Example", steps: ["translate", " \n"]).isValid)
        #expect(!TransformPreset.validStep("\t"))
        #expect(TransformPreset.validName(" Example "))
        let preset = TransformPreset(name: "Example", steps: ["英語に翻訳して", "丁寧な文体にして"])
        #expect(preset.isValid)
        let decoded = try JSONDecoder().decode(TransformPreset.self, from: JSONEncoder().encode(preset))
        #expect(decoded == preset)
        #expect(decoded.id == preset.id)
        #expect(decoded.steps == ["英語に翻訳して", "丁寧な文体にして"])
        var changed = preset
        changed.steps.swapAt(0, 1)
        #expect(changed != preset)
        #expect(changed.id == preset.id)
    }
}
