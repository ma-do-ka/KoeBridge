import Foundation

public enum TranslationDirection: String, CaseIterable, Sendable {
    case auto, jaToEn, enToJa
}

public enum TranslationPolicy {
    /// Any Japanese script wins, including mixed-language selections.
    public static func direction(for text: String) -> TranslationDirection {
        let japanese = text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3005...0x3007, 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x1AFF0...0x1AFFF, 0x20000...0x2FA1F, 0x30000...0x323AF, 0x1B000...0x1B16F:
                return true
            default: return false
            }
        }
        return japanese ? .jaToEn : .enToJa
    }

    /// Resolve .auto with direction(for:) before calling this function.
    public static func instruction(for direction: TranslationDirection) -> String {
        let language = direction == .jaToEn ? "English" : "Japanese"
        return "Translate the selected text into \(language), preserving its meaning, tone, and formatting. Output ONLY the translation, without explanations or added content."
    }
}
