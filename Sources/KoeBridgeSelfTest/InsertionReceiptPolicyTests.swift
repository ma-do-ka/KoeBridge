import Foundation
import KoeBridgeCore

struct InsertionReceiptPolicyTests {
    private typealias Policy = InsertionReceiptPolicy
    private typealias Snapshot = InsertionReceiptPolicy.Snapshot

    private func state(_ text: String, _ location: Int, _ length: Int = 0) -> Snapshot {
        Snapshot(text: text, selection: .init(location: location, length: length))
    }

    func verifiesJapaneseAtTheActualUTF16Caret() throws {
        let before = state("📎案：", 4)
        let after = state("📎案：明日", 6)
        let receipt = try require(Policy.verify(before: before, inserted: "明日", after: after, sameTarget: true))
        check(receipt.before == before)
        check(receipt.after == after)
        check(Policy.reconcile(before, using: receipt, sameTarget: true, eventsPosted: true) == .rebased(after))
    }

    func preservesSelectionReplacementAndEmojiSuffix() throws {
        let before = state("A旧文😀Z", 1, 4)
        let inserted = "予定👨‍👩‍👧‍👦"
        let after = state("A" + inserted + "Z", 1 + inserted.utf16.count)
        let receipt = try require(Policy.verify(before: before, inserted: inserted, after: after, sameTarget: true))
        check(Policy.reconcile(before, using: receipt, sameTarget: true, eventsPosted: true) == .rebased(after))
        check(Policy.reconcile(after, using: receipt, sameTarget: true, eventsPosted: true) == .rebased(after))
    }

    func repeatedTextStillRequiresTheCorrectPosition() throws {
        let before = state("aaaa", 2)
        let receipt = try require(Policy.verify(before: before, inserted: "a", after: state("aaaaa", 3), sameTarget: true))
        for wrongCaret in [0, 1, 2, 4, 5] {
            check(Policy.verify(before: before, inserted: "a", after: state("aaaaa", wrongCaret), sameTarget: true) == nil)
        }
        check(Policy.reconcile(state("aaaaa", 4), using: receipt, sameTarget: true, eventsPosted: true) == .blocked)
    }

    func canonicalEquivalenceCannotAuthorizeUTF16Offsets() throws {
        let before = state("e\u{301}終", 2)
        let exact = state("e\u{301}😀終", 4)
        let composed = state("é😀終", 4)
        check(exact.text == composed.text)
        check(!Policy.sameText(exact.text, composed.text))
        check(exact != composed)
        check(Policy.verify(before: before, inserted: "😀", after: composed, sameTarget: true) == nil)
        let receipt = try require(Policy.verify(before: before, inserted: "😀", after: exact, sameTarget: true))
        check(Policy.reconcile(composed, using: receipt, sameTarget: true, eventsPosted: true) == .blocked)
    }

    func invalidOrSplitSurrogateRangesAreRejected() {
        let invalid = [state("😀A", -1), state("😀A", Int.max),
                       state("😀A", 0, Int.max), state("😀A", 1),
                       state("😀A", 0, 1), state("😀A", 4)]
        for snapshot in invalid {
            check(!Policy.isValid(snapshot))
            check(Policy.expectedAfter(before: snapshot, inserted: "x") == nil)
        }
        check(Policy.expectedAfter(before: state("😀A", 2), inserted: "x") == state("😀xA", 3))
    }

    func rebasesCapturesBeforeDuringAndAfterSubmission() throws {
        let before = state("headOLDtail", 4, 3)
        let after = state("head一二😀三tail", 9)
        let receipt = try require(Policy.verify(before: before, inserted: "一二😀三", after: after, sameTarget: true))
        for candidate in [before, after] {
            check(Policy.reconcile(candidate, using: receipt, sameTarget: true, eventsPosted: true) == .rebased(after))
        }
        for candidate in [state("headtail", 4), state("head一二tail", 6), state("head一二😀tail", 8)] {
            check(Policy.reconcile(candidate, using: receipt, sameTarget: true, eventsPosted: true,
                                   capturedDuringSubmission: true) == .rebased(after))
            check(Policy.reconcile(candidate, using: receipt, sameTarget: true, eventsPosted: true,
                                   capturedDuringSubmission: false) == .blocked)
        }
    }

    func humanEditsOrFocusChangesDoNotBecomeOwnInput() throws {
        let before = state("abcDEFghi", 3, 3)
        let after = state("abcXYZghi", 6)
        let receipt = try require(Policy.verify(before: before, inserted: "XYZ", after: after, sameTarget: true))
        for candidate in [state("abcXghi!", 4), state("abcXghi", 0), state("abcQghi", 4), state("abcXYZghi", 2)] {
            check(Policy.reconcile(candidate, using: receipt, sameTarget: true, eventsPosted: true,
                                   capturedDuringSubmission: true) == .blocked)
        }
        check(Policy.reconcile(before, using: receipt, sameTarget: false, eventsPosted: true) == .unchanged)
        check(Policy.verify(before: before, inserted: "XYZ", after: after, sameTarget: false) == nil)
        check(Policy.verify(before: before, inserted: "XYZ", after: state("abcXYZghi!", 6), sameTarget: true) == nil)
    }

