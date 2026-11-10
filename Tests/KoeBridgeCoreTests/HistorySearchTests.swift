import Foundation
import Testing
@testable import KoeBridgeCore

struct HistorySearchTests {
    @Test func emptyQueryPassthrough() {
        let records = [record("first"), record("second")]
        #expect(HistorySearch.filter(records, query: "") == records)
        #expect(HistorySearch.filter(records, query: " \t\n ") == records)
    }

    @Test func singleTermSubstring() {
        let records = [record("今日の文字起こし"), record("別の文章")]
        #expect(HistorySearch.filter(records, query: "文字") == [records[0]])
    }

    @Test func caseInsensitiveMatch() {
        let records = [record("Use KoeBridge today")]
        #expect(HistorySearch.filter(records, query: "koebridge") == records)
    }

    @Test func diacriticInsensitiveMatch() {
        let records = [record("Café résumé")]
        #expect(HistorySearch.filter(records, query: "CAFE resume") == records)
        #expect(HistorySearch.filter([record("cafe")], query: "café").count == 1)
    }

    @Test func multiTermAND() {
        let records = [record("KoeBridge writes notes"), record("KoeBridge writes")]
        #expect(HistorySearch.filter(records, query: "  notes\tKoeBridge\n ") == [records[0]])
        #expect(HistorySearch.filter(records, query: "KoeBridge missing").isEmpty)
    }

    @Test func noMatchReturnsEmpty() {
        #expect(HistorySearch.filter([record("hello")], query: "missing").isEmpty)
        #expect(HistorySearch.filter([], query: "hello").isEmpty)
    }

    @Test func orderPreserved() {
        let records = [record("match newest"), record("other"), record("match oldest")]
        #expect(HistorySearch.filter(records, query: "match") == [records[0], records[2]])
    }

    @Test func matchesTextContentOnly() {
        let metadataOnly = TranscriptRecord(
            engine: "EngineOnly", text: "本文", isPartial: false, delivery: .reviewRequired,
            review: TranscriptReview(status: .needsReview, note: "ReviewOnly",
                                     originalText: "OriginalOnly", alternativeText: "AlternativeOnly"),
            deliveryDetail: "DetailOnly")
        for query in ["EngineOnly", "ReviewOnly", "AlternativeOnly", "OriginalOnly",
                      "DetailOnly", metadataOnly.delivery.label] {
            #expect(HistorySearch.filter([metadataOnly], query: query).isEmpty)
        }
        #expect(HistorySearch.filter([metadataOnly], query: "本文") == [metadataOnly])
    }

    private func record(_ text: String) -> TranscriptRecord {
        TranscriptRecord(recordedAt: Date(timeIntervalSince1970: 0), engine: "Apple",
                         text: text, isPartial: false, delivery: .pending)
    }
}
