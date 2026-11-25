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
        check(receipt.mode == .strict)
    }

    func blockScopedAndTrailingNewlineNormalizedReceiptsVerifyAndReconcileSafely() throws {
        // 1. Block-scoped AX read-back at caret 0 with 9 UTF-16 units below (exact 0ebd1d92 shape).
        let suffix9 = "123456789"
        let inserted26 = String(repeating: "あ", count: 26)
        let beforeCaret0 = state(suffix9, 0)
        let afterBlock0 = state(inserted26, 26)
        let receiptBlock0 = try require(Policy.verify(before: beforeCaret0, inserted: inserted26,
                                                      after: afterBlock0, sameTarget: true))
        check(receiptBlock0.mode == .blockScoped)
        check(receiptBlock0.after == afterBlock0)
        // Reconcile accepts before or observed block-scoped after, and blocks unverified full expectedAfter (I5).
        let fullAfter0 = try require(Policy.expectedAfter(before: beforeCaret0, inserted: inserted26))
        check(Policy.reconcile(beforeCaret0, using: receiptBlock0, sameTarget: true, eventsPosted: true) == .rebased(afterBlock0))
        check(Policy.reconcile(afterBlock0, using: receiptBlock0, sameTarget: true, eventsPosted: true) == .rebased(afterBlock0))
        check(Policy.reconcile(fullAfter0, using: receiptBlock0, sameTarget: true, eventsPosted: true) == .blocked)
        // Reviewer probe I5: before = "pZ"@1, inserted = "X", observed = "pX"@2 (block-scoped), candidate = "pXZ"@2 -> .blocked.
        let probeReceiptI5 = try require(Policy.verify(before: state("pZ", 1), inserted: "X",
                                                       after: state("pX", 2), sameTarget: true))
        check(probeReceiptI5.mode == .blockScoped)
        check(Policy.reconcile(state("pXZ", 2), using: probeReceiptI5, sameTarget: true,
                               eventsPosted: true, capturedDuringSubmission: false) == .blocked)
        check(Policy.reconcile(state("pX", 2), using: probeReceiptI5, sameTarget: true,
                               eventsPosted: true, capturedDuringSubmission: false) == .rebased(state("pX", 2)))

        // 2. Block-scoped AX read-back at non-zero prefix (location 5) with 12 UTF-16 units below.
        let beforeMid = state("アイウエオ\nカキクケコサシスセソタ", 5)
        let inserted10 = "０１２３４５６７８９"
        let afterMidBlock = state("アイウエオ" + inserted10, 15)
        let receiptMid = try require(Policy.verify(before: beforeMid, inserted: inserted10,
                                                   after: afterMidBlock, sameTarget: true))
        check(receiptMid.mode == .blockScoped)

        // 3. Trailing-newline normalization (\n stripped, \r\n stripped, up to 2 trailing newline code units).
        let beforeTrailingLF = state("先行テキスト\n後続段落\n", 6)
        let afterStrippedLF = state("先行テキスト追加文\n後続段落", 9)
        let receiptLF = try require(Policy.verify(before: beforeTrailingLF, inserted: "追加文",
                                                  after: afterStrippedLF, sameTarget: true))
        check(receiptLF.mode == .trailingNewlineNormalized)

        let beforeTrailingCRLF = state("A\nB\r\n", 1)
        let afterStrippedCRLF = state("AX\nB", 2)
        let receiptCRLF = try require(Policy.verify(before: beforeTrailingCRLF, inserted: "X",
                                                    after: afterStrippedCRLF, sameTarget: true))
        check(receiptCRLF.mode == .trailingNewlineNormalized)

        // 4. Legitimate failure cases must still fail closed (return nil):
        // (a) Non-newline suffix character mutated or truncated ("abc" -> "ab").
        check(Policy.verify(before: state("headabc", 4), inserted: "INS",
                            after: state("headINSab", 7), sameTarget: true) == nil)
        // (b) Partial suffix truncation when observed suffix is non-empty ("123456789" -> "1234").
        check(Policy.verify(before: beforeCaret0, inserted: inserted26,
                            after: state(inserted26 + "1234", 26), sameTarget: true) == nil)
        // (c) Prefix mismatch before caret.
        check(Policy.verify(before: state("ABCDtail", 4), inserted: "XY",
                            after: state("ABCE" + "XY", 6), sameTarget: true) == nil)
        // (d) Inserted span mismatch.
        check(Policy.verify(before: beforeCaret0, inserted: "期待文",
                            after: state("別テキスト", 3), sameTarget: true) == nil)
        // (e) Caret location mismatch even when block-scoped text matches.
        check(Policy.verify(before: beforeCaret0, inserted: inserted26,
                            after: state(inserted26, 25), sameTarget: true) == nil)
        check(Policy.verify(before: beforeCaret0, inserted: inserted26,
                            after: state(inserted26, 26, 1), sameTarget: true) == nil)
        // (f) Non-zero initial selection (selection replacement) requires strict suffix preservation.
        check(Policy.verify(before: state("ABCDtail", 0, 4), inserted: "XY",
                            after: state("XY", 2), sameTarget: true) == nil)
        check(Policy.verify(before: state("ABCDtail\n", 0, 4), inserted: "XY",
                            after: state("XYtail", 2), sameTarget: true) == nil)
        // (g) More than 2 trailing newlines stripped fails closed.
        check(Policy.verify(before: state("A\nB\n\n\n", 1), inserted: "X",
                            after: state("AX\nB", 2), sameTarget: true) == nil)
    }

    func settledUnconfirmedPredecessorAndTargetScopedLatchGateFollowUpTakes() {
        // 1. Target-scoped latch: moving to an unrelated field B when start was blocked on field A is permitted.
        check(Policy.mayProceedWithPredecessorState(
            operation: .dictation,
            startBlocked: true,
            freshMatchesStart: false,
            hasHardUnverifiedPredecessorOnFresh: false,
            hasSettledUnconfirmedPredecessorOnFresh: false))

        // 2. Staying on blocked field A without settled unconfirmed predecessor blocks.
        check(!Policy.mayProceedWithPredecessorState(
            operation: .dictation,
            startBlocked: true,
            freshMatchesStart: true,
            hasHardUnverifiedPredecessorOnFresh: false,
            hasSettledUnconfirmedPredecessorOnFresh: false))

        // 3. Hard unverified predecessor on fresh always blocks even if settled unconfirmed also present.
        check(!Policy.mayProceedWithPredecessorState(
            operation: .dictation,
            startBlocked: false,
            freshMatchesStart: false,
            hasHardUnverifiedPredecessorOnFresh: true,
            hasSettledUnconfirmedPredecessorOnFresh: true,
            predecessorAllEventsPosted: true,
            predecessorPostSendFocusOK: true,
            predecessorExactBaselineAvailable: false,
            elapsedSincePredecessorSeconds: 0.200,
            firstBracketedIdentityMatches: true,
            secondBracketedIdentityMatches: true,
            bracketedSelectionStable: true))

        // 4. Settled marker-only predecessor unblocks follow-up dictation when >= 150ms elapsed
        //    and two bracketed reads separated by 35ms confirm identity AND selection stability.
        check(Policy.mayProceedWithPredecessorState(
            operation: .dictation,
            startBlocked: true,
            freshMatchesStart: true,
            hasHardUnverifiedPredecessorOnFresh: false,
            hasSettledUnconfirmedPredecessorOnFresh: true,
            predecessorAllEventsPosted: true,
            predecessorPostSendFocusOK: true,
            predecessorExactBaselineAvailable: false,
            elapsedSincePredecessorSeconds: 0.150,
            firstBracketedIdentityMatches: true,
            secondBracketedIdentityMatches: true,
            bracketedSelectionStable: true))

        // 5. Elapsed < 150ms fails closed.
        check(!Policy.mayProceedWithPredecessorState(
            operation: .dictation,
            startBlocked: true,
            freshMatchesStart: true,
            hasHardUnverifiedPredecessorOnFresh: false,
            hasSettledUnconfirmedPredecessorOnFresh: true,
            predecessorAllEventsPosted: true,
            predecessorPostSendFocusOK: true,
            predecessorExactBaselineAvailable: false,
            elapsedSincePredecessorSeconds: 0.149,
            firstBracketedIdentityMatches: true,
            secondBracketedIdentityMatches: true,
            bracketedSelectionStable: true))

        // 6. Bracketed read 1 or read 2 identity mismatch fails closed.
        check(!Policy.mayProceedWithPredecessorState(
            operation: .dictation,
            startBlocked: true,
            freshMatchesStart: true,
            hasHardUnverifiedPredecessorOnFresh: false,
            hasSettledUnconfirmedPredecessorOnFresh: true,
            predecessorAllEventsPosted: true,
            predecessorPostSendFocusOK: true,
            predecessorExactBaselineAvailable: false,
            elapsedSincePredecessorSeconds: 0.200,
            firstBracketedIdentityMatches: false,
            secondBracketedIdentityMatches: true,
            bracketedSelectionStable: true))
        check(!Policy.mayProceedWithPredecessorState(
            operation: .dictation,
            startBlocked: true,
            freshMatchesStart: true,
            hasHardUnverifiedPredecessorOnFresh: false,
            hasSettledUnconfirmedPredecessorOnFresh: true,
            predecessorAllEventsPosted: true,
            predecessorPostSendFocusOK: true,
            predecessorExactBaselineAvailable: false,
            elapsedSincePredecessorSeconds: 0.200,
            firstBracketedIdentityMatches: true,
            secondBracketedIdentityMatches: false,
            bracketedSelectionStable: true))

        // 7. Bracketed selection/marker change between reads fails closed.
        check(!Policy.mayProceedWithPredecessorState(
            operation: .dictation,
            startBlocked: true,
            freshMatchesStart: true,
            hasHardUnverifiedPredecessorOnFresh: false,
            hasSettledUnconfirmedPredecessorOnFresh: true,
            predecessorAllEventsPosted: true,
            predecessorPostSendFocusOK: true,
            predecessorExactBaselineAvailable: false,
            elapsedSincePredecessorSeconds: 0.200,
            firstBracketedIdentityMatches: true,
            secondBracketedIdentityMatches: true,
            bracketedSelectionStable: false))

        // 8. Predecessor with exactBaselineAvailable == true (e.g. posted_receipt_timeout)
        //    or incomplete post or post-send focus failure stays hard-blocked.
        check(!Policy.mayProceedWithPredecessorState(
            operation: .dictation,
            startBlocked: true,
            freshMatchesStart: true,
            hasHardUnverifiedPredecessorOnFresh: false,
            hasSettledUnconfirmedPredecessorOnFresh: true,
            predecessorAllEventsPosted: true,
            predecessorPostSendFocusOK: true,
            predecessorExactBaselineAvailable: true,
            elapsedSincePredecessorSeconds: 0.200,
            firstBracketedIdentityMatches: true,
            secondBracketedIdentityMatches: true,
            bracketedSelectionStable: true))
        check(!Policy.mayProceedWithPredecessorState(
            operation: .dictation,
            startBlocked: true,
            freshMatchesStart: true,
            hasHardUnverifiedPredecessorOnFresh: false,
            hasSettledUnconfirmedPredecessorOnFresh: true,
            predecessorAllEventsPosted: false,
            predecessorPostSendFocusOK: true,
            predecessorExactBaselineAvailable: false,
            elapsedSincePredecessorSeconds: 0.200,
            firstBracketedIdentityMatches: true,
            secondBracketedIdentityMatches: true,
            bracketedSelectionStable: true))
        check(!Policy.mayProceedWithPredecessorState(
            operation: .dictation,
            startBlocked: true,
            freshMatchesStart: true,
            hasHardUnverifiedPredecessorOnFresh: false,
            hasSettledUnconfirmedPredecessorOnFresh: true,
            predecessorAllEventsPosted: true,
            predecessorPostSendFocusOK: false,
            predecessorExactBaselineAvailable: false,
            elapsedSincePredecessorSeconds: 0.200,
            firstBracketedIdentityMatches: true,
            secondBracketedIdentityMatches: true,
            bracketedSelectionStable: true))

        // 9. Condition 3: Voice commands (.command) and transforms (.transform) keep the strict rule
        //    and NEVER unlock via settled unconfirmed predecessor.
        for op: Policy.SettledUnconfirmedOperation in [.command, .transform] {
            check(!Policy.mayProceedWithPredecessorState(
                operation: op,
                startBlocked: true,
                freshMatchesStart: true,
                hasHardUnverifiedPredecessorOnFresh: false,
                hasSettledUnconfirmedPredecessorOnFresh: true,
                predecessorAllEventsPosted: true,
                predecessorPostSendFocusOK: true,
                predecessorExactBaselineAvailable: false,
                elapsedSincePredecessorSeconds: 0.250,
                firstBracketedIdentityMatches: true,
                secondBracketedIdentityMatches: true,
                bracketedSelectionStable: true))
            check(!Policy.mayProceedWithPredecessorState(
                operation: op,
                startBlocked: false,
                freshMatchesStart: false,
                hasHardUnverifiedPredecessorOnFresh: false,
                hasSettledUnconfirmedPredecessorOnFresh: true,
                predecessorAllEventsPosted: true,
                predecessorPostSendFocusOK: true,
                predecessorExactBaselineAvailable: false,
                elapsedSincePredecessorSeconds: 0.250,
                firstBracketedIdentityMatches: true,
                secondBracketedIdentityMatches: true,
                bracketedSelectionStable: true))
        }
    }

    func blockScopedReceiptEvidenceIsTieredByFieldNature() throws {
        let before = state("suffix", 0)
        let inserted = "abc"
        let after = state("abc", 3)
        func receipt(_ nature: Policy.FieldNature) -> Policy.Receipt? {
            Policy.verify(before: before, inserted: inserted, after: after,
                          sameTarget: true, fieldNature: nature)
        }

        let normal = try require(receipt(.normal))
        check(normal.mode == .blockScoped)
        check(normal.retainsContentEvidence)
        check(normal.before.text == before.text)
        check(normal.after.text == after.text)
        check(normal.inserted == inserted)
        check(normal.before.textSHA256 == nil)
        check(normal.after.textSHA256 == nil)
        check(normal.insertedSHA256 == nil)

        let protected = try require(receipt(.protected))
        check(protected.mode == .blockScoped)
        check(protected.fieldNature == .protected)
        check(!protected.retainsContentEvidence)
        check(protected.before.text.isEmpty)
        check(protected.after.text.isEmpty)
        check(protected.inserted.isEmpty)
        check(protected.before.textUTF16Count == before.text.utf16.count)
        check(protected.after.textUTF16Count == after.text.utf16.count)
        check(protected.insertedUTF16Count == inserted.utf16.count)
        check(protected.before.textSHA256?.count == 64)
        check(protected.after.textSHA256?.count == 64)
        check(protected.insertedSHA256?.count == 64)
        check(protected.before.selection == before.selection)
        check(protected.after.selection == after.selection)
        check(Policy.reconcile(before, using: protected, sameTarget: true, eventsPosted: true) == .blocked)

        let unknown = try require(receipt(.unknown))
        check(unknown.fieldNature == .protected)
        check(!unknown.retainsContentEvidence)
        check(unknown.before.text.isEmpty)
        check(unknown.after.text.isEmpty)
        check(unknown.insertedSHA256?.count == 64)
    }

    func fieldNatureClassificationIsExplicitAndFailsClosed() {
        check(Policy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
                                 hasTextSelection: false, bundleIdentifier: "com.example.Editor") == .normal)
        check(Policy.fieldNature(role: "AXTextArea", subrole: nil, editable: nil,
                                 hasTextSelection: true, bundleIdentifier: "com.example.Editor") == .normal)
        check(Policy.fieldNature(role: "AXSecureTextField", subrole: nil, editable: true,
                                 hasTextSelection: true, bundleIdentifier: "com.example.Editor") == .protected)
        check(Policy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
                                 hasTextSelection: false, bundleIdentifier: "com.example.Editor",
                                 labelHints: ["PIN入力"]) == .protected)
        check(Policy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
                                 hasTextSelection: false, bundleIdentifier: "com.example.Editor",
                                 explicitlyProtected: true) == .protected)
        check(Policy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
                                 hasTextSelection: false, bundleIdentifier: "com.example.Secrets",
                                 protectedBundleIdentifiers: ["com.example.Secrets"]) == .protected)
        check(Policy.fieldNature(role: nil, subrole: nil, editable: true,
                                 hasTextSelection: true, bundleIdentifier: "com.example.Editor") == .unknown)
        check(Policy.fieldNature(role: "AXWebArea", subrole: nil, editable: true,
                                 hasTextSelection: true, bundleIdentifier: "com.example.Editor") == .unknown)
        check(Policy.fieldNature(role: "AXTextField", subrole: nil, editable: true,
                                 hasTextSelection: false, bundleIdentifier: "com.example.Editor",
                                 attributesReadable: false) == .unknown)
    }
}
