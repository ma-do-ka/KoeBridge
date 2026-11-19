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

    public enum VerificationMode: String, Equatable, Sendable {
        case strict = "strict_value_and_selection"
        case trailingNewlineNormalized = "trailing_newline_normalized"
        case blockScoped = "block_scoped_prefix_and_selection"
    }

    public struct Receipt: Equatable, Sendable {
        public let before: Snapshot
        public let after: Snapshot
        public let inserted: String
        public let mode: VerificationMode

        fileprivate init(before: Snapshot, after: Snapshot, inserted: String,
                         mode: VerificationMode = .strict) {
            self.before = before
            self.after = after
            self.inserted = inserted
            self.mode = mode
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.before == rhs.before && lhs.after == rhs.after
                && InsertionReceiptPolicy.sameText(lhs.inserted, rhs.inserted)
                && lhs.mode == rhs.mode
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

    public static func verify(before: Snapshot, inserted: String, after: Snapshot?,
                              sameTarget: Bool, cancelled: Bool = false) -> Receipt? {
        guard sameTarget, !cancelled,
              let after, isValid(after),
              let expected = expectedAfter(before: before, inserted: inserted),
              // Replacing selected text with the identical text has no visible
              // text edit to attribute to us. A collapsed selection alone is
              // insufficient evidence that the receiving app accepted input.
              !sameText(before.text, after.text) else { return nil }
        if expected == after {
            return Receipt(before: before, after: after, inserted: inserted, mode: .strict)
        }
        // Only collapsed-caret insertions qualify for trailing-newline normalization
        // or block-scoped AX read-back acceptance. Selection replacements remain strict.
        guard before.selection.length == 0,
              expected.selection == after.selection else { return nil }
        let beforeUnits = Array(before.text.utf16)
        let insertedUnits = Array(inserted.utf16)
        let afterUnits = Array(after.text.utf16)
        let prefixCount = before.selection.location
        let confirmedCount = prefixCount + insertedUnits.count
        guard afterUnits.count >= confirmedCount,
              Array(afterUnits.prefix(prefixCount)) == Array(beforeUnits.prefix(prefixCount)),
              Array(afterUnits[prefixCount..<confirmedCount]) == insertedUnits else { return nil }
        let beforeSuffix = Array(beforeUnits.suffix(from: prefixCount))
        guard !beforeSuffix.isEmpty else { return nil }
        let afterSuffix = Array(afterUnits.suffix(from: confirmedCount))
        // Branch (b): Block-scoped AX read-back where the active paragraph node
        // following the insertion contains only prefix + inserted and trailing
        // paragraphs live in sibling AX nodes omitted from the active node's AXValue.
        if afterSuffix.isEmpty {
            return Receipt(before: before, after: after, inserted: inserted, mode: .blockScoped)
        }
        // Branch (a): Trailing-newline normalization where the editor strips or
        // collapses up to 2 trailing newline code units (\n or \r) at the end of
        // a non-empty suffix while preserving every non-newline suffix unit.
        if stripTrailingNewlines(beforeSuffix, maxUnits: 2) == stripTrailingNewlines(afterSuffix, maxUnits: 2) {
            return Receipt(before: before, after: after, inserted: inserted, mode: .trailingNewlineNormalized)
        }
        return nil
    }

    private static func stripTrailingNewlines(_ units: [UInt16], maxUnits: Int) -> [UInt16] {
        var end = units.count
        var stripped = 0
        while end > 0, stripped < maxUnits {
            let unit = units[end - 1]
            guard unit == 0x000A || unit == 0x000D else { break }
            end -= 1
            stripped += 1
        }
        return Array(units.prefix(end))
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

    public enum SettledUnconfirmedOperation: Equatable, Sendable {
        case dictation
        case command
        case transform
    }

    /// Evaluate whether a follow-up operation may proceed after an unconfirmed predecessor
    /// on the same target (Mode B) or after moving to a different target (target-scoped latch).
    /// - Target-scoped latch: if `freshMatchesBlockedStart == false`, `hasHardUnverifiedPredecessorOnFresh == false`,
    ///   and `hasSettledUnconfirmedPredecessorOnFresh == false`, moving to an unrelated field is permitted.
    /// - Settled unconfirmed predecessor (Mode B): applies ONLY to `.dictation` when all events of the
    ///   predecessor were posted without post-send focus drift on a target where exact baseline/receipt
    ///   verification is structurally unavailable (`predecessorExactBaselineAvailable == false`),
    ///   at least 150 ms have elapsed since predecessor completion, and two bracketed reads separated
    ///   by 35 ms confirm both identical element/window/owner identity AND identical selection/marker state.
    /// - Voice commands (`.command`) and transforms (`.transform`) always keep the strict rule.
    public static func mayProceedWithPredecessorState(operation: SettledUnconfirmedOperation,
                                                      startBlocked: Bool,
                                                      freshMatchesStart: Bool,
                                                      hasHardUnverifiedPredecessorOnFresh: Bool,
                                                      hasSettledUnconfirmedPredecessorOnFresh: Bool,
                                                      predecessorAllEventsPosted: Bool = true,
                                                      predecessorPostSendFocusOK: Bool = true,
                                                      predecessorExactBaselineAvailable: Bool = false,
                                                      elapsedSincePredecessorSeconds: Double = 0,
                                                      firstBracketedIdentityMatches: Bool = false,
                                                      secondBracketedIdentityMatches: Bool = false,
                                                      bracketedSelectionStable: Bool = false) -> Bool {
        if hasHardUnverifiedPredecessorOnFresh { return false }
        let startBlocksFresh = startBlocked && freshMatchesStart
        if !startBlocksFresh && !hasSettledUnconfirmedPredecessorOnFresh {
            return true
        }
        guard operation == .dictation,
              hasSettledUnconfirmedPredecessorOnFresh,
              predecessorAllEventsPosted,
              predecessorPostSendFocusOK,
              !predecessorExactBaselineAvailable,
              elapsedSincePredecessorSeconds >= 0.150,
              firstBracketedIdentityMatches,
              secondBracketedIdentityMatches,
              bracketedSelectionStable else {
            return false
        }
        return true
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
