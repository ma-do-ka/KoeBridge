import Foundation

/// Presentation-only snapshot of the local transcript archive. The menu
/// previews are deliberately bounded; the original full text is never altered.
public struct RecentHistoryMenuEntry: Equatable, Sendable {
    public let recordID: UUID
    public let recordedAt: Date
    public let preview: String
    public let isPartial: Bool
    public let copyHelp: String
}

public enum RecentHistoryMenuPolicy {
    public static let maximumPreviewCharacters = 44

    public static func entries(from history: [TranscriptRecord]) -> [RecentHistoryMenuEntry] {
        history.prefix(RecentTranscriptArchive.maximumRecords).map { record in
            let needsReview = record.delivery == .reviewRequired || record.review?.status == .needsReview
            let interrupted = record.delivery == .interruptedDelivery
            let marker = (needsReview ? "［要確認・元の文］" : "")
                + (interrupted ? "［入力要確認］" : "")
                + (record.isPartial ? "［途中］" : "")
            let textBudget = max(0, maximumPreviewCharacters - marker.count)
            // Read only a short prefix even if a corrupted/extreme record is huge.
            // Collapse newlines and spaces for NSMenu's single-line rows.
            let oneLine = String(record.text.prefix(160))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let cut = oneLine.count > textBudget
                || !record.text.dropFirst(160).isEmpty
            let summary = oneLine.isEmpty ? "（本文を表示できません）" :
                String(oneLine.prefix(textBudget)) + (cut ? "…" : "")
            var copyHelp = needsReview
                ? "再認識結果との違いがあります。選ぶと元の文章の全文をコピーします。"
                : "選ぶと保存済みの全文をコピーします。⌘Vで貼り付けできます"
            if needsReview {
                copyHelp += record.review?.alternativeText != nil
                    ? "候補は「履歴をすべて表示…」で確認できます。"
                    : "詳しくは「履歴をすべて表示…」を確認してください。"
            }
            if interrupted {
                copyHelp += " 入力処理が中断したため、貼り付ける前に入力先に入った範囲を確認してください。"
            }
            return RecentHistoryMenuEntry(
                recordID: record.id, recordedAt: record.recordedAt,
                preview: marker + summary,
                isPartial: record.isPartial,
                copyHelp: copyHelp
            )
        }
    }
}
