import Foundation

public struct SnippetRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var trigger: String
    public var template: String

    public init(id: UUID = UUID(), trigger: String, template: String) {
        self.id = id
        self.trigger = trigger
        self.template = template
    }
}

public struct SnippetContext: Equatable, Sendable {
    public var date: Date
    public var clipboardText: String?

    public init(date: Date, clipboardText: String?) {
        self.date = date
        self.clipboardText = clipboardText
    }
}

public enum SnippetExpander {
    private static let placeholderRegex = try! NSRegularExpression(pattern: #"\{\{(DATE|TIME|CLIPBOARD)\}\}"#)

    private static func ordered(_ rules: [SnippetRule]) -> [SnippetRule] {
        rules.enumerated()
            .filter { !$0.element.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                $0.element.trigger.count == $1.element.trigger.count
                    ? $0.offset < $1.offset : $0.element.trigger.count > $1.element.trigger.count
            }.map(\.element)
    }

    public struct Expansion {
        public let text: String
        public let budgetExhausted: Bool
    }

    // Limit every intermediate result, including a rendered clipboard template.
    // Larger original inputs may shrink or pass through without truncation.
    static let maximumBytes = 256 * 1024

    public static func needsClipboard(_ text: String, rules: [SnippetRule], date: Date,
                                      calendar: Calendar = .current) -> Bool {
        var needed = false
        _ = expand(text, rules: rules, date: date, calendar: calendar, maximumBytes: maximumBytes) {
            needed = true
            return nil
        }
        return needed
    }

    public static func expand(_ text: String, rules: [SnippetRule], context: SnippetContext,
                              calendar: Calendar = .current) -> String {
        expand(text, rules: rules, date: context.date, calendar: calendar, maximumBytes: maximumBytes) {
            context.clipboardText
        }.text
    }

    /// Read the pasteboard once, only if a reached template asks for it.
    public static func expansion(_ text: String, rules: [SnippetRule], date: Date,
                                 clipboard: () -> String?) -> Expansion {
        var read = false
        var value: String?
        return expand(text, rules: rules, date: date, calendar: .current, maximumBytes: maximumBytes) {
            if !read { value = clipboard(); read = true }
            return value
        }
    }

    static func expand(_ text: String, rules: [SnippetRule], date: Date, calendar: Calendar,
                       maximumBytes: Int, clipboard: () -> String?) -> Expansion {
        let limit = max(text.utf8.count, maximumBytes)
        var result = text
        for rule in ordered(rules) {
            // Character equality is the same canonical equivalence as Set<String>.
            var remainder = result[...]
            guard var match = remainder.firstRange(of: rule.trigger) else { continue }
            guard let replacement = template(rule.template, date: date, calendar: calendar,
                                             limit: limit, clipboard: clipboard) else {
                return Expansion(text: result, budgetExhausted: true)
            }
            var next = ""
            while true {
                guard append(remainder[..<match.lowerBound], to: &next, limit: limit),
                      append(replacement, to: &next, limit: limit) else {
                    return Expansion(text: result, budgetExhausted: true)
                }
                remainder = remainder[match.upperBound...]
                guard let found = remainder.firstRange(of: rule.trigger) else { break }
                match = found
            }
            guard append(remainder, to: &next, limit: limit) else {
                return Expansion(text: result, budgetExhausted: true)
            }
            result = next
        }
        return Expansion(text: result, budgetExhausted: false)
    }

    private static func append(_ part: some StringProtocol, to result: inout String, limit: Int) -> Bool {
        guard part.utf8.count <= limit - result.utf8.count else { return false }
        result.append(contentsOf: part)
        return true
    }

    private static func template(_ text: String, date: Date, calendar: Calendar, limit: Int,
                                 clipboard: () -> String?) -> String? {
        let source = text as NSString
        var start = 0
        var result = ""
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        while let match = placeholderRegex.firstMatch(in: text,
                    range: NSRange(location: start, length: source.length - start)) {
            let prefix = NSRange(location: start, length: match.range.location - start)
            guard append(source.substring(with: prefix), to: &result, limit: limit) else { return nil }
            let value: String
            switch source.substring(with: match.range(at: 1)) {
            case "DATE": value = String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            case "TIME": value = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            default: value = clipboard() ?? ""
            }
            guard append(value, to: &result, limit: limit) else { return nil }
            start = NSMaxRange(match.range)
        }
        guard append(source.substring(from: start), to: &result, limit: limit) else { return nil }
        return result
    }
}
