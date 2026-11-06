import Foundation

/// One immutable UTF-16 index over the original transcript. Formatting plans
/// all edits against this index before changing the text, so literal boundaries
/// never move halfway through a pass. No document context is collected.
struct ProtectedTextSpans {
    private let text: String
    private let ranges: [NSRange]

    func intersects(_ range: NSRange) -> Bool {
        ranges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    func containsInterior(_ offset: Int) -> Bool {
        ranges.contains { $0.location < offset && offset < NSMaxRange($0) }
    }

    var contents: [Data] {
        let source = text as NSString
        return ranges.map { Data(source.substring(with: $0).utf8) }
    }

    init(_ text: String) {
        // Quote bodies include punctuation/whitespace verbatim. ASCII runs
        // protect URLs, paths, flags, decimals, signs, IDs and English tokens;
        // token boundaries also prevent "foo bar" -> "foobar" acceptance.
        let patterns = [
            #"```[\s\S]*?(?:```|$)"#,
            #"`[^`\n]*(?:`|\n|$)"#,
            #"「[^」]*(?:」|$)|『[^』]*(?:』|$)"#,
            #"“[^”]*(?:”|$)|‘[^’]*(?:’|$)"#,
            #""[^"\n]*(?:"|\n|$)|'[^'\n]*(?:'|\n|$)"#,
            // URLs may contain Japanese punctuation. A path with an extension
            // ends at that extension, even when a Japanese particle follows it;
            // otherwise an unspaced paragraph would all become protected text.
            #"(?:[A-Za-z][A-Za-z0-9+.-]*://|www\.)[^\s<>"'「」『』“”‘’`]+"#,
            #"(?:[^\s。、<>"'「」『』“”‘’`/\\]*[/\\])+[^\s<>"'「」『』“”‘’`/\\]*?\.[A-Za-z0-9]{1,12}(?:\.[A-Za-z0-9]{1,12})*(?![A-Za-z0-9_.])"#,
            #"[^\s。、<>"'「」『』“”‘’`/\\]*[/\\][^\s。、<>"'「」『』“”‘’`]*"#,
            #"[^\s、<>"'「」『』“”‘’`/\\]+?\.[A-Za-z0-9]{1,12}(?:\.[A-Za-z0-9]{1,12})*(?![A-Za-z0-9_.])"#,
            #"[\p{N}〇一二三四五六七八九十百千万億兆]+|[!-~]+"#
        ]
        let fullRange = NSRange(text.startIndex..., in: text)
        // Match each family independently: a broad path token before a URL
        // must not hide the URL's longer, more specific protected span.
        let ranges = patterns.flatMap { pattern -> [NSRange] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: fullRange).map(\.range)
        }.sorted { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, range.location < NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        self.text = text
        self.ranges = merged
    }
}
