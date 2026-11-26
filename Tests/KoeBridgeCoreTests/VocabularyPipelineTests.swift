import Testing
import Foundation
@testable import KoeBridgeCore

struct VocabularyPipelineTests {
    // MARK: - Stage 1: Intake & Normalization

    @Test func intakeNormalization_halfWidthSpaceBecomesUnderscore() {
        let term = LearnedTerm(
            term: "Astora Sync",
            originalFragment: "アストラシンク",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        #expect(outcome.isPendingReview)
        if case .pendingReview(let reason, let candidate) = outcome {
            #expect(candidate.written == "Astora_Sync")
            #expect(reason == .writtenContainsForbiddenCharacters)
        }
    }

    @Test func intakeNormalization_forbiddenCharactersCauseHold() {
        let term = LearnedTerm(
            term: "Astora|Sync",
            originalFragment: "アストラパイプシンク",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        #expect(outcome.isPendingReview)
        if case .pendingReview(let reason, _) = outcome {
            #expect(reason == .writtenContainsForbiddenCharacters)
        }
    }

    @Test func intakeNormalization_punctuationOnlyChangeExcluded() {
        let term = LearnedTerm(
            term: "アストラ同期",
            originalFragment: "アストラ同期、",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        #expect(outcome.isExcluded)
    }

    @Test func intakeNormalization_sameSoundOrthographyExcluded() {
        // Example: 子供 → 子ども (same reading, different kanji)
        // We cannot reliably detect this without a dictionary; for MVP we treat
        // any kanji‑to‑kanji change with identical kana reading as out‑of‑scope.
        // This test is a placeholder.
        let term = LearnedTerm(
            term: "子ども",
            originalFragment: "子供",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        // Should be excluded (out‑of‑dictionary‑scope) or held.
        #expect(outcome.isExcluded || outcome.isPendingReview)
    }

    // MARK: - Stage 2: Type Classification

    @Test func typeClassification_kanaOnly() {
        let pipeline = VocabularyCandidatePipeline()
        #expect(pipeline.classifyTest("クロハネ") == .kana)
        #expect(pipeline.classifyTest("ゆうなぎ") == .kana)
        #expect(pipeline.classifyTest("あすとら") == .kana)
    }

    @Test func typeClassification_kanjiMixed() {
        let pipeline = VocabularyCandidatePipeline()
        #expect(pipeline.classifyTest("霧峰システム") == .kanjiMixed)
        #expect(pipeline.classifyTest("稼働監視基盤") == .kanjiMixed)
        #expect(pipeline.classifyTest("水無瀬基盤") == .kanjiMixed)
    }

    @Test func typeClassification_alphabet() {
        let pipeline = VocabularyCandidatePipeline()
        #expect(pipeline.classifyTest("VKLN") == .alphabet)
        #expect(pipeline.classifyTest("NXR") == .alphabet)
        #expect(pipeline.classifyTest("ZQDB") == .alphabet)
    }

    @Test func typeClassification_numericMixed() {
        let pipeline = VocabularyCandidatePipeline()
        #expect(pipeline.classifyTest("V2連携") == .numericMixed)
        #expect(pipeline.classifyTest("Kurohane204") == .numericMixed)
        #expect(pipeline.classifyTest("ステップB設計") == .numericMixed)
    }

    // MARK: - Stage 3 & 4: Reading Generation & Guards (using GD‑308 samples)

    @Test func gd308_correctPairs_kanaWordsReady() {
        // CAT1‑01 through CAT1‑07 should be ready (auto‑determined).
        let samples = [
            ("クロハネ", "黒羽", "くろはね"),
            ("アストラ", "明日とら", "あすとら"),
            ("ハルカゼ", "春風", "はるかぜ"),
            ("シロガネ", "白金", "しろがね"),
            ("ゆうなぎ", "夕凪", "ゆうなぎ"),
            ("タカネー", "高値", "たかねー"),
            ("クモゲート", "雲ゲート", "くもげーと"),
        ]
        for (written, originalFragment, expectedReading) in samples {
            let term = LearnedTerm(
                term: written,
                originalFragment: originalFragment,
                sourceRecordID: nil
            )
            let pipeline = VocabularyCandidatePipeline()
            let outcome = pipeline.process(term)
            // Kana words should be ready (no hold reasons).
            #expect(outcome.isReady, "Failed for \(written)")
            if case .ready(let candidate) = outcome {
                #expect(candidate.reading == expectedReading, "Reading mismatch for \(written)")
            }
        }
    }

    @Test func gd308_boundaryShortReadingHold() {
        // BND‑A01 through A04 (short‑reading guard) should be pendingReview.
        let samples = [
            ("QA", "課", .shortReadingGuard),
            ("NOA", "野合", .shortReadingGuard),
            ("K", "系", .shortReadingGuard),
            ("RI", "理", .shortReadingGuard),
        ]
        for (written, originalFragment, expectedReason) in samples {
            let term = LearnedTerm(
                term: written,
                originalFragment: originalFragment,
                sourceRecordID: nil
            )
            let pipeline = VocabularyCandidatePipeline()
            let outcome = pipeline.process(term)
            #expect(outcome.isPendingReview, "Should be pendingReview for \(written)")
            if case .pendingReview(let reason, _) = outcome {
                #expect(reason == expectedReason, "Wrong hold reason for \(written)")
            }
        }
    }

    @Test func gd308_boundaryPhoneticDivergenceHold() {
        // BND‑D01 through D04 (phonetic divergence) should be pendingReview.
        let samples = [
            ("Kurohane", "全然違う", .phoneticDivergence),
            ("霧峰システム", "会議資料", .phoneticDivergence),
            ("ZQDB", "データベース", .phoneticDivergence),
            ("アストラ同期", "システム障害", .phoneticDivergence),
        ]
        for (written, originalFragment, expectedReason) in samples {
            let term = LearnedTerm(
                term: written,
                originalFragment: originalFragment,
                sourceRecordID: nil
            )
            let pipeline = VocabularyCandidatePipeline()
            let outcome = pipeline.process(term)
            #expect(outcome.isPendingReview, "Should be pendingReview for \(written)")
            if case .pendingReview(let reason, _) = outcome {
                #expect(reason == expectedReason, "Wrong hold reason for \(written)")
            }
        }
    }

    @Test func gd308_forbiddenCasesZeroReady() {
        // Verify that none of the 27 auto‑registration‑forbidden cases produce `.ready`.
        // We'll test a representative subset.
        let forbidden = [
            ("QA", "課"),
            ("K", "系"),
            ("Kurohane", "全然違う"),
            ("Astora|Sync", "アストラパイプシンク"),
        ]
        for (written, originalFragment) in forbidden {
            let term = LearnedTerm(
                term: written,
                originalFragment: originalFragment,
                sourceRecordID: nil
            )
            let pipeline = VocabularyCandidatePipeline()
            let outcome = pipeline.process(term)
            #expect(!outcome.isReady, "Forbidden case \(written) incorrectly ready")
        }
    }

    // MARK: - Utilities for testing

    private extension VocabularyCandidatePipeline {
        func classifyTest(_ written: String) -> VocabularyTermType {
            classifyWrittenForm(written)
        }
    }

    private extension VocabularyCandidateOutcome {
        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
        var isPendingReview: Bool {
            if case .pendingReview = self { return true }
            return false
        }
        var isExcluded: Bool {
            if case .excluded = self { return true }
            return false
        }
    }
}