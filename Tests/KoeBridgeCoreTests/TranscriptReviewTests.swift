import Foundation
import Testing
@testable import KoeBridgeCore

struct TranscriptReviewTests {
    @Test func nestedAndUnclosedQuotations() {
        for (open, close) in [("「", "」"), ("『", "』"), ("“", "”"), ("‘", "’")] {
            let nested = open + "外 " + open + "内" + close + " 残 す。次にという。こと " + close
            #expect(JapaneseDictationSpacing.adopt(nested + " 後 文", enabled: true, protectedTerms: []) == nested + " 後文")
            #expect(AgentInstructionFormatting.format(nested) == nested)
            #expect(TextContextChecking.check(nested).changes == 0)
            let unclosed = open + "残 す\n次 行"
            #expect(JapaneseDictationSpacing.adopt(unclosed, enabled: true, protectedTerms: []) == unclosed)
        }
        #expect(JapaneseDictationSpacing.adopt("'残 す\n次 行", enabled: true, protectedTerms: []) == "'残 す\n次行")
    }

    @Test func balancedTypographicQuotesProtectBothLines() {
        for (open, close) in [("「", "」"), ("『", "』"), ("“", "”"), ("‘", "’")] {
            let quoted = open + "一行 目\n二行 目" + close
            let source = quoted + " 後 文"
            #expect(ProtectedTextSpans(source).contents == [Data(quoted.utf8)])
            #expect(JapaneseDictationSpacing.adopt(source, enabled: true, protectedTerms: []) == quoted + " 後文")
        }
    }

    @Test func apostrophesInWordsAndQuotations() {
        for word in ["don't", "it's", "rock'n'roll", "カ'ナ", "don’t"] {
            let source = "項目：" + word + "。日本 語"
            #expect(JapaneseDictationSpacing.adopt(source, enabled: true, protectedTerms: []) == "項目：" + word + "。日本語")
            let quoted = "'日本 語 " + word + " 残 す'"
            #expect(JapaneseDictationSpacing.adopt(quoted + " 後 文", enabled: true, protectedTerms: []) == quoted + " 後文")
        }
    }

