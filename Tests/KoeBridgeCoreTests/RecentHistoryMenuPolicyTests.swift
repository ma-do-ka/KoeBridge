import Foundation
import Testing
@testable import KoeBridgeCore

struct RecentHistoryMenuPolicyTests {
    @Test func newestTenRemainInArchiveOrder() {
        let records = (0..<12).reversed().map { i in
            TranscriptRecord(recordedAt: Date(timeIntervalSince1970: TimeInterval(i)),
                             engine: "Apple", text: "文章\(i)", isPartial: false,
                             delivery: .attemptedUnconfirmed)
        }
        let rows = RecentHistoryMenuPolicy.entries(from: records)
        #expect(rows.count == 10)
        #expect(rows.map(\.recordID) == Array(records.prefix(10)).map(\.id))
        #expect(rows.map(\.preview) == (2...11).reversed().map { "文章\($0)" })
    }

    @Test func previewCollapsesNewlinesWithoutEditingOriginalText() {
        let original = " 今朝の\n GitHub\tIssue #190  は   修正済み "
        let record = TranscriptRecord(engine: "Gemini", text: original,
                                      isPartial: true, delivery: .recognitionInterrupted)
        let row = try! #require(RecentHistoryMenuPolicy.entries(from: [record]).first)
        #expect(row.preview == "［途中］今朝の GitHub Issue #190 は 修正済み")
        #expect(row.isPartial)
        #expect(record.text == original)
    }

    @Test func emojiAndLongTextAreClippedAtGraphemeBoundaries() {
        let full = String(repeating: "👩‍💻", count: 90)
        let rows = RecentHistoryMenuPolicy.entries(from: [
            TranscriptRecord(engine: "Gemini", text: full, isPartial: false,
                             delivery: .automaticPasteDisabled)
        ])
        let preview = rows[0].preview
        #expect(preview.count == RecentHistoryMenuPolicy.maximumPreviewCharacters + 1)
        #expect(preview == String(repeating: "👩‍💻", count: 44) + "…")
        #expect(rows[0].recordID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    @Test func emptyMenuIsValid() {
        #expect(RecentHistoryMenuPolicy.entries(from: []).isEmpty)
    }

    @Test func reviewAndInterruptedRowsExplainWhichTextWillBeCopied() {
        let original = "予算は100円。\n変更しないでください。"
        let alternative = "予算は1000円。変更してください。"
        let review = TranscriptReview(status: .needsReview, note: "差異あり", alternativeText: alternative)
        let records = [
            TranscriptRecord(engine: "Gemini", text: original, isPartial: false, delivery: .reviewRequired, review: review),
            // The review marker must survive a later interruption of delivery.
            TranscriptRecord(engine: "Gemini", text: original, isPartial: false, delivery: .interruptedDelivery, review: review),
            TranscriptRecord(engine: "Apple", text: original, isPartial: false, delivery: .interruptedDelivery),
            TranscriptRecord(engine: "Gemini", text: original, isPartial: false, delivery: .reviewRequired)
        ]
        let rows = RecentHistoryMenuPolicy.entries(from: records)
        #expect(rows.map(\.recordID) == records.map(\.id))
        for index in [0, 1, 3] {
            #expect(rows[index].preview.hasPrefix("［要確認・元の文］"))
            #expect(rows[index].copyHelp.contains("元の文章の全文をコピー"))
            #expect(rows[index].copyHelp.contains("履歴をすべて表示…"))
        }
        #expect(rows[1].preview.contains("［入力要確認］"))
        #expect(rows[2].preview.hasPrefix("［入力要確認］"))
        #expect(rows[2].copyHelp.contains("入力先に入った範囲を確認"))
        #expect(!rows[3].copyHelp.contains("候補は"))
        #expect(records.allSatisfy { $0.text == original })
        #expect(records[0].review?.alternativeText == alternative)
        #expect(rows.allSatisfy { !$0.preview.contains("1000円") })
    }

    @Test func attentionMarkersStayInsideTheGraphemePreviewBudget() {
        let original = String(repeating: "👩‍💻", count: 90)
        let record = TranscriptRecord(engine: "Gemini", text: original, isPartial: true,
                                      delivery: .interruptedDelivery,
                                      review: TranscriptReview(status: .needsReview, note: "差異あり", alternativeText: "別の候補"))
        let row = RecentHistoryMenuPolicy.entries(from: [record])[0]
        let marker = "［要確認・元の文］［入力要確認］［途中］"
        #expect(row.preview == marker + String(repeating: "👩‍💻", count: 44 - marker.count) + "…")
        #expect(row.preview.count == RecentHistoryMenuPolicy.maximumPreviewCharacters + 1)
        #expect(row.isPartial)
        #expect(record.text == original)
    }
}
