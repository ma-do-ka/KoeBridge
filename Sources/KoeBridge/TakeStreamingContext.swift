#if os(macOS)
import Foundation
import KoeBridgeCore

/// R-03 案B-2 Soft Commit: during one take, sentence units finalize and run
/// post-processing ahead; delivery still happens once, in order, at stop.
/// One context per take; discarded entirely at take end. The structure keeps
/// "finalize sentences" separate from "deliver" so a future live-delivery
/// variant is not foreclosed, but nothing is delivered while recording.
@MainActor final class TakeStreamingContext {
    struct Outcome {
        /// Whole-take text the OFF path would see (concat of raw units).
        let rawText: String
        /// Concatenated per-sentence post-processing results (raw fallback per
        /// unit where processing failed or was skipped).
        let processedText: String
        /// True when the streamed prefix did not match the take's final text.
        /// The caller must fall back to the whole-take (OFF) path.
        let degraded: Bool
        let unitCount: Int
        let appliedSentences: Int
        let fallbackSentences: Int
        let boundarySources: [SentenceBoundarySource: Int]
    }

    private var segmenter = SentenceSegmenter()
    private var units: [SentenceUnit] = []
    private var processed: [Int: String] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var appliedSentences = 0
    private var fallbackSentences = 0
    private var sealed = false
    private let postProcess: @MainActor (String) async -> (text: String, applied: Bool)
    private let postProcessEligible: Bool

    /// `postProcessEligible` is the take-start snapshot of the normal
    /// PostProcessingPolicy check. When off, units are still tracked for
    /// diagnostics but no per-sentence work runs (identity = OFF-equivalent).
    init(postProcessEligible: Bool,
         postProcess: @escaping @MainActor (String) async -> (text: String, applied: Bool)) {
        self.postProcessEligible = postProcessEligible
        self.postProcess = postProcess
    }

    /// Feed the engine's cumulative finalized prefix (raw, pre-adoption).
    /// Newly cut units immediately start post-processing ahead of stop.
    func ingest(finalizedPrefix: String) {
        guard !sealed else { return }
        for unit in segmenter.ingest(finalizedPrefix) {
            register(unit)
        }
    }

    private func register(_ unit: SentenceUnit) {
        units.append(unit)
        guard postProcessEligible else { return }
        let index = unit.index
        let processor = postProcess
        tasks.append(Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let result = await processor(unit.text)
            self.processed[index] = result.text
            if result.applied { self.appliedSentences += 1 } else { self.fallbackSentences += 1 }
        })
    }

    /// Stop accepting text: append the take's final text tail, flush the
    /// remainder, then wait for still-running per-sentence work. The pending
    /// work remains bounded by the take's existing 15 s end watchdog; the
    /// caller supplies the watchdog's raw-text fallback via `markFallback`.
    func seal(finalText: String, markFallback: (String) -> Void) async -> Outcome {
        guard !sealed else { return degradedOutcome(finalText) }
        sealed = true
        for unit in segmenter.ingest(finalText) {
            register(unit)
        }
        guard !segmenter.conflicted else {
            for task in tasks { task.cancel() }
            return degradedOutcome(finalText)
        }
        if let remainder = segmenter.flush() {
            register(remainder)
        }
        let rawText = units.map { $0.separator + $0.text }.joined()
        markFallback(rawText)
        for task in tasks { await task.value }
        tasks.removeAll()
        let processedText = units.map { $0.separator + (processed[$0.index] ?? $0.text) }.joined()
        var sources: [SentenceBoundarySource: Int] = [:]
        for unit in units { sources[unit.source, default: 0] += 1 }
        return Outcome(rawText: rawText, processedText: processedText,
                       degraded: false, unitCount: units.count,
                       appliedSentences: appliedSentences,
                       fallbackSentences: fallbackSentences,
                       boundarySources: sources)
    }

    private func degradedOutcome(_ finalText: String) -> Outcome {
        Outcome(rawText: finalText, processedText: finalText, degraded: true,
                unitCount: units.count, appliedSentences: appliedSentences,
                fallbackSentences: fallbackSentences, boundarySources: [:])
    }

    /// Fully discarded at take end; nothing carries into the next take.
    func cancel() {
        sealed = true
        for task in tasks { task.cancel() }
        tasks.removeAll()
        units.removeAll()
        processed.removeAll()
    }
}
#endif