    @Test func foreignDelimitersAndTrailingApostrophesLeaveProseEditable() {
        let examples = [
            (#""users'""#, "。次にという。こと 後 文", "。次にという。こと後文"),
            (#""The users' guide""#, " 日本 語。次にという。こと", " 日本語。次にという。こと"),
            (#""foo 'bar""#, " 日本 語", " 日本語"),
            (#"'foo "bar'"#, " 日本 語", " 日本語"),
            ("It's users'", "。日本 語", "。日本語")
        ]
        for (prefix, prose, normalized) in examples {
            let source = prefix + prose
            let tail = NSRange(location: prefix.utf16.count, length: prose.utf16.count)
            #expect(!ProtectedTextSpans(source).intersects(tail))
            #expect(JapaneseDictationSpacing.adopt(source, enabled: true, protectedTerms: []) == prefix + normalized)
            #expect(AgentInstructionFormatting.format(source) == prefix + prose.replacingOccurrences(of: "。次に", with: "。\n次に"))
            #expect(TextContextChecking.check(source).text == prefix + prose.replacingOccurrences(of: "という。こと", with: "ということ"))
        }
    }

    @Test func quoteCoverageMatchesMainOnUnchangedCases() {
        // UTF-16 ranges captured from main (c9806ec). Check coverage and the
        // boundaries between spans, including the two units of an emoji.
        let fixtures: [(String, [Range<Int>])] = [
            ("😀『語 文』後 文「別」", [2..<7, 10..<13]),
            ("彼は“語 文”と‘別’", [2..<7, 8..<11]),
            ("\"開 く\n次 行", [0..<5]),
            ("「未 完", [0..<4]),
            ("🍵\"和 ' 文\"次", [2..<9]),
            ("\"甲\"\"乙\" 後", [0..<6]),
            ("引用なし", []),
            ("「外『内』残」後", [0..<7]),
            ("語 '未 完", [2..<6])
        ]
        for (source, expected) in fixtures {
            let spans = ProtectedTextSpans(source)
            for offset in 0..<source.utf16.count {
                let unit = NSRange(location: offset, length: 1)
                #expect(spans.intersects(unit) == expected.contains { $0.contains(offset) })
                #expect(spans.containsInterior(offset) == expected.contains { $0.lowerBound < offset && offset < $0.upperBound })
            }
        }
    }

    @Test func escapedClosersStayLiteralAndOnlyASCIIQuotesStopAtLineBreaks() {
        for quoted in [#""前\" 残 す ' 後""#, #"'前\' 残 す " 後'"#] {
            #expect(JapaneseDictationSpacing.adopt(quoted + " 後 文", enabled: true, protectedTerms: []) == quoted + " 後文")
        }
        for open in ["「", "『", "“", "‘", "'", "\""] {
            for newline in ["\n", "\r", "\r\n", "\u{2028}", "\u{2029}"] {
                let prefix = open + " 残 す" + newline
                let source = prefix + "次 行"
                let expected = (open == "\"" || open == "'") ? prefix + "次行" : source
                #expect(JapaneseDictationSpacing.adopt(source, enabled: true, protectedTerms: []) == expected)
            }
        }
    }

    @Test func localPathsAgreeOnFenceFixtures() {
        let body = "和 文。次にという。こと"
        let fixtures = [("```swift\n" + body + "\n```", true), ("  ~~~~sh\n" + body + "\n  ~~~~~", true),
                        ("````\n```\n" + body + "\n````", true), ("```sh\nx=\"```\"\n" + body + "\n```", true), ("~~~\r\n" + body, true),
                        (body, false), ("~~\n" + body + "\n~~", false), ("    ~~~\n" + body, false)]
        for (source, protected) in fixtures {
            #expect((JapaneseDictationSpacing.adopt(source, enabled: true, protectedTerms: []) == source) == protected)
            #expect((AgentInstructionFormatting.format(source) == source) == protected)
            #expect((TextContextChecking.check(source).changes == 0) == protected)
        }
    }

    @Test func localCheckJoinsOnlyKnownConnectives() {
        let result = TextContextChecking.check("設定について。はあとで考えるという。ことです。今日は終わり。明日続けます。")
        #expect(result.text == "設定についてはあとで考えるということです。今日は終わり。明日続けます。")
        #expect(result.changes == 2)
        #expect(TextContextChecking.check("どうしたの。教えてください。").changes == 0)
    }

    @Test func quotedCodePathsAndNumbersRemainExact() {
        let source = "`という。こと` と「について。は」 https://example.com/a?x=1 ./src/a.swift --force 1.25 1,000 😊"
        #expect(TextContextChecking.check(source).text == source)
        for (a, b) in [("番号は1.25", "番号は125"), ("変更しない", "変更する"),
                        ("foo bar", "foobar"), ("`a b`", "`ab`"), ("設定？", "設定。"),
                        ("番号は１ ０００", "番号は１０００")] {
            #expect(!TextContextChecking.hasMatchingWords(original: a, candidate: b))
        }
        #expect(TextContextChecking.hasMatchingWords(original: "設定について。は変更しない。", candidate: "設定については、変更しない。"))
        #expect(!TextContextChecking.hasMatchingWords(original: "", candidate: ""))
    }

    @Test func reviewDeadlineUsesRemainingPrimaryBudget() {
        let stop = Date(timeIntervalSince1970: 100)
        #expect(TranscriptReviewDeadline.available(stoppedAt: stop, now: stop) == 6)
        #expect(TranscriptReviewDeadline.available(stoppedAt: stop, now: stop.addingTimeInterval(12)) == 2.75)
        #expect(TranscriptReviewDeadline.available(stoppedAt: stop, now: stop.addingTimeInterval(14.8)) == 0)
        #expect(TranscriptReviewDeadline.available(stoppedAt: nil, now: stop) == 0)
    }

    @Test func audioComparisonDoesNotEnableTextEditing() {
        let original = "設定について。は変更しない。"
        let candidate = "設定については、変更しない。"
        let audioOnly = TextContextChecking.compare(original: original, candidate: candidate, textCheckEnabled: false)
        #expect(!audioOnly.requiresReview)
        #expect(audioOnly.text == original)
        let both = TextContextChecking.compare(original: original, candidate: candidate, textCheckEnabled: true)
        #expect(!both.requiresReview)
        #expect(both.text == "設定については変更しない。")
        let disagreement = TextContextChecking.compare(original: original, candidate: "設定を変更する。", textCheckEnabled: true)
        #expect(disagreement.requiresReview && disagreement.text == original)
    }

    @Test func incompleteQuotesAndUnicodePathsAreNeverRewritten() {
        for text in ["`という。こと", "```\nという。こと", "「について。は", "“という。こと”",
                     "src/という。こと.swift", "https://example.com/について。は", "という。こと.swift",
                     "参照はhttps://example.com/について。はです"] {
            #expect(TextContextChecking.check(text).text == text)
        }
        let prose = "src/という。こと.swiftを開きます。設定について。は変更しない。"
        #expect(TextContextChecking.check(prose).text == "src/という。こと.swiftを開きます。設定については変更しない。")
        #expect(!TextContextChecking.hasMatchingWords(original: "src/という。こと.swift",
                                                      candidate: "src/ということ.swift"))
    }

    @Test func reviewEvidenceRoundTripsAndOldHistoryStillDecodes() throws {
        let original = TranscriptRecord(engine: "Gemini", text: "100円", isPartial: false,
                                        delivery: .reviewRequired,
                                        review: TranscriptReview(status: .needsReview, note: "差異あり", alternativeText: "1000円"))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(TranscriptRecord.self, from: encoder.encode(original)) == original)
        let old = TranscriptRecord(engine: "Apple", text: "以前の履歴", isPartial: false, delivery: .attemptedUnconfirmed)
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any])
        json.removeValue(forKey: "review")
        #expect(try decoder.decode(TranscriptRecord.self, from: JSONSerialization.data(withJSONObject: json)).review == nil)
    }

    @Test func mixedConnectivesPreserveOriginalLiteralBoundariesAndUnicodeOffsets() {
        let literal = "👩🏽‍💻 `という。こと` src/という。こと.swift 「について。は」"
        let source = "設定について。は変更するという。ことです。\(literal) 次の案に関して。は担当として。は確認します。という。ものです。"
        let expected = "設定については変更するということです。\(literal) 次の案に関しては担当としては確認します。というものです。"
        let result = TextContextChecking.check(source)
        #expect(result.text == expected)
        #expect(result.changes == 5)
        #expect(TextContextChecking.check(result.text).changes == 0)
        #expect(TextContextChecking.hasMatchingWords(original: source, candidate: result.text))
    }
}
