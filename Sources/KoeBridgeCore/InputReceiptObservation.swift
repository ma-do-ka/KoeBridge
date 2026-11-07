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
}