    func chainsThreeRepeatedTakesWithoutDroppingOrDuplicatingText() throws {
        var next = state("はい", 2)
        var third = next
        for expectedText in ["はいはい", "はいはいはい", "はいはいはいはい"] {
            let after = state(expectedText, expectedText.utf16.count)
            let receipt = try require(Policy.verify(before: next, inserted: "はい", after: after, sameTarget: true))
            let secondResult = Policy.reconcile(next, using: receipt, sameTarget: true, eventsPosted: true)
            let thirdResult = Policy.reconcile(third, using: receipt, sameTarget: true, eventsPosted: true)
            check(secondResult == .rebased(after))
            check(thirdResult == .rebased(after))
            if case .rebased(let updated) = secondResult { next = updated }
            if case .rebased(let updated) = thirdResult { third = updated }
        }
        check(next == state("はいはいはいはい", 8))
        check(third == next)
    }

    func unknownPartialOrCancelledDeliveryNeverUnlocksTheNextTake() throws {
        let before = state("", 0)
        let after = state("入力", 2)
        let receipt = try require(Policy.verify(before: before, inserted: "入力", after: after, sameTarget: true))
        check(Policy.reconcile(before, using: nil, sameTarget: true, eventsPosted: true) == .blocked)
        check(Policy.reconcile(state("入", 1), using: nil, sameTarget: true, eventsPosted: true,
                               capturedDuringSubmission: true) == .blocked)
        check(Policy.reconcile(nil, using: receipt, sameTarget: true, eventsPosted: true) == .blocked)
        check(Policy.reconcile(before, using: nil, sameTarget: true, eventsPosted: false) == .unchanged)
        check(Policy.reconcile(before, using: receipt, sameTarget: true, eventsPosted: true, cancelled: true) == .blocked)
        check(Policy.verify(before: before, inserted: "入力", after: after, sameTarget: true, cancelled: true) == nil)
    }

    func ambiguousWindowIdentityCannotUnlockAConcurrentTake() throws {
        let before = state("", 0)
        let receipt = try require(Policy.verify(before: before, inserted: "入力", after: state("入力", 2), sameTarget: true))
        // The pid/element agrees but only one capture has a readable window.
        check(Policy.reconcile(before, using: nil, sameTarget: false, eventsPosted: true,
                               mayShareTarget: true) == .blocked)
        check(Policy.reconcile(before, using: receipt, sameTarget: false, eventsPosted: true,
                               mayShareTarget: true) == .blocked)
        check(Policy.reconcile(before, using: nil, sameTarget: false, eventsPosted: false,
                               mayShareTarget: true) == .unchanged)
    }

    func identicalReplacementIsNotAnObservableTextReceipt() throws {
        let before = state("same", 0, 4)
        let after = try require(Policy.expectedAfter(before: before, inserted: "same"))
        check(after == state("same", 4))
        check(Policy.verify(before: before, inserted: "same", after: after, sameTarget: true) == nil)
        check(Policy.expectedAfter(before: before, inserted: "") == nil)
    }

    func verifiesOnlyTheSanitizedTransportText() throws {
        let original = "a\nb\tc\r\n"
        let safe = UnicodeTypingPlan.safeText(original)
        let before = state(">", 1)
        let after = state(">a b c ", 7)
        check(safe == "a b c ")
        _ = try require(Policy.verify(before: before, inserted: safe, after: after, sameTarget: true))
        check(Policy.verify(before: before, inserted: original, after: after, sameTarget: true) == nil)
    }

    func readbackSizeAndIntermediateScalarBoundariesAreBounded() throws {
        let maximum = Policy.maximumObservableUTF16Count
        let full = state(String(repeating: "x", count: maximum), maximum)
        check(Policy.isValid(full))
        check(Policy.expectedAfter(before: full, inserted: "x") == nil)
        check(!Policy.isValid(state(full.text + "x", maximum + 1)))
        let receipt = try require(Policy.verify(before: state("", 0), inserted: "😀A",
                                                after: state("😀A", 3), sameTarget: true))
        check(Policy.reconcile(state("X", 1), using: receipt, sameTarget: true, eventsPosted: true,
                               capturedDuringSubmission: true) == .blocked)
        check(Policy.reconcile(state("😀", 2), using: receipt, sameTarget: true, eventsPosted: true,
                               capturedDuringSubmission: true) == .rebased(state("😀A", 3)))
    }
}
