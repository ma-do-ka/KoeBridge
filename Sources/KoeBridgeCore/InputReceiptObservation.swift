/// A content-free description of one read-back attempt. This is diagnostic
/// evidence only: it cannot authorize input, rebase a caret, or create a receipt.
/// The caller must still use InsertionReceiptPolicy.verify together with the
/// input pipeline's focus, cancellation, and deadline checks.
public enum InputReceiptObservation: String, Equatable, Sendable {
    case unavailable
    case invalidSnapshot
    case notComparable
    case unchanged
    case matches
    case selectionMismatch
    case textMismatch

    public static func classify(before: InsertionReceiptPolicy.Snapshot?,
                                expected: InsertionReceiptPolicy.Snapshot?,
                                after: InsertionReceiptPolicy.Snapshot?) -> Self {
        guard let after else { return .unavailable }
        guard InsertionReceiptPolicy.isValid(after) else { return .invalidSnapshot }
        if let before, !InsertionReceiptPolicy.isValid(before) { return .invalidSnapshot }
        if let expected, !InsertionReceiptPolicy.isValid(expected) { return .invalidSnapshot }
        guard let before, let expected else { return .notComparable }

        // A collapsed or moved selection alone is not an observable text edit.
        // In particular, replacing selected text with identical text must not
        // be described as a positive match even if the expected caret agrees.
        if InsertionReceiptPolicy.sameText(before.text, after.text) { return .unchanged }
        guard InsertionReceiptPolicy.sameText(expected.text, after.text) else { return .textMismatch }
        return expected.selection == after.selection ? .matches : .selectionMismatch
    }

    public struct SpanComparison: Equatable, Sendable {
        public let prefixMatches: Bool
        public let insertedMatches: Bool
        public let suffixMatches: Bool
        public let observedSuffixUTF16: Int

        public init(prefixMatches: Bool, insertedMatches: Bool,
                    suffixMatches: Bool, observedSuffixUTF16: Int) {
            self.prefixMatches = prefixMatches
            self.insertedMatches = insertedMatches
            self.suffixMatches = suffixMatches
            self.observedSuffixUTF16 = observedSuffixUTF16
        }
    }

    public static func compareSpans(before: InsertionReceiptPolicy.Snapshot?,
                                    inserted: String,
                                    after: InsertionReceiptPolicy.Snapshot?) -> SpanComparison? {
        guard let before, let after,
              !inserted.isEmpty,
              InsertionReceiptPolicy.isValid(before),
              InsertionReceiptPolicy.isValid(after) else { return nil }
        let beforeUnits = Array(before.text.utf16)
        let insertedUnits = Array(inserted.utf16)
        let afterUnits = Array(after.text.utf16)
        let prefixCount = before.selection.location
        let expectedPrefix = Array(beforeUnits.prefix(prefixCount))
        let expectedSuffix = Array(beforeUnits.suffix(from: prefixCount + before.selection.length))
        let prefixMatches = afterUnits.count >= prefixCount
            && Array(afterUnits.prefix(prefixCount)) == expectedPrefix
        let confirmedCount = prefixCount + insertedUnits.count
        let insertedMatches = afterUnits.count >= confirmedCount
            && Array(afterUnits[prefixCount..<confirmedCount]) == insertedUnits
        let observedSuffix = afterUnits.count >= confirmedCount
            ? Array(afterUnits.suffix(from: confirmedCount))
            : []
        let suffixMatches = afterUnits.count >= confirmedCount && observedSuffix == expectedSuffix
        let observedSuffixUTF16 = max(0, afterUnits.count - confirmedCount)
        return SpanComparison(prefixMatches: prefixMatches,
                              insertedMatches: insertedMatches,
                              suffixMatches: suffixMatches,
                              observedSuffixUTF16: observedSuffixUTF16)
    }
}
