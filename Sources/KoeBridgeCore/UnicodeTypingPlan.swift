import Foundation

/// Clipboard-free Unicode key events must never split a grapheme cluster.
public enum UnicodeTypingPlan {
    /// Literal newlines and tabs can submit a chat message or change focus.
    /// Automatic typing uses spaces; the history retains the original text.
    public static func safeText(_ text: String) -> String {
        var output = ""
        for c in text.unicodeScalars {
            switch c.value {
            case 0x09, 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
                if !output.hasSuffix(" ") { output.append(" ") }
            case 0x00...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F:
                continue
            default:
                output.unicodeScalars.append(c)
            }
        }
        return output
    }

    public static func chunks(_ original: String, maximumUTF16Units: Int = 16) -> [String] {
        precondition(maximumUTF16Units > 0)
        var result: [String] = []
        var current = ""
        var unitsInCurrent = 0
        for character in safeText(original) {
            let part = String(character)
            let count = part.utf16.count
            if !current.isEmpty && unitsInCurrent + count > maximumUTF16Units {
                result.append(current)
                current = ""
                unitsInCurrent = 0
            }
            current.append(character)
            unitsInCurrent += count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
