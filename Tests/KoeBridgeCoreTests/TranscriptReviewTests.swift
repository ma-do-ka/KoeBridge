import Foundation
import Testing
@testable import KoeBridgeCore

struct TranscriptReviewTests {
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
                     "src/という。こと.swift", "https://example.com/について。は", "という。こと.swift"] {
            #expect(TextContextChecking.check(text).text == text)
        }
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
}
