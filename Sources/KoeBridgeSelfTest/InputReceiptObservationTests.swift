import KoeBridgeCore

struct InputReceiptObservationTests {
    private typealias Observation = InputReceiptObservation
    private typealias Policy = InsertionReceiptPolicy
    private typealias Snapshot = InsertionReceiptPolicy.Snapshot

    private func state(_ text: String, _ location: Int, _ length: Int = 0) -> Snapshot {
        Snapshot(text: text, selection: .init(location: location, length: length))
    }

    func missingReadbackDoesNotInventAnOutcome() {
        check(Observation.classify(before: state("", 0), expected: state("本文", 2),
                                   after: nil) == .unavailable)
        check(Observation.classify(before: nil, expected: nil, after: nil) == .unavailable)
    }

    func missingBaselineOrExpectationIsNotComparable() {
        let before = state("", 0)
        let after = state("本文", 2)
        check(Observation.classify(before: nil, expected: after, after: after) == .notComparable)
        check(Observation.classify(before: before, expected: nil, after: after) == .notComparable)
        check(Observation.classify(before: nil, expected: nil, after: after) == .notComparable)
    }

    func invalidUTF16RangesNeverBecomeTextOrSelectionMismatches() {
        let before = state("旧文", 2)
        let expected = state("旧文😀", 4)
        let invalid = [
            state("😀A", -1), state("😀A", 0, -1), state("😀A", Int.max),
            state("😀A", 0, Int.max), state("😀A", 1), state("😀A", 0, 1),
            state("😀A", 4),
            state(String(repeating: "x", count: Policy.maximumObservableUTF16Count + 1), 0)
        ]
        for snapshot in invalid {
            check(Observation.classify(before: before, expected: expected, after: snapshot) == .invalidSnapshot)
            check(Observation.classify(before: snapshot, expected: expected, after: expected) == .invalidSnapshot)
            check(Observation.classify(before: before, expected: snapshot, after: expected) == .invalidSnapshot)
        }
    }

    func unchangedTextWinsOverIdenticalReplacementAndCaretMovement() throws {
        let before = state("同じ😀文", 0, 5)
        let expected = try require(Policy.expectedAfter(before: before, inserted: before.text))
        check(expected.selection == .init(location: 5, length: 0))
        check(Observation.classify(before: before, expected: expected, after: before) == .unchanged)
        check(Observation.classify(before: before, expected: expected, after: expected) == .unchanged)
        check(Observation.classify(before: before, expected: expected,
                                   after: state(before.text, 2)) == .unchanged)
        check(Policy.verify(before: before, inserted: before.text, after: expected, sameTarget: true, fieldNature: .normal) == nil)
    }

    func exactEmojiReplacementMatchesTheActualUTF16Caret() throws {
        let before = state("A旧文😀Z", 1, 4)
        let inserted = "予定👩🏽‍💻"
        let expected = try require(Policy.expectedAfter(before: before, inserted: inserted))
        let after = state("A" + inserted + "Z", 1 + inserted.utf16.count)
        check(Observation.classify(before: before, expected: expected, after: after) == .matches)
        check(Policy.verify(before: before, inserted: inserted, after: after, sameTarget: true, fieldNature: .normal) != nil)
    }

    func matchingTextStillDistinguishesCaretAndSelectionChanges() throws {
        let before = state("aaaa", 2)
        let expected = try require(Policy.expectedAfter(before: before, inserted: "a"))
        check(Observation.classify(before: before, expected: expected,
                                   after: state("aaaaa", 3)) == .matches)
        for location in [0, 1, 2, 4, 5] {
            check(Observation.classify(before: before, expected: expected,
                                       after: state("aaaaa", location)) == .selectionMismatch)
        }
        check(Observation.classify(before: before, expected: expected,
                                   after: state("aaaaa", 3, 1)) == .selectionMismatch)
    }

