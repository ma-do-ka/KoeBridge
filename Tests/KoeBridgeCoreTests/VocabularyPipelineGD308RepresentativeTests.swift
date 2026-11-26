import Testing
import Foundation
@testable import KoeBridgeCore

/// Representative tests for GD‑308 covering each category and guard.
/// These tests verify that the pipeline implements the design correctly.
struct VocabularyPipelineGD308RepresentativeTests {
    // MARK: - Correct Pairs (expected auto‑confirm)

    @Test func correctPair_kanaWord() {
        let term = LearnedTerm(
            term: "クロハネ",
            originalFragment: "黒羽",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        #expect(outcome.isReady, "CAT1‑01 should be ready")
        if case .ready(let candidate) = outcome {
            #expect(candidate.reading == "くろはね")
            #expect(candidate.type == .kana)
        }
    }

    @Test func correctPair_kanjiMixedSameReading() {
        let term = LearnedTerm(
            term: "稼働監視基盤",
            originalFragment: "稼働監視基板",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        #expect(outcome.isReady, "CAT2‑02 should be ready (Y_before = Y_after)")
        if case .ready(let candidate) = outcome {
            #expect(candidate.reading == "かどうかんしきばん")
            #expect(candidate.type == .kanjiMixed)
        }
    }

    @Test func correctPair_alphabetAcronym() {
        let term = LearnedTerm(
            term: "VKLN",
            originalFragment: "ブイケーエルエヌ",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        #expect(outcome.isReady, "CAT3‑03 should be ready")
        if case .ready(let candidate) = outcome {
            #expect(candidate.reading == "ぶいけーえるえぬ")
            #expect(candidate.type == .alphabet)
        }
    }

    @Test func correctPair_mixedSpellingMatch() {
        let term = LearnedTerm(
            term: "ステップB設計",
            originalFragment: "ステップびー設計",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        #expect(outcome.isReady, "CAT4‑06 should be ready")
        if case .ready(let candidate) = outcome {
            #expect(candidate.reading == "すてっぷびーせっけい")
            #expect(candidate.type == .numericMixed)
        }
    }

    // MARK: - Conditional / Held Cases (expected pendingReview)

    @Test func conditional_kanjiMixedPhoneticDivergence() {
        let term = LearnedTerm(
            term: "音声入力設定",
            originalFragment: "音声入力設営",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        // せつえい vs せってい – edit distance >1 → hold
        #expect(outcome.isPendingReview, "CAT2‑03 should be pendingReview")
        if case .pendingReview(let reason, _) = outcome {
            #expect(reason == .phoneticDivergence)
        }
    }

    @Test func conditional_alphabetRomanjiHold() {
        let term = LearnedTerm(
            term: "Kurohane",
            originalFragment: "黒羽",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        // Romanji proper noun – ambiguous alphabet reading → hold
        #expect(outcome.isPendingReview, "CAT3‑02 should be pendingReview")
        if case .pendingReview(let reason, _) = outcome {
            #expect(reason == .ambiguousAlphabetReading)
        }
    }

    @Test func conditional_mixedAlphabetHold() {
        let term = LearnedTerm(
            term: "MIRA基盤",
            originalFragment: "ミラ基盤",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        // MIRA could be read as "みら" (word) or spelled out – ambiguous → hold
        #expect(outcome.isPendingReview, "CAT4‑01 should be pendingReview")
        if case .pendingReview(let reason, _) = outcome {
            #expect(reason == .ambiguousAlphabetReading || reason == .readingGenerationUnavailable)
        }
    }

    // MARK: - Forbidden Cases (must NOT be ready)

    @Test func forbidden_shortReadingGuard() {
        let term = LearnedTerm(
            term: "QA",
            originalFragment: "課",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        #expect(!outcome.isReady, "BND‑A01 must not be ready")
        #expect(outcome.isPendingReview, "Should be pendingReview")
        if case .pendingReview(let reason, _) = outcome {
            #expect(reason == .shortReadingGuard)
        }
    }

    @Test func forbidden_phoneticDivergence() {
        let term = LearnedTerm(
            term: "Kurohane",
            originalFragment: "全然違う",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        #expect(!outcome.isReady, "BND‑D01 must not be ready")
        #expect(outcome.isPendingReview, "Should be pendingReview")
        if case .pendingReview(let reason, _) = outcome {
            #expect(reason == .phoneticDivergence)
        }
    }

    @Test func forbidden_forbiddenCharactersHold() {
        let term = LearnedTerm(
            term: "Astora|Sync",
            originalFragment: "アストラパイプシンク",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        #expect(!outcome.isReady, "BND‑C01 must not be ready")
        #expect(outcome.isPendingReview, "Should be pendingReview")
        if case .pendingReview(let reason, _) = outcome {
            #expect(reason == .writtenContainsForbiddenCharacters)
        }
    }

    // MARK: - Excluded Cases

    @Test func excluded_punctuationOnly() {
        let term = LearnedTerm(
            term: "アストラ同期",
            originalFragment: "アストラ同期、",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        #expect(outcome.isExcluded, "BND‑E03 should be excluded")
    }

    @Test func excluded_fullRewriteNoise() {
        let term = LearnedTerm(
            term: "仕様を変更した",
            originalFragment: "機能を追加した",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        #expect(outcome.isExcluded, "BND‑E04 should be excluded")
    }

    // MARK: - Edge Cases

    @Test func edge_longReadingGuard() {
        // BND‑B01: very long reading (>20 mora) should be held.
        // We'll simulate with a long string.
        let long = String(repeating: "あ", count: 30) // 30 mora
        let term = LearnedTerm(
            term: long,
            originalFragment: long,
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline()
        let outcome = pipeline.process(term)
        #expect(outcome.isPendingReview, "Long reading should be held")
        if case .pendingReview(let reason, _) = outcome {
            #expect(reason == .longReadingGuard)
        }
    }

    @Test func edge_duplicateReadingCollision() {
        let tracker = CandidateSetTracker()
        let firstTerm = LearnedTerm(
            term: "クロハネ",
            originalFragment: "黒羽",
            sourceRecordID: nil
        )
        let secondTerm = LearnedTerm(
            term: "Kurohane",
            originalFragment: "黒羽",
            sourceRecordID: nil
        )
        let pipeline = VocabularyCandidatePipeline(candidateSetTracker: tracker)
        // First candidate (kana) should be ready.
        let firstOutcome = pipeline.process(firstTerm)
        guard case .ready(let firstCandidate) = firstOutcome else {
            Issue.record("First candidate should be ready")
            return
        }
        tracker.addCandidate(firstCandidate)
        // Second candidate (alphabet) same reading, different written → collision hold.
        let secondOutcome = pipeline.process(secondTerm)
        #expect(secondOutcome.isPendingReview, "Duplicate reading should be held")
        if case .pendingReview(let reason, _) = secondOutcome {
            #expect(reason == .duplicateReadingCollision)
        }
    }
}