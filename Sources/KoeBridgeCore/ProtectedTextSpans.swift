import Foundation

/// Match whole delimiters so shorter runs inside longer ones stay literal.
enum CodeFences {
    // Markdown fences start on their own line, indented by at most three spaces.
    // Inside a fence, only a closing line with the same marker (at least as
    // long) counts. Inline backticks and fence-like code strings are data.
    private static let delimiterLine = try! NSRegularExpression(
        pattern: #"(?m)^ {0,3}(\x60{3,}|~{3,})([^\r\n]*)"#)

    static func ranges(in text: String) -> [NSRange] {
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        var opening: NSRange?
        var ranges: [NSRange] = []
        for line in delimiterLine.matches(in: text, range: full) {
            let run = line.range(at: 1)
            let marker = source.character(at: run.location)
            let suffix = source.substring(with: line.range(at: 2))
            if let start = opening {
                if marker == source.character(at: start.location), run.length >= start.length,
                   suffix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    ranges.append(NSRange(location: start.location, length: NSMaxRange(run) - start.location))
                    opening = nil
                }
            } else if marker != 0x60 || !suffix.utf8.contains(0x60) {
                opening = run
            }
        }
        if let start = opening { ranges.append(NSRange(location: start.location, length: full.length - start.location)) }
        return ranges
    }

    static func segments(in text: String) -> [Data] {
        let source = text as NSString
        return ranges(in: text).map { Data(source.substring(with: $0).utf8) }
    }
}

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

    private static let inlineCode = try! NSRegularExpression(pattern:
        #"(?<!\x60)(\x60{2,})(?!\x60)[\s\S]*?(?:(?<!\x60)\1(?!\x60)|\z)|\x60[^\x60\n]*(?:\x60|\n|\z)"#)

    private static func quoteRanges(in text: String) -> [NSRange] {
        // Track each delimiter family independently, as the original protections
        // can overlap (e.g. an unmatched quotation inside a command).
        let scalars = text.unicodeScalars
        let word = CharacterSet.alphanumerics.union(.nonBaseCharacters)
        let pairs: [(Unicode.Scalar, Unicode.Scalar)] = [("「", "」"), ("『", "』"), ("“", "”"),
                                                         ("‘", "’"), ("'", "'"), ("\"", "\"")]
        var ranges: [NSRange] = []
        for (open, close) in pairs where scalars.contains(open) {
            var start = 0, depth = 0, offset = 0
            var previousIsWord = false, escaped = false
            let singleLine = open == close
            for index in scalars.indices {
                let ch = scalars[index]
                let end = offset + ch.utf16.count
                let next = scalars.index(after: index)
                let internalApostrophe = (ch == "'" || ch == "’") && previousIsWord &&
                    next < scalars.endIndex && word.contains(scalars[next])
                if singleLine && ch == "\n" && depth > 0 {
                    ranges.append(NSRange(location: start, length: end - start))
                    depth = 0
                } else if !internalApostrophe && !escaped {
                    if depth > 0 && ch == close {
                        depth -= 1
                        if depth == 0 { ranges.append(NSRange(location: start, length: end - start)) }
                    } else if ch == open {
                        if depth == 0 { start = offset }
                        depth += 1
                    }
                }
                escaped = singleLine && depth > 0 && ch == "\\" && !escaped
                previousIsWord = word.contains(ch)
                offset = end
            }
            if depth > 0 { ranges.append(NSRange(location: start, length: offset - start)) }
        }
        return ranges
    }

    init(_ text: String, additionalPatterns: [NSRegularExpression] = []) {
        // Quote bodies include punctuation/whitespace verbatim. ASCII runs
        // protect URLs, paths, flags, decimals, signs, IDs and English tokens;
        // token boundaries also prevent "foo bar" -> "foobar" acceptance.
        var patterns = [
            #"[\p{N}〇一二三四五六七八九十百千万億兆]+|[!-~]+"#
        ]
        // Every path/URL pattern requires a slash, backslash or period. Skip
        // their unanchored searches through long uninterrupted Japanese phrases.
        if text.utf8.contains(where: { $0 == 0x2f || $0 == 0x5c || $0 == 0x2e }) {
            patterns += [
                // URLs may contain Japanese punctuation. A path with an extension
                // ends at that extension, even when a Japanese particle follows it;
                // otherwise an unspaced paragraph would all become protected text.
                #"(?:[A-Za-z][A-Za-z0-9+.-]*://|www\.)[^\s<>"'「」『』“”‘’`]+"#,
                #"(?:[^\s。、<>"'「」『』“”‘’`/\\]*[/\\])+[^\s<>"'「」『』“”‘’`/\\]*?\.[A-Za-z0-9]{1,12}(?:\.[A-Za-z0-9]{1,12})*(?![A-Za-z0-9_.])"#,
                #"[^\s。、<>"'「」『』“”‘’`/\\]*[/\\][^\s。、<>"'「」『』“”‘’`]*"#,
                #"[^\s、<>"'「」『』“”‘’`/\\]+?\.[A-Za-z0-9]{1,12}(?:\.[A-Za-z0-9]{1,12})*(?![A-Za-z0-9_.])"#
            ]
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        // Match each family independently: a broad path token before a URL
        // must not hide the URL's longer, more specific protected span.
        var ranges = patterns.flatMap { pattern -> [NSRange] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: fullRange).map(\.range)
        }
        let fences = CodeFences.ranges(in: text)
        ranges += fences
        // Inline code may have variable-length delimiters. Do not interpret an
        // unmatched delimiter inside a fenced block as the start of a new span.
        var start = 0
        for fence in fences + [NSRange(location: fullRange.length, length: 0)] {
            let gap = NSRange(location: start, length: fence.location - start)
            ranges += Self.inlineCode.matches(in: text, range: gap).map(\.range)
            start = NSMaxRange(fence)
        }
        ranges += Self.quoteRanges(in: text)
        for regex in additionalPatterns {
            ranges.append(contentsOf: regex.matches(in: text, range: fullRange).map(\.range))
        }
        ranges.sort { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }
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
