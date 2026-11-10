import Foundation
import KoeBridgeCore

struct TranslationAndPresetTests {
    func translationDirectionAndInstructions() {
        for text in ["こんにちは", "カタカナ", "漢字", "Hello 日本", "ｶﾅ", "𠮷", "𛀁", "〇", "𚿰"] {
            check(TranslationPolicy.direction(for: text) == .jaToEn)
        }
        for text in ["", "Hello", "123 👩🏽‍💻", "café", "한국어"] {
            check(TranslationPolicy.direction(for: text) == .enToJa)
        }
        let english = TranslationPolicy.instruction(for: .jaToEn)
        let japanese = TranslationPolicy.instruction(for: .enToJa)
        check(english.contains("English"))
        check(japanese.contains("Japanese"))
        check(english.contains("preserving its meaning"))
        check(japanese.contains("Output ONLY the translation"))
        check(TranslationDirection(rawValue: "auto") == .auto)
        check(TransformMode(rawValue: "spoken") == .spoken)
    }

    func presetValidationAndRoundTrip() throws {
        check(!TransformPreset(name: "", steps: ["translate"]).isValid)
        check(!TransformPreset(name: " \n", steps: ["translate"]).isValid)
        check(!TransformPreset(name: "Example").isValid)
        check(!TransformPreset(name: "Example", steps: ["translate", " \n"]).isValid)
        check(!TransformPreset.validStep("\t"))
        check(TransformPreset.validName(" Example "))
        let preset = TransformPreset(name: "Example", steps: ["英語に翻訳して", "丁寧な文体にして"])
        check(preset.isValid)
        let decoded = try JSONDecoder().decode(TransformPreset.self, from: JSONEncoder().encode(preset))
        check(decoded == preset)
        check(decoded.id == preset.id)
        check(decoded.steps == ["英語に翻訳して", "丁寧な文体にして"])
        var changed = preset
        changed.steps.swapAt(0, 1)
        check(changed != preset)
        check(changed.id == preset.id)
    }
}
