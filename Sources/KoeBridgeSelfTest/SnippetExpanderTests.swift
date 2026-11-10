import Foundation
import KoeBridgeCore

struct SnippetExpanderTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        return calendar
    }
    private var context: SnippetContext {
        SnippetContext(date: Date(timeIntervalSince1970: 0), clipboardText: "コピー {{DATE}}")
    }
    private func expand(_ text: String, _ rules: [SnippetRule]) -> String {
        SnippetExpander.expand(text, rules: rules, context: context, calendar: calendar)
    }
    func singleReplacement() {
        check(expand("hello sig", [.init(trigger: "sig", template: "署名")]) == "hello 署名")
    }
    func allOccurrences() {
        check(expand("sig sig", [.init(trigger: "sig", template: "署名")]) == "署名 署名")
    }
    func longestTriggerFirst() {
        check(expand("abc ab", [.init(trigger: "ab", template: "短"), .init(trigger: "abc", template: "長")]) == "長 短")
    }
    func equalLengthsKeepListOrder() {
        check(expand("ab", [.init(trigger: "ab", template: "cd"), .init(trigger: "cd", template: "終")]) == "終")
    }
    func dateAndTimeUseInjectedCalendar() {
        check(expand("x", [.init(trigger: "x", template: "{{DATE}} {{TIME}}")]) == "1970/01/01 09:00")
        var west = calendar
        west.timeZone = TimeZone(secondsFromGMT: -3600)!
        check(SnippetExpander.expand("x", rules: [.init(trigger: "x", template: "{{DATE}} {{TIME}}")], context: context, calendar: west) == "1969/12/31 23:00")
    }
    func clipboardPresentAndAbsent() {
        let rules = [SnippetRule(trigger: "x", template: "前{{CLIPBOARD}}後")]
        check(expand("x", rules) == "前コピー {{DATE}}後")
        check(SnippetExpander.expand("x", rules: rules, context: .init(date: context.date, clipboardText: nil)) == "前後")
    }
    func unknownTokenUntouched() {
        check(expand("x", [.init(trigger: "x", template: "{{UNKNOWN}}")]) == "{{UNKNOWN}}")
    }
    func emptyTriggerIgnored() {
        check(expand("a b", [.init(trigger: "", template: "bad"), .init(trigger: " \n", template: "bad")]) == "a b")
    }
    func noMatchPassthrough() {
        check(expand("unchanged", [.init(trigger: "x", template: "y")]) == "unchanged")
    }
    func clipboardOnlyNeededForExpandingTemplate() {
        let rules = [SnippetRule(trigger: "x", template: "{{CLIPBOARD}}")]
        check(!SnippetExpander.needsClipboard("none", rules: rules, date: context.date))
        check(SnippetExpander.needsClipboard("x", rules: rules, date: context.date))
        check(!SnippetExpander.needsClipboard("x", rules: [.init(trigger: " ", template: "{{CLIPBOARD}}")], date: context.date))
        check(SnippetExpander.needsClipboard("long", rules: [.init(trigger: "long", template: "x")] + rules, date: context.date))
    }
}
