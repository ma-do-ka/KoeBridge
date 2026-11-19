import Foundation

/// Adopt a finalized normal-dictation candidate. All ranges refer to its original UTF-16
/// offsets. Never call this on expanded snippets, clipboard contents or recovery text.
public enum JapaneseDictationSpacing {
    // Also include the hiragana and katakana iteration marks outside the measured ranges.
    private static let boundary = try! NSRegularExpression(
        pattern: #"(?<=[ぁ-ゖゝゞァ-ヺヽヾー々〆〇一-鿿㐀-䶿]) +(?=[ぁ-ゖゝゞァ-ヺヽヾー々〆〇一-鿿㐀-䶿、。])"#)

    // Shell arguments can be separate Japanese words. Preserve argument lists with
    // an explicit prompt, option, executable path or common bare command name.
    private static let literals = [
        #"(?m)(?:^[ \t]*(?:\$[ \t]+|(?:[./~][^\s]*|[a-z][a-z0-9_.-]*(?=[ \t]+[ぁ-ゖァ-ヺ一-鿿㐀-䶿])|cp|mv|ls|cd|mkdir|touch|echo|printf|cat|git|open|rm)[ \t]+)|(?<!\S)--?[A-Za-z][\w-]*(?=[= \t]))[^\r\n]*"#,
        // Markdown permits backticks inside a longer code delimiter, and tilde fences.
        #"(?<!\x60)(\x60{2,})(?!\x60)[\s\S]*?(?:(?<!\x60)\1(?!\x60)|\z)"#,
        #"(?m)^[ ]{0,3}(~{3,})[^\n]*\n[\s\S]*?(?:^[ ]{0,3}\1~*[ \t]*$|\z)"#,
        #"[零壱弐参拾佰阡萬]+"#,
        // An escaped delimiter inside a quoted argument does not close it.
        #""(?:\\[^\n]|[^"\\\n])*(?:"|$)|'(?:\\[^\n]|[^'\\\n])*(?:'|$)"#,
        #"(?<![^\s@。、「」『』<>"])[^\s@。、「」『』<>"]+@[^\s@。、「」『』<>"]+"#
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func adopt(_ text: String, enabled: Bool, protectedTerms: [String]) -> String {
        guard enabled, text.utf8.contains(0x20) else { return text }
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        let candidates = boundary.matches(in: text, range: full)
        guard !candidates.isEmpty else { return text }

        let protected = ProtectedTextSpans(text, additionalPatterns: literals)
        var termOffsets = IndexSet()
        // A literal trigger may overlap another occurrence, or include leading/trailing spaces.
        for term in Set(protectedTerms) where term.utf8.contains(0x20) {
            var start = 0
            while start < source.length {
                let match = source.range(of: term, options: .literal,
                    range: NSRange(location: start, length: source.length - start))
                guard match.location != NSNotFound else { break }
                termOffsets.insert(integersIn: match.location..<NSMaxRange(match))
                start = match.location + 1
            }
        }

        let result = NSMutableString(string: text)
        for match in candidates.reversed() {
            let gap = match.range
            // Both neighbours are BMP characters by construction. This preserves
            // number/unit and path boundaries even when the gap itself is unprotected.
            let neighbours = NSRange(location: gap.location - 1, length: gap.length + 2)
            if !protected.intersects(neighbours),
               !termOffsets.intersects(integersIn: gap.location..<NSMaxRange(gap)) {
                result.deleteCharacters(in: gap)
            }
        }
        return result as String
    }
}
