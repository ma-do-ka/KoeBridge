import Testing
@testable import KoeBridgeCore

struct InputReceiptObservationTests {
    private typealias Observation = InputReceiptObservation
    private typealias Policy = InsertionReceiptPolicy
    private typealias Snapshot = InsertionReceiptPolicy.Snapshot

    private func state(_ text: String, _ location: Int, _ length: Int = 0) -> Snapshot {
        Snapshot(text: text, selection: .init(location: location, length: length))
    }

    @Test func missingReadbackDoesNotInventAnOutcome() {
        #expect(Observation.classify(before: state("", 0), expected: state("本文", 2),
                                     after: nil) == .unavailable)
        #expect(Observation.classify(before: nil, expected: nil, after: nil) == .unavailable)
    }

    @Test func missingBaselineOrExpectationIsNotComparable() {
        let before = state("", 0)
        let after = state("本文", 2)
        #expect(Observation.classify(before: nil, expected: after, after: after) == .notComparable)
        #expect(Observation.classify(before: before, expected: nil, after: after) == .notComparable)
        #expect(Observation.classify(before: nil, expected: nil, after: after) == .notComparable)
    }

    @Test func invalidUTF16RangesNeverBecomeTextOrSelectionMismatches() {
        let before = state("旧文", 2)
        let expected = state("旧文😀", 4)
        let invalid = [
            state("😀A", -1), state("😀A", 0, -1), state("😀A", Int.max),
            state("😀A", 0, Int.max), state("😀A", 1), state("😀A", 0, 1),
            state("😀A", 4),
            state(String(repeating: "x", count: Policy.maximumObservableUTF16Count + 1), 0)
        ]
        for snapshot in invalid {
            #expect(Observation.classify(before: before, expected: expected, after: snapshot) == .invalidSnapshot)
            #expect(Observation.classify(before: snapshot, expected: expected, after: expected) == .invalidSnapshot)
            #expect(Observation.classify(before: before, expected: snapshot, after: expected) == .invalidSnapshot)
        }
    }

    @Test func unchangedTextWinsOverIdenticalReplacementAndCaretMovement() throws {
        let before = state("同じ😀文", 0, 5)
        let expected = try #require(Policy.expectedAfter(before: before, inserted: before.text))
        #expect(expected.selection == .init(location: 5, length: 0))
        #expect(Observation.classify(before: before, expected: expected, after: before) == .unchanged)
        #expect(Observation.classify(before: before, expected: expected, after: expected) == .unchanged)
        #expect(Observation.classify(before: before, expected: expected,
                                     after: state(before.text, 2)) == .unchanged)
        #expect(Policy.verify(before: before, inserted: before.text, after: expected, sameTarget: true) == nil)
    }

    @Test func exactEmojiReplacementMatchesTheActualUTF16Caret() throws {
        let before = state("A旧文😀Z", 1, 4)
        let inserted = "予定👩🏽‍💻"
        let expected = try #require(Policy.expectedAfter(before: before, inserted: inserted))
        let after = state("A" + inserted + "Z", 1 + inserted.utf16.count)
        #expect(Observation.classify(before: before, expected: expected, after: after) == .matches)
        #expect(Policy.verify(before: before, inserted: inserted, after: after, sameTarget: true) != nil)
    }

    @Test func matchingTextStillDistinguishesCaretAndSelectionChanges() throws {
        let before = state("aaaa", 2)
        let expected = try #require(Policy.expectedAfter(before: before, inserted: "a"))
        #expect(Observation.classify(before: before, expected: expected,
                                     after: state("aaaaa", 3)) == .matches)
        for location in [0, 1, 2, 4, 5] {
            #expect(Observation.classify(before: before, expected: expected,
                                         after: state("aaaaa", location)) == .selectionMismatch)
        }
        #expect(Observation.classify(before: before, expected: expected,
                                     after: state("aaaaa", 3, 1)) == .selectionMismatch)
    }

    @Test func normalizationAndOtherTextChangesRemainExact() {
        let before = state(">", 1)
        let expected = state(">e\u{301}😀", 5)
        let normalized = state(">é😀", 4)
        #expect(expected.text == normalized.text)
        #expect(!Policy.sameText(expected.text, normalized.text))
        #expect(Observation.classify(before: before, expected: expected, after: normalized) == .textMismatch)
        #expect(Observation.classify(before: before, expected: expected,
                                     after: state(">e\u{301}😀!", 5)) == .textMismatch)
        #expect(Observation.classify(before: state("e\u{301}", 2), expected: state("e\u{301}!", 3),
                                     after: state("é", 1)) == .textMismatch)
    }

    @Test func diagnosticMatchDoesNotReplaceTheRealReceiptGuards() {
        let before = state("", 0)
        let after = state("本文", 2)
        #expect(Observation.classify(before: before, expected: after, after: after) == .matches)
        #expect(Policy.verify(before: before, inserted: "本文", after: after, sameTarget: false) == nil)
        #expect(Policy.verify(before: before, inserted: "本文", after: after,
                              sameTarget: true, cancelled: true) == nil)
    }
}
