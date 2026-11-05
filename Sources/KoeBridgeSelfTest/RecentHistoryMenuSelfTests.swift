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
}
