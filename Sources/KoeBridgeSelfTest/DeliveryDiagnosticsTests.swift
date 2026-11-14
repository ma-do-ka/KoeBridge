import Foundation
import KoeBridgeCore

struct DeliveryDiagnosticsTests {
    func receiptEligibilityDistinguishesSkippedUnknownAndFailed() {
        typealias Reason = ReceiptEligibilityReason
        typealias Token = InputDiagnosticEvent.Token
        for value in [Token.notAttempted, .ok, .unavailable, .secure, .tooLarge] {
            check(Reason.classify(selectionKind: .textMarker, valueRead: value) == .markerNotNumeric)
            check(Reason.classify(selectionKind: .none, valueRead: value) == .selectionMissing)
        }
        check(Reason.classify(selectionKind: .unknown) == .unknown)
        check(Reason.classify(selectionKind: .numericRange) == .notAttempted)
        check(Reason.classify(selectionKind: .numericRange, selectionRead: .ok) == .notAttempted)
        for selection in [Token.missing, .unavailable, .invalidType, .invalidRange] {
            check(Reason.classify(selectionKind: .numericRange, selectionRead: selection,
                                    valueRead: .ok) == .selectionUnavailable)
        }
        for value in [Token.missing, .unavailable, .invalidType, .tooLarge, .secure, .unknown] {
            check(Reason.classify(selectionKind: .numericRange, selectionRead: .ok,
                                    valueRead: value) == .valueUnavailable)
        }
        check(Reason.classify(selectionKind: .numericRange, selectionRead: .ok,
                                valueRead: .ok) == .snapshotInvalid)
        check(Reason.classify(selectionKind: .numericRange, selectionRead: .ok,
                                valueRead: .ok, snapshotAvailable: true) == .snapshotAvailable)
        check(Reason.snapshotAvailable.afterPosting(expectedEditAvailable: false, textChanged: false) == .snapshotInvalid)
        check(Reason.snapshotAvailable.afterPosting(expectedEditAvailable: true, textChanged: false) == .noObservableDelta)
        check(Reason.snapshotAvailable.afterPosting(expectedEditAvailable: true, textChanged: true) == .snapshotAvailable)
        for skipped in [Reason.markerNotNumeric, .selectionMissing, .selectionUnavailable, .valueUnavailable] {
            check(skipped.afterPosting(expectedEditAvailable: false, textChanged: false) == skipped)
        }
        let codes = Set(Reason.allCases.map(\.rawValue))
        check(codes == Set(["marker_not_numeric", "selection_missing", "selection_unavailable",
                             "value_unavailable", "snapshot_invalid", "no_observable_delta",
                             "snapshot_available", "not_attempted", "unknown"]))
        for code in codes {
            check(InputDiagnosticEvent.Value.reason(code) != .token(.unknown) || code == "unknown")
        }
    }

    func progressSummarizesRealGapsAndPostingOverhead() {
        var progress = DeliveryChunkProgress()
        check(progress.fields[.lastPostedOrdinal] == .integer(0))
        check(progress.fields[.gapCount] == .integer(0))
        progress.posted(ordinal: 1, requestedGapNanoseconds: 0,
                        beganNanoseconds: 1_000_000, endedNanoseconds: 1_100_000)
        check(progress.gapCount == 0)
        progress.posted(ordinal: 2, requestedGapNanoseconds: 20_000_000,
                        beganNanoseconds: 23_100_000, endedNanoseconds: 23_300_000)
        progress.posted(ordinal: 3, requestedGapNanoseconds: 20_000_000,
                        beganNanoseconds: 43_300_000, endedNanoseconds: 43_600_000)
        let fields = progress.fields
        check(progress.lastPostedOrdinal == 3 && progress.gapCount == 2)
        check(fields[.requestedGapMinUS] == .integer(20_000))
        check(fields[.requestedGapMaxUS] == .integer(20_000))
        check(fields[.requestedGapLastUS] == .integer(20_000))
        check(fields[.actualGapMinUS] == .integer(20_000))
        check(fields[.actualGapMaxUS] == .integer(22_000))
        check(fields[.actualGapLastUS] == .integer(20_000))
        check(fields[.postingStallTotalUS] == .integer(2_600))
    }

    func progressIsConstantSpaceAcrossLongDeliveriesAndSaturatesSafely() {
        var progress = DeliveryChunkProgress()
        for index in 1...10_000 {
            let began = UInt64(index) * 25_000_000
            progress.posted(ordinal: index, requestedGapNanoseconds: 20_000_000,
                            beganNanoseconds: began, endedNanoseconds: began + 1_000)
            check(progress.fields.count == 9)
        }
        check(progress.lastPostedOrdinal == 10_000 && progress.gapCount == 9_999)
        check(progress.fields[.requestedGapLastUS] == .integer(20_000))
        // Bad/overflowing clock fixtures cannot wrap or trap the summary.
        progress.posted(ordinal: Int.max, requestedGapNanoseconds: 0,
                        beganNanoseconds: UInt64.max, endedNanoseconds: 0)
        progress.posted(ordinal: 0, requestedGapNanoseconds: 0,
                        beganNanoseconds: 0, endedNanoseconds: UInt64.max)
        check(progress.lastPostedOrdinal == Int.max)
        check(progress.fields[.postingStallTotalUS] == .integer(Int(clamping: UInt64.max / 1_000)))
    }
}
