import Foundation
import KoeBridgeCore

struct HistorySearchTests {
    func emptyQueryPassthrough() {
        let records = [record("first"), record("second")]
        check(HistorySearch.filter(records, query: "") == records)
        check(HistorySearch.filter(records, query: " \t\n ") == records)
    }

    func singleTermSubstring() {
        let records = [record("今日の文字起こし"), record("別の文章")]
        check(HistorySearch.filter(records, query: "文字") == [records[0]])
    }

    func caseInsensitiveMatch() {
        let records = [record("Use KoeBridge today")]
        check(HistorySearch.filter(records, query: "koebridge") == records)
    }

    func diacriticInsensitiveMatch() {
        let records = [record("Café résumé")]
        check(HistorySearch.filter(records, query: "CAFE resume") == records)
        check(HistorySearch.filter([record("cafe")], query: "café").count == 1)
    }

    func multiTermAND() {
        let records = [record("KoeBridge writes notes"), record("KoeBridge writes")]
        check(HistorySearch.filter(records, query: "  notes\tKoeBridge\n ") == [records[0]])
        check(HistorySearch.filter(records, query: "KoeBridge missing").isEmpty)
    }

    func noMatchReturnsEmpty() {
        check(HistorySearch.filter([record("hello")], query: "missing").isEmpty)
        check(HistorySearch.filter([], query: "hello").isEmpty)
    }

    func orderPreserved() {
        let records = [record("match newest"), record("other"), record("match oldest")]
        check(HistorySearch.filter(records, query: "match") == [records[0], records[2]])
    }

    func matchesTextContentOnly() {
        let metadataOnly = TranscriptRecord(
            engine: "EngineOnly", text: "本文", isPartial: false, delivery: .reviewRequired,
            review: TranscriptReview(status: .needsReview, note: "ReviewOnly",
                                     originalText: "OriginalOnly", alternativeText: "AlternativeOnly"),
            deliveryDetail: "DetailOnly")
        for query in ["EngineOnly", "ReviewOnly", "AlternativeOnly", "OriginalOnly",
                      "DetailOnly", metadataOnly.delivery.label] {
            check(HistorySearch.filter([metadataOnly], query: query).isEmpty)
        }
        check(HistorySearch.filter([metadataOnly], query: "本文") == [metadataOnly])
    }

    private func record(_ text: String) -> TranscriptRecord {
        TranscriptRecord(recordedAt: Date(timeIntervalSince1970: 0), engine: "Apple",
                         text: text, isPartial: false, delivery: .pending)
    }
}
