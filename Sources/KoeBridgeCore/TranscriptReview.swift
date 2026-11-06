import Foundation

/// Review belongs to one recording. It never includes another app's text.
public struct TranscriptReview: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case checked, incomplete, needsReview
    }
    public let status: Status
    public let note: String
    public let originalText: String?
    public let alternativeText: String?

    public init(status: Status, note: String, originalText: String? = nil,
                alternativeText: String? = nil) {
        self.status = status
        self.note = note
        self.originalText = originalText
        self.alternativeText = alternativeText
    }
}

/// A deliberately small local check. No sentence completion, word deletion,
/// spelling substitution, context harvesting, or additional model request.
public enum TextContextChecking {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let changes: Int
    }

    // Only boundaries inside these explicit Japanese connective phrases are
    // joined. A general "particle + pause" heuristic also joins real sentences.
    private static let joins = [
        ("という。こと", "ということ"),
        ("という。もの", "というもの"),
        ("について。は", "については"),
        ("について。の", "についての"),
        ("に関して。は", "に関しては"),
        ("に関して。の", "に関しての"),
        ("として。は", "としては")
    ]

    public static func check(_ text: String) -> Result {
        var output = text
        var count = 0
        for (before, after) in joins {
            // Recompute after each edit; all indices remain UTF-16 based.
            let protected = protectedRanges(in: output)
            let source = output as NSString
            var matches: [NSRange] = []
            var search = NSRange(location: 0, length: source.length)
            while search.length > 0 {
                let found = source.range(of: before, options: [], range: search)
                guard found.location != NSNotFound else { break }
                if !protected.contains(where: { NSIntersectionRange($0, found).length > 0 }) {
                    matches.append(found)
                }
                let end = NSMaxRange(found)
                search = NSRange(location: end, length: source.length - end)
            }
            let edited = NSMutableString(string: output)
            for range in matches.reversed() { edited.replaceCharacters(in: range, with: after) }
            count += matches.count
            output = edited as String
        }
        return Result(text: output, changes: count)
    }

    public static func isSuspicious(_ text: String) -> Bool {
        if check(text).changes > 0 { return true }
        return text.contains("。。") || text.contains("、、") || text.contains("\u{FFFD}")
    }

    /// Only Japanese sentence punctuation and whitespace may differ, and
    /// technical/quoted spans must be byte-for-byte identical. This is not a
    /// general semantic equivalence test: any lexical disagreement is review-only.
    public static func hasMatchingWords(original: String, candidate: String) -> Bool {
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard protectedText(in: original) == protectedText(in: candidate) else { return false }
        return signature(original).utf8.elementsEqual(signature(candidate).utf8)
    }

    public struct Comparison: Equatable, Sendable {
        public let text: String
        public let requiresReview: Bool
    }

    /// A second ASR result is evidence for comparison, never an implicit
    /// activation of the separate punctuation-editing preference.
    public static func compare(original: String, candidate: String,
                               textCheckEnabled: Bool) -> Comparison {
        guard hasMatchingWords(original: original, candidate: candidate) else {
            return Comparison(text: original, requiresReview: true)
        }
        return Comparison(text: textCheckEnabled ? check(original).text : original,
                          requiresReview: false)
    }

    private static func signature(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            $0 != "。" && $0 != "、" && !CharacterSet.whitespacesAndNewlines.contains($0)
        })
    }

    private static func protectedText(in text: String) -> [Data] {
        let source = text as NSString
        return protectedRanges(in: text).map { Data(source.substring(with: $0).utf8) }
    }

    private static func protectedRanges(in text: String) -> [NSRange] {
        // Quote bodies include punctuation/whitespace verbatim. ASCII runs
        // protect URLs, paths, flags, decimals, signs, IDs and English tokens;
        // token boundaries also prevent "foo bar" -> "foobar" acceptance.
        let pattern = [
            #"```[\s\S]*?(?:```|$)"#,
            #"`[^`\n]*(?:`|\n|$)"#,
            #"「[^」]*(?:」|$)|『[^』]*(?:』|$)"#,
            #"“[^”]*(?:”|$)|‘[^’]*(?:’|$)"#,
            #""[^"\n]*(?:"|\n|$)|'[^'\n]*(?:'|\n|$)"#,
            // Protect the complete Unicode token around a URL/path separator,
            // including Japanese punctuation that can be a real filename byte.
            #"[^\s<>"'「」『』“”‘’`]*[/\\][^\s<>"'「」『』“”‘’`]*"#,
            #"[^\s<>"'「」『』“”‘’`]+\.[A-Za-z0-9]{1,12}\b"#,
            #"[\p{N}〇一二三四五六七八九十百千万億兆]+|[!-~]+"#
        ].joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }
}

public enum TranscriptReviewDeadline {
    public static let totalSeconds: TimeInterval = 15
    public static let maximumReviewSeconds: TimeInterval = 6

    public static func available(stoppedAt: Date?, now: Date) -> TimeInterval {
        guard let stoppedAt else { return 0 }
        let remaining = totalSeconds - now.timeIntervalSince(stoppedAt) - 0.25
        return remaining >= 0.5 ? min(maximumReviewSeconds, remaining) : 0
    }
}
