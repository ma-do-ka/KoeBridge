#if os(macOS)
import Foundation
import Testing
import KoeBridgeCore
@testable import KoeBridge

/// Runtime coverage for the R-03 案B-2 soft-commit context: per-sentence
/// post-processing runs ahead during the take, and seal assembles the
/// ordered result the whole-take (OFF) path would produce.
@MainActor struct TakeStreamingContextTests {
    /// Per-sentence tasks may finish in any order; the assembled text keeps
    /// sentence order.
    @Test func outOfOrderCompletionKeepsSentenceOrder() async throws {
        var gates: [String: CheckedContinuation<Void, Never>] = [:]
        let context = TakeStreamingContext(postProcessEligible: true) { text in
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                gates[text] = c
            }
            return ("[\(text)]", true)
        }
        context.ingest("一つ目です。二つ目です。三つ目です。")
        for _ in 0..<1_000 where gates.count < 3 { await Task.yield() }
        try #require(gates.count == 3)
        // Release the sentences out of order; seal awaits every task anyway.
        gates["三つ目です。"]?.resume()
        gates["一つ目です。"]?.resume()
        gates["二つ目です。"]?.resume()
        let outcome = await context.seal(finalText: "一つ目です。二つ目です。三つ目です。") { _ in }
        #expect(!outcome.degraded)
        #expect(outcome.rawText == "一つ目です。二つ目です。三つ目です。")
        #expect(outcome.processedText == "[一つ目です。][二つ目です。][三つ目です。]")
        #expect(outcome.appliedSentences == 3 && outcome.fallbackSentences == 0)
    }

    /// A sentence whose post-processing reports failure keeps its raw text
    /// while the other sentences still apply their results.
    @Test func failedSentenceKeepsItsRawText() async {
        let context = TakeStreamingContext(postProcessEligible: true) { text in
            text.contains("失敗") ? (text, false) : ("[\(text)]", true)
        }
        context.ingest("成功です。失敗です。これも成功です。")
        let outcome = await context.seal(finalText: "成功です。失敗です。これも成功です。") { _ in }
        #expect(!outcome.degraded)
        #expect(outcome.processedText == "[成功です。]失敗です。[これも成功です。]")
        #expect(outcome.appliedSentences == 2 && outcome.fallbackSentences == 1)
    }

    /// A rewritten final text conflicts with the streamed prefix: seal
    /// degrades, pending sentence work is cancelled, no watchdog fallback is
    /// armed, and the assembled text is exactly the final text.
    @Test func conflictedSealDegradesAndCancelsPendingWork() async {
        var armed: [String] = []
        let context = TakeStreamingContext(postProcessEligible: true) { text in
            try? await Task.sleep(for: .seconds(3_600))
            return ("[\(text)]", true)
        }
        context.ingest("確定した一つ目です。確定した二つ目です。")
        let outcome = await context.seal(finalText: "まったく別の確定文") { armed.append($0) }
        #expect(outcome.degraded)
        #expect(armed.isEmpty)
        #expect(outcome.rawText == "まったく別の確定文")
        #expect(outcome.processedText == "まったく別の確定文")
        // A repeated seal stays degraded; the context is finished.
        let again = await context.seal(finalText: "まったく別の確定文") { armed.append($0) }
        #expect(again.degraded && armed.isEmpty)
    }

    /// Units cut from the final text at seal are registered: split normally,
    /// post-processed per sentence, counted, and ordered. Regression for
    /// seal discarding segmenter.ingest(finalText) units.
    @Test func sealRegistersFinalUnitsExactlyOnce() async {
        var seen: [String] = []
        let context = TakeStreamingContext(postProcessEligible: true) { text in
            seen.append(text)
            return ("[\(text)]", true)
        }
        let outcome = await context.seal(finalText: "一です。二です。三") { _ in }
        #expect(!outcome.degraded)
        #expect(outcome.unitCount == 3)
        #expect(outcome.boundarySources[.terminator] == 2)
        #expect(outcome.boundarySources[.flush] == 1)
        #expect(seen == ["一です。", "二です。", "三"])
        #expect(outcome.processedText == "[一です。][二です。][三]")
        #expect(outcome.rawText == "一です。二です。三")
    }

    /// Units already cut during speech are not registered twice at seal; the
    /// seal-time ingest adds only the newly finalized tail.
    @Test func sealDoesNotDuplicateStreamedUnits() async {
        var seen: [String] = []
        let context = TakeStreamingContext(postProcessEligible: true) { text in
            seen.append(text)
            return ("[\(text)]", true)
        }
        context.ingest("一です。")
        let outcome = await context.seal(finalText: "一です。二です。") { _ in }
        #expect(!outcome.degraded)
        #expect(outcome.unitCount == 2)
        #expect(seen == ["一です。", "二です。"])
        #expect(outcome.processedText == "[一です。][二です。]")
        #expect(outcome.appliedSentences == 2 && outcome.fallbackSentences == 0)
    }

    /// postProcessEligible == false mirrors the whole-take (OFF) path: units
    /// are still tracked for diagnostics, but no per-sentence work runs and
    /// seal does not arm the watchdog's raw-text fallback, so a later review
    /// session keeps the OFF watchdog precedence.
    @Test func ineligibleContextIsOffEquivalent() async {
        var calls = 0
        var armed: [String] = []
        let context = TakeStreamingContext(postProcessEligible: false) { text in
            calls += 1
            return ("[\(text)]", true)
        }
        context.ingest("一です。二です。")
        let outcome = await context.seal(finalText: "一です。二です。") { armed.append($0) }
        #expect(calls == 0)
        #expect(armed.isEmpty)
        #expect(!outcome.degraded)
        #expect(outcome.unitCount == 2)
        #expect(outcome.processedText == outcome.rawText)
        #expect(outcome.appliedSentences == 0 && outcome.fallbackSentences == 0)
    }

    /// When eligible, seal arms the watchdog fallback with the assembled raw
    /// text for the duration of the remaining sentence work.
    @Test func eligibleSealArmsRawTextFallback() async {
        var armed: [String] = []
        let context = TakeStreamingContext(postProcessEligible: true) { ($0, true) }
        context.ingest("一です。")
        let outcome = await context.seal(finalText: "一です。二です。") { armed.append($0) }
        #expect(armed == ["一です。二です。"])
        #expect(!outcome.degraded)
        #expect(outcome.processedText == "一です。二です。")
    }
}
#endif
