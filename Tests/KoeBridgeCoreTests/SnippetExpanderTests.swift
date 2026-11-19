import Foundation
import Testing
@testable import KoeBridgeCore

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
    @Test func canonicalSearchMatchesSegmentDeduplication() {
        let forms = ["が", "か\u{3099}", "ガ", "ｶﾞ", "é", "e\u{301}", "É", "e", "A", "Ａ", "a", "각", "각", "\u{1109A}", "\u{11099}\u{110BA}"]
        for lhs in forms {
            for rhs in forms {
                let a = "用語" + lhs + " 登録 語", b = "用語" + rhs + " 登録 語"
                var transcript = TranscriptAssembler()
                transcript.apply(.final(a), segmentIdentity: "id")
                transcript.apply(.final(b), segmentIdentity: "id")
                let deduplicated = transcript.finalCount == 1
                #expect(deduplicated == (a == b))
                #expect((expand(a, [.init(trigger: b, template: "!")]) == "!") == deduplicated)
                #expect((JapaneseDictationSpacing.adopt(a, enabled: true, protectedTerms: [b]) == a) == deduplicated)
            }
        }
    }

    @Test func boundedSequentialChainsCommitOnlyWholeRules() {
        let cases: [([SnippetRule], String, Bool)] = [
            ([.init(trigger: "a", template: "aa"), .init(trigger: "a", template: "aaa")], "aa", true),
            ([.init(trigger: "a", template: "bb"), .init(trigger: "b", template: "aaa")], "bb", true),
            ([.init(trigger: "a", template: "bb"), .init(trigger: "b", template: "aa")], "aaaa", false),
            ([.init(trigger: "a", template: "{{CLIPBOARD}}{{CLIPBOARD}}")], "a", true)
        ]
        for (rules, expected, exhausted) in cases {
            let result = SnippetExpander.expand("a", rules: rules, date: context.date, calendar: calendar,
                                                maximumBytes: 4) { "語" }
            #expect(result.text == expected)
            #expect(result.budgetExhausted == exhausted)
            #expect(result.text.utf8.count <= 4)
        }
        var reads = 0
        let rules = [SnippetRule(trigger: "a", template: String(repeating: "x", count: 262_145)),
                     SnippetRule(trigger: "a", template: "{{CLIPBOARD}}")]
        let partial = SnippetExpander.expansion("a", rules: rules, date: context.date) { reads += 1; return "x" }
        #expect(partial.budgetExhausted && partial.text == "a" && reads == 0)
        #expect(!SnippetExpander.needsClipboard("a", rules: rules, date: context.date))
    }

    @Test func singleReplacement() {
        #expect(expand("hello sig", [.init(trigger: "sig", template: "署名")]) == "hello 署名")
    }
    @Test func allOccurrences() {
        #expect(expand("sig sig", [.init(trigger: "sig", template: "署名")]) == "署名 署名")
    }
    @Test func longestTriggerFirst() {
        #expect(expand("abc ab", [.init(trigger: "ab", template: "短"), .init(trigger: "abc", template: "長")]) == "長 短")
    }
    @Test func equalLengthsKeepListOrder() {
        #expect(expand("ab", [.init(trigger: "ab", template: "cd"), .init(trigger: "cd", template: "終")]) == "終")
    }
    @Test func dateAndTimeUseInjectedCalendar() {
        #expect(expand("x", [.init(trigger: "x", template: "{{DATE}} {{TIME}}")]) == "1970/01/01 09:00")
        var west = calendar
        west.timeZone = TimeZone(secondsFromGMT: -3600)!
        #expect(SnippetExpander.expand("x", rules: [.init(trigger: "x", template: "{{DATE}} {{TIME}}")], context: context, calendar: west) == "1969/12/31 23:00")
    }
    @Test func clipboardPresentAndAbsent() {
        let rules = [SnippetRule(trigger: "x", template: "前{{CLIPBOARD}}後")]
        #expect(expand("x", rules) == "前コピー {{DATE}}後")
        #expect(SnippetExpander.expand("x", rules: rules, context: .init(date: context.date, clipboardText: nil)) == "前後")
    }
    @Test func unknownTokenUntouched() {
        #expect(expand("x", [.init(trigger: "x", template: "{{UNKNOWN}}")]) == "{{UNKNOWN}}")
    }
    @Test func emptyTriggerIgnored() {
        #expect(expand("a b", [.init(trigger: "", template: "bad"), .init(trigger: " \n", template: "bad")]) == "a b")
    }
    @Test func noMatchPassthrough() {
        #expect(expand("unchanged", [.init(trigger: "x", template: "y")]) == "unchanged")
    }
    @Test func clipboardOnlyNeededForExpandingTemplate() {
        let rules = [SnippetRule(trigger: "x", template: "{{CLIPBOARD}}")]
        #expect(!SnippetExpander.needsClipboard("none", rules: rules, date: context.date))
        #expect(SnippetExpander.needsClipboard("x", rules: rules, date: context.date))
        #expect(!SnippetExpander.needsClipboard("x", rules: [.init(trigger: " ", template: "{{CLIPBOARD}}")], date: context.date))
        #expect(SnippetExpander.needsClipboard("long", rules: [.init(trigger: "long", template: "x")] + rules, date: context.date))
    }
}
