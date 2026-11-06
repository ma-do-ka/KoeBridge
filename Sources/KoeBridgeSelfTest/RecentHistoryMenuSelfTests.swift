import Foundation
import KoeBridgeCore

struct RecentHistoryMenuSelfTests {
    func newestTenAndStableIds() {
        let records = (0..<12).reversed().map { i in
            TranscriptRecord(engine: "Apple", text: "履歴\(i)", isPartial: false, delivery: .pending)
        }
        let rows = RecentHistoryMenuPolicy.entries(from: records)
        check(rows.count == 10)
        check(rows.map(\.recordID) == Array(records.prefix(10)).map(\.id))
        check(rows.first?.preview == "履歴11")
        check(rows.last?.preview == "履歴2")
    }

    func multilinePartialAndEmojiAreSafe() {
        let text = " 今朝の\n GitHub\tIssue #190  は   修正済み "
        let record = TranscriptRecord(engine: "Gemini", text: text,
                                      isPartial: true, delivery: .recognitionInterrupted)
        let row = RecentHistoryMenuPolicy.entries(from: [record]).first
        check(row?.preview == "［途中］今朝の GitHub Issue #190 は 修正済み")
        check(record.text == text)  // Clipboard must use this unchanged full text.
        let long = TranscriptRecord(engine: "Apple", text: String(repeating: "👩‍💻", count: 90),
                                    isPartial: false, delivery: .automaticPasteDisabled)
        let preview = RecentHistoryMenuPolicy.entries(from: [long]).first?.preview
        check(preview == String(repeating: "👩‍💻", count: 44) + "…")
        check(RecentHistoryMenuPolicy.entries(from: []).isEmpty)
    }

    func reviewAndInterruptedEntriesAreVisible() {
        let text = "予算は100円。\n変更しないでください。"
        let review = TranscriptReview(status: .needsReview, note: "差異あり", alternativeText: "予算は1000円。")
        let record = TranscriptRecord(engine: "Gemini", text: text, isPartial: false,
                                      delivery: .interruptedDelivery, review: review)
        let row = RecentHistoryMenuPolicy.entries(from: [record])[0]
        check(row.recordID == record.id)
        check(row.preview.hasPrefix("［要確認・元の文］［入力要確認］"))
        check(row.copyHelp.contains("元の文章の全文をコピー"))
        check(row.copyHelp.contains("入力先に入った範囲を確認"))
        check(!row.preview.contains("1000円"))
        check(record.text == text)
        let withoutMetadata = TranscriptRecord(engine: "Gemini", text: text, isPartial: false,
                                               delivery: .reviewRequired)
        check(RecentHistoryMenuPolicy.entries(from: [withoutMetadata])[0].preview.hasPrefix("［要確認・元の文］"))
        let long = TranscriptRecord(engine: "Gemini", text: String(repeating: "👩‍💻", count: 90),
                                    isPartial: true, delivery: .interruptedDelivery, review: review)
        let preview = RecentHistoryMenuPolicy.entries(from: [long])[0].preview
        let marker = "［要確認・元の文］［入力要確認］［途中］"
        check(preview == marker + String(repeating: "👩‍💻", count: 44 - marker.count) + "…")
        check(preview.count == RecentHistoryMenuPolicy.maximumPreviewCharacters + 1)
    }
}