    func normalizationAndOtherTextChangesRemainExact() {
        let before = state(">", 1)
        let expected = state(">e\u{301}😀", 5)
        let normalized = state(">é😀", 4)
        check(expected.text == normalized.text)
        check(!Policy.sameText(expected.text, normalized.text))
        check(Observation.classify(before: before, expected: expected, after: normalized) == .textMismatch)
        check(Observation.classify(before: before, expected: expected,
                                   after: state(">e\u{301}😀!", 5)) == .textMismatch)
        check(Observation.classify(before: state("e\u{301}", 2), expected: state("e\u{301}!", 3),
                                   after: state("é", 1)) == .textMismatch)
    }

    func diagnosticMatchDoesNotReplaceTheRealReceiptGuards() {
        let before = state("", 0)
        let after = state("本文", 2)
        check(Observation.classify(before: before, expected: after, after: after) == .matches)
        check(Policy.verify(before: before, inserted: "本文", after: after, sameTarget: false, fieldNature: .normal) == nil)
        check(Policy.verify(before: before, inserted: "本文", after: after,
                            sameTarget: true, cancelled: true, fieldNature: .normal) == nil)
    }

    func spanComparisonRemainsContentFreeAndDistinguishesMismatches() {
        let before = state("前置きSECRET後続段落", 3)
        // Exact match
        let exact = Observation.compareSpans(before: before, inserted: "挿入",
                                             after: state("前置き挿入SECRET後続段落", 5))
        check(exact == .init(prefixMatches: true, insertedMatches: true,
                             suffixMatches: true, observedSuffixUTF16: 10))
        // Block-scoped read-back (0 suffix units returned)
        let blockScoped = Observation.compareSpans(before: before, inserted: "挿入",
                                                   after: state("前置き挿入", 5))
        check(blockScoped == .init(prefixMatches: true, insertedMatches: true,
                                   suffixMatches: false, observedSuffixUTF16: 0))
        // Trailing newline stripped
        let beforeNL = state("前置き後続\n", 3)
        let nlStripped = Observation.compareSpans(before: beforeNL, inserted: "挿入",
                                                  after: state("前置き挿入後続", 5))
        check(nlStripped == .init(prefixMatches: true, insertedMatches: true,
                                  suffixMatches: false, observedSuffixUTF16: 2))
        // Prefix or inserted mismatch
        let badPrefix = Observation.compareSpans(before: before, inserted: "挿入",
                                                 after: state("別置き挿入SECRET後続段落", 5))
        check(badPrefix == .init(prefixMatches: false, insertedMatches: true,
                                 suffixMatches: true, observedSuffixUTF16: 10))
        let badInserted = Observation.compareSpans(before: before, inserted: "挿入",
                                                   after: state("前置き別文SECRET後続段落", 5))
        check(badInserted == .init(prefixMatches: true, insertedMatches: false,
                                   suffixMatches: true, observedSuffixUTF16: 10))
        // Invalid or empty inputs return nil
        check(Observation.compareSpans(before: nil, inserted: "挿入", after: state("挿入", 2)) == nil)
        check(Observation.compareSpans(before: before, inserted: "", after: before) == nil)
        check(Observation.compareSpans(before: before, inserted: "挿入", after: state("😀", 1)) == nil)

        // Verify diagnostic event fields render content-free flags, integer counts, and receipt_mode tokens
        for mode in [Policy.VerificationMode.strict, .trailingNewlineNormalized, .blockScoped] {
            let event = InputDiagnosticEvent(kind: .result, stage: .result, fields: [
                .outcome: .token(.verified),
                .reason: .reason("verified_value_and_selection"),
                .receiptMode: .reason(mode.rawValue),
                .prefixMatches: .flag(true),
                .insertedMatches: .flag(true),
                .suffixMatches: .flag(mode == .strict),
                .observedSuffixUTF16: .integer(mode == .blockScoped ? 0 : 9)
            ])
            check(event.fields[.receiptMode] != .token(.unknown))
            var buffer = InputDiagnosticBuffer(takeID: .init())
            buffer.append(event, elapsedMS: 120)
            let rendered = buffer.renderedLines().joined(separator: "\n")
            check(rendered.contains("receipt_mode=\(mode.rawValue)"))
            check(rendered.contains("prefix_matches=1"))
            check(rendered.contains("inserted_matches=1"))
            check(!rendered.contains("SECRET"))
        }
    }
}
