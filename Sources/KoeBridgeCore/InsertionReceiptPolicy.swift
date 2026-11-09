import Foundation

/// Exact, local-only evidence for advancing another recording's input position.
/// UTF-16 offsets match AXSelectedTextRange; String.count does not.
public enum InsertionReceiptPolicy {
    public static let maximumObservableUTF16Count = 200_000

    public struct Selection: Equatable, Sendable {
        public let location: Int
        public let length: Int

        public init(location: Int, length: Int) {
            self.location = location
            self.length = length
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let text: String
        public let selection: Selection

        public init(text: String, selection: Selection) {
            self.text = text
            self.selection = selection
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.selection == rhs.selection && InsertionReceiptPolicy.sameText(lhs.text, rhs.text)
        }
    }

    public struct Receipt: Equatable, Sendable {
        public let before: Snapshot
        public let after: Snapshot
        public let inserted: String

        fileprivate init(before: Snapshot, after: Snapshot, inserted: String) {
            self.before = before
            self.after = after
            self.inserted = inserted
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.before == rhs.before && lhs.after == rhs.after
                && InsertionReceiptPolicy.sameText(lhs.inserted, rhs.inserted)
        }
    }

    public struct VerificationPlan: Sendable {
        public let before: Snapshot
        public let inserted: String
        public let expected: Snapshot

        fileprivate init(before: Snapshot, inserted: String, expected: Snapshot) {
            self.before = before
            self.inserted = inserted
            self.expected = expected
        }
    }

    public enum Reconciliation: Equatable, Sendable {
        case unchanged
        case rebased(Snapshot)
        case blocked
    }

    /// Swift String equality accepts canonically equivalent spellings. An AX
    /// position belongs to the actual UTF-16 representation, so compare units.
    public static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    public static func isValid(_ snapshot: Snapshot) -> Bool {
        let units = Array(snapshot.text.utf16)
        let range = snapshot.selection
        guard units.count <= maximumObservableUTF16Count,
              range.location >= 0, range.length >= 0,
              range.location <= units.count,
              range.length <= units.count - range.location else { return false }
        return isScalarBoundary(range.location, in: units)
            && isScalarBoundary(range.location + range.length, in: units)
    }

    /// `inserted` must be the text actually submitted to the transport, after
    /// UnicodeTypingPlan.safeText has removed action keys and control bytes.
    public static func expectedAfter(before: Snapshot, inserted: String) -> Snapshot? {
        guard !inserted.isEmpty, isValid(before) else { return nil }
        return replacingSelection(before, with: Array(inserted.utf16))
    }

    public static func verificationPlan(before: Snapshot, inserted: String) -> VerificationPlan? {
        guard let expected = expectedAfter(before: before, inserted: inserted) else { return nil }
        return VerificationPlan(before: before, inserted: inserted, expected: expected)
    }

    public static func verify(_ plan: VerificationPlan, after: Snapshot?,
                              sameTarget: Bool, cancelled: Bool = false) -> Receipt? {
        guard sameTarget, !cancelled, let after,
              plan.expected == after,
              // Replacing selected text with the identical text has no visible
              // text edit to attribute to us. A collapsed selection alone is
              // insufficient evidence that the receiving app accepted input.
              !sameText(plan.before.text, after.text) else { return nil }
        return Receipt(before: plan.before, after: after, inserted: plan.inserted)
    }

    public static func verify(before: Snapshot, inserted: String, after: Snapshot?,
                              sameTarget: Bool, cancelled: Bool = false) -> Receipt? {
        guard let plan = verificationPlan(before: before, inserted: inserted) else { return nil }
        return verify(plan, after: after, sameTarget: sameTarget, cancelled: cancelled)
    }

    /// Reconcile only a concurrent recording for the exact same target. A
    /// posted-but-unverified edit blocks that chain even when the old caret
    /// still looks unchanged: the event may be applied later. Never retry it.
    public static func reconcile(_ candidate: Snapshot?, using receipt: Receipt?,
                                 sameTarget: Bool, eventsPosted: Bool,
                                 mayShareTarget: Bool = false,
                                 capturedDuringSubmission: Bool = false,
                                 cancelled: Bool = false) -> Reconciliation {
        guard eventsPosted else { return .unchanged }
        // Missing window identity is not proof of an unrelated field. It may
        // block an uncertain chain, but it must not authorize positive rebase.
        guard sameTarget else { return mayShareTarget ? .blocked : .unchanged }
        guard !cancelled, let receipt, let candidate, isValid(candidate) else { return .blocked }
        if candidate == receipt.before || candidate == receipt.after {
            return .rebased(receipt.after)
        }
        // A new take can start while the editor is consuming an earlier
        // batch of Unicode events. Accept only the exact prefix edit, and
        // only when its capture occurred inside that submission's interval.
        guard capturedDuringSubmission,
              isIntermediate(candidate, of: receipt) else { return .blocked }
        return .rebased(receipt.after)
    }

    private static func isIntermediate(_ candidate: Snapshot, of receipt: Receipt) -> Bool {
        let untouchedCount = receipt.before.text.utf16.count - receipt.before.selection.length
        let prefixCount = candidate.text.utf16.count - untouchedCount
        let insertedUnits = Array(receipt.inserted.utf16)
        guard prefixCount >= 0, prefixCount < insertedUnits.count,
              isScalarBoundary(prefixCount, in: insertedUnits),
              let expected = replacingSelection(receipt.before,
                                                 with: Array(insertedUnits.prefix(prefixCount))) else { return false }
        return expected == candidate
    }

    private static func replacingSelection(_ before: Snapshot, with inserted: [UInt16]) -> Snapshot? {
        let units = Array(before.text.utf16)
        let range = before.selection
        let remainingCount = units.count - range.length
        guard inserted.count <= maximumObservableUTF16Count - remainingCount else { return nil }
        var output = Array(units.prefix(range.location))
        output.append(contentsOf: inserted)
        output.append(contentsOf: units.suffix(from: range.location + range.length))
        return Snapshot(text: String(decoding: output, as: UTF16.self),
                        selection: Selection(location: range.location + inserted.count, length: 0))
    }

    private static func isScalarBoundary(_ offset: Int, in units: [UInt16]) -> Bool {
        guard offset >= 0, offset <= units.count else { return false }
        guard offset > 0, offset < units.count else { return true }
        return !(0xD800...0xDBFF).contains(units[offset - 1])
            || !(0xDC00...0xDFFF).contains(units[offset])
    }
}
