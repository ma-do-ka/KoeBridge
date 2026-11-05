import Foundation

/// Presentation-only snapshot of the local transcript archive. The menu
/// previews are deliberately bounded; the original full text is never altered.
public struct RecentHistoryMenuEntry: Equatable, Sendable {
    public let recordID: UUID
    public let recordedAt: Date
    public let preview: String
    public let isPartial: Bool
}

public enum RecentHistoryMenuPolicy {
    public static let maximumPreviewCharacters = 44

    public static func entries(from history: [TranscriptRecord]) -> [RecentHistoryMenuEntry] {
        history.prefix(RecentTranscriptArchive.maximumRecords).map { record in
            // Read only a short prefix even if a corrupted/extreme record is huge.
            // Collapse newlines and spaces for NSMenu's single-line rows.
            let oneLine = String(record.text.prefix(160))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let cut = oneLine.count > maximumPreviewCharacters
                || !record.text.dropFirst(160).isEmpty
            let summary = oneLine.isEmpty ? "（本文を表示できません）" :
                String(oneLine.prefix(maximumPreviewCharacters)) + (cut ? "…" : "")
            return RecentHistoryMenuEntry(
                recordID: record.id, recordedAt: record.recordedAt,
                preview: (record.isPartial ? "［途中］" : "") + summary,
                isPartial: record.isPartial
            )
        }
    }
}
