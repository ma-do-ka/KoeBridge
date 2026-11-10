import Foundation

/// Content-only history search that preserves the archive's input order.
public enum HistorySearch {
    public static func filter(_ records: [TranscriptRecord], query: String) -> [TranscriptRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }
        let terms = trimmed.split(whereSeparator: { $0.isWhitespace }).map {
            String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        return records.filter { record in
            let text = record.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return terms.allSatisfy { text.contains($0) }
        }
    }
}
