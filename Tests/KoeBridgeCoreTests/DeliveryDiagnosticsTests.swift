import Foundation
import Testing
@testable import KoeBridgeCore

struct DeliveryDiagnosticsTests {
    @Test func receiptEligibilityDistinguishesSkippedUnknownAndFailed() {
        typealias Reason = ReceiptEligibilityReason
        typealias Token = InputDiagnosticEvent.Token
        for value in [Token.notAttempted, .ok, .unavailable, .secure, .tooLarge] {
            #expect(Reason.classify(selectionKind: .textMarker, valueRead: value) == .markerNotNumeric)
            #expect(Reason.classify(selectionKind: .none, valueRead: value) == .selectionMissing)
        }
        #expect(Reason.classify(selectionKind: .unknown) == .unknown)
        #expect(Reason.classify(selectionKind: .numericRange) == .notAttempted)
        #expect(Reason.classify(selectionKind: .numericRange, selectionRead: .ok) == .notAttempted)
        for selection in [Token.missing, .unavailable, .invalidType, .invalidRange] {
            #expect(Reason.classify(selectionKind: .numericRange, selectionRead: selection,
                                    valueRead: .ok) == .selectionUnavailable)
        }
        for value in [Token.missing, .unavailable, .invalidType, .tooLarge, .secure, .unknown] {
            #expect(Reason.classify(selectionKind: .numericRange, selectionRead: .ok,
                                    valueRead: value) == .valueUnavailable)
        }
        #expect(Reason.classify(selectionKind: .numericRange, selectionRead: .ok,
                                valueRead: .ok) == .snapshotInvalid)
        #expect(Reason.classify(selectionKind: .numericRange, selectionRead: .ok,
                                valueRead: .ok, snapshotAvailable: true) == .snapshotAvailable)
        #expect(Reason.snapshotAvailable.afterPosting(expectedEditAvailable: false, textChanged: false) == .snapshotInvalid)
        #expect(Reason.snapshotAvailable.afterPosting(expectedEditAvailable: true, textChanged: false) == .noObservableDelta)
        #expect(Reason.snapshotAvailable.afterPosting(expectedEditAvailable: true, textChanged: true) == .snapshotAvailable)
        for skipped in [Reason.markerNotNumeric, .selectionMissing, .selectionUnavailable, .valueUnavailable] {
            #expect(skipped.afterPosting(expectedEditAvailable: false, textChanged: false) == skipped)
        }
        let codes = Set(Reason.allCases.map(\.rawValue))
        #expect(codes == Set(["marker_not_numeric", "selection_missing", "selection_unavailable",
                             "value_unavailable", "snapshot_invalid", "no_observable_delta",
                             "snapshot_available", "not_attempted", "unknown"]))
        for code in codes {
            #expect(InputDiagnosticEvent.Value.reason(code) != .token(.unknown) || code == "unknown")
        }
    }

    @Test func progressSummarizesRealGapsAndPostingOverhead() {
        var progress = DeliveryChunkProgress()
        #expect(progress.fields[.lastPostedOrdinal] == .integer(0))
        #expect(progress.fields[.gapCount] == .integer(0))
        progress.posted(ordinal: 1, requestedGapNanoseconds: 0,
                        beganNanoseconds: 1_000_000, endedNanoseconds: 1_100_000)
        #expect(progress.gapCount == 0)
        progress.posted(ordinal: 2, requestedGapNanoseconds: 20_000_000,
                        beganNanoseconds: 23_100_000, endedNanoseconds: 23_300_000)
        progress.posted(ordinal: 3, requestedGapNanoseconds: 20_000_000,
                        beganNanoseconds: 43_300_000, endedNanoseconds: 43_600_000)
        let fields = progress.fields
        #expect(progress.lastPostedOrdinal == 3 && progress.gapCount == 2)
        #expect(fields[.requestedGapMinUS] == .integer(20_000))
        #expect(fields[.requestedGapMaxUS] == .integer(20_000))
        #expect(fields[.requestedGapLastUS] == .integer(20_000))
        #expect(fields[.actualGapMinUS] == .integer(20_000))
        #expect(fields[.actualGapMaxUS] == .integer(22_000))
        #expect(fields[.actualGapLastUS] == .integer(20_000))
        #expect(fields[.postingStallTotalUS] == .integer(2_600))
    }

    @Test func progressIsConstantSpaceAcrossLongDeliveriesAndSaturatesSafely() {
        var progress = DeliveryChunkProgress()
        for index in 1...10_000 {
            let began = UInt64(index) * 25_000_000
            progress.posted(ordinal: index, requestedGapNanoseconds: 20_000_000,
                            beganNanoseconds: began, endedNanoseconds: began + 1_000)
            #expect(progress.fields.count == 9)
        }
        #expect(progress.lastPostedOrdinal == 10_000 && progress.gapCount == 9_999)
        #expect(progress.fields[.requestedGapLastUS] == .integer(20_000))
        // Bad/overflowing clock fixtures cannot wrap or trap the summary.
        progress.posted(ordinal: Int.max, requestedGapNanoseconds: 0,
                        beganNanoseconds: UInt64.max, endedNanoseconds: 0)
        progress.posted(ordinal: 0, requestedGapNanoseconds: 0,
                        beganNanoseconds: 0, endedNanoseconds: UInt64.max)
        #expect(progress.lastPostedOrdinal == Int.max)
        #expect(progress.fields[.postingStallTotalUS] == .integer(Int(clamping: UInt64.max / 1_000)))
    }
}
