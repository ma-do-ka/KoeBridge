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

    /// Uses the same sequential replacement order as expansion, without reading a clipboard.
    public static func needsClipboard(_ text: String, rules: [SnippetRule], date: Date,
                                      calendar: Calendar = .current) -> Bool {
        var result = text
        for rule in ordered(rules) where result.range(of: rule.trigger, options: .literal) != nil {
            if rule.template.contains("{{CLIPBOARD}}") { return true }
            result = result.replacingOccurrences(of: rule.trigger, with: template(
                rule.template, context: SnippetContext(date: date, clipboardText: nil), calendar: calendar), options: .literal)
        }
        return false
    }

    public static func expand(_ text: String, rules: [SnippetRule], context: SnippetContext,
                              calendar: Calendar = .current) -> String {
        var result = text
        for rule in ordered(rules) where result.range(of: rule.trigger, options: .literal) != nil {
            result = result.replacingOccurrences(of: rule.trigger,
                with: template(rule.template, context: context, calendar: calendar), options: .literal)
        }
        return result
    }

    private static func template(_ text: String, context: SnippetContext, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: context.date)
        let values = ["DATE": String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
                      "TIME": String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0),
                      "CLIPBOARD": context.clipboardText ?? ""]
        // Replace only original template tokens: clipboard content is never interpreted as a token.
        var result = text
        for match in placeholderRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result),
                  let keyRange = Range(match.range(at: 1), in: text) else { continue }
            result.replaceSubrange(range, with: values[String(text[keyRange])] ?? "")
        }
        return result
    }
}
