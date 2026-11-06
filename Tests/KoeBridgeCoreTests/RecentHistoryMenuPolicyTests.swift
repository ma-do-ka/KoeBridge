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
}
