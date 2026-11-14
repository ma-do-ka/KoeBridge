import Foundation

/// Diagnostic classifications only. None of these grant delivery permission.
public enum ReceiptEligibilityReason: String, CaseIterable, Equatable, Sendable {
    case markerNotNumeric = "marker_not_numeric"
    case selectionMissing = "selection_missing"
    case selectionUnavailable = "selection_unavailable"
    case valueUnavailable = "value_unavailable"
    case snapshotInvalid = "snapshot_invalid"
    case noObservableDelta = "no_observable_delta"
    case snapshotAvailable = "snapshot_available"
    case notAttempted = "not_attempted"
    case unknown

    public static func classify(selectionKind: InputDiagnosticEvent.Token,
                                selectionRead: InputDiagnosticEvent.Token = .notAttempted,
                                valueRead: InputDiagnosticEvent.Token = .notAttempted,
                                snapshotAvailable: Bool = false) -> Self {
        switch selectionKind {
        case .textMarker: return .markerNotNumeric
        case .none: return .selectionMissing
        case .numericRange:
            if snapshotAvailable { return .snapshotAvailable }
            if selectionRead == .notAttempted { return .notAttempted }
            if selectionRead != .ok { return .selectionUnavailable }
            if valueRead == .notAttempted { return .notAttempted }
            if valueRead != .ok { return .valueUnavailable }
            return .snapshotInvalid
        default: return .unknown
        }
    }

    /// Preserve ineligibility when there was no exact baseline. With an exact
    /// baseline, separate an invalid expected edit from an identical-text edit.
    public func afterPosting(expectedEditAvailable: Bool, textChanged: Bool) -> Self {
        guard self == .snapshotAvailable else { return self }
        guard expectedEditAvailable else { return .snapshotInvalid }
        return textChanged ? .snapshotAvailable : .noObservableDelta
    }
}

/// Constant-space sender telemetry. Actual gaps run from the previous keyUp
/// post's return to the next keyDown post's start (including AX/scheduling).
/// Stall total is post-call duration plus gap time beyond requested sleeps;
/// it is sender overhead, never evidence of receiver acceptance.
public struct DeliveryChunkProgress: Sendable {
    public private(set) var lastPostedOrdinal = 0
    public private(set) var gapCount = 0
    private var previousPostEnd: UInt64?
    private var requestedMin: UInt64 = 0
    private var requestedMax: UInt64 = 0
    private var requestedLast: UInt64 = 0
    private var actualMin: UInt64 = 0
    private var actualMax: UInt64 = 0
    private var actualLast: UInt64 = 0
    private var stallTotal: UInt64 = 0

    public init() {}

    private static func adding(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? UInt64.max : sum
    }

    public mutating func posted(ordinal: Int, requestedGapNanoseconds: UInt64,
                                beganNanoseconds: UInt64, endedNanoseconds: UInt64) {
        if let previousPostEnd {
            let gap = beganNanoseconds >= previousPostEnd ? beganNanoseconds - previousPostEnd : 0
            if gapCount == 0 {
                requestedMin = requestedGapNanoseconds
                actualMin = gap
            } else {
                requestedMin = min(requestedMin, requestedGapNanoseconds)
                actualMin = min(actualMin, gap)
            }
            requestedMax = max(requestedMax, requestedGapNanoseconds)
            requestedLast = requestedGapNanoseconds
            actualMax = max(actualMax, gap)
            actualLast = gap
            if gapCount < Int.max { gapCount += 1 }
            stallTotal = Self.adding(stallTotal, gap > requestedGapNanoseconds ? gap - requestedGapNanoseconds : 0)
        }
        stallTotal = Self.adding(stallTotal, endedNanoseconds >= beganNanoseconds ? endedNanoseconds - beganNanoseconds : 0)
        previousPostEnd = endedNanoseconds
        lastPostedOrdinal = max(lastPostedOrdinal, ordinal)
    }

    public var fields: [InputDiagnosticEvent.Field: InputDiagnosticEvent.Value] {
        func microseconds(_ ns: UInt64) -> InputDiagnosticEvent.Value {
            .integer(Int(clamping: ns / 1_000))
        }
        return [
            .lastPostedOrdinal: .integer(lastPostedOrdinal), .gapCount: .integer(gapCount),
            .requestedGapMinUS: microseconds(requestedMin), .requestedGapMaxUS: microseconds(requestedMax),
            .requestedGapLastUS: microseconds(requestedLast), .actualGapMinUS: microseconds(actualMin),
            .actualGapMaxUS: microseconds(actualMax), .actualGapLastUS: microseconds(actualLast),
            .postingStallTotalUS: microseconds(stallTotal)
        ]
    }
}
