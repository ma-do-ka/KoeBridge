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
        let protected = ProtectedTextSpans(text)
        let source = text as NSString
        var edits: [(range: NSRange, replacement: String)] = []
        for (before, after) in joins {
            var search = NSRange(location: 0, length: source.length)
            while search.length > 0 {
                let found = source.range(of: before, options: [], range: search)
                guard found.location != NSNotFound else { break }
                if !protected.intersects(found) {
                    edits.append((found, after))
                }
                let end = NSMaxRange(found)
                search = NSRange(location: end, length: source.length - end)
            }
        }
        // The deleted punctuation positions are distinct. Phrases may share
        // a boundary character, which both replacements retain. Apply from the
        // end to preserve original UTF-16 offsets and inspect literals once.
        let output = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            output.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return Result(text: output as String, changes: edits.count)
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
        ProtectedTextSpans(text).contents
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
