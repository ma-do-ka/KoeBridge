import Foundation
import Testing
@testable import KoeBridgeCore

struct BenchmarkMetricsTests {
    private func approxEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-12) -> Bool {
        abs(lhs - rhs) < tolerance
    }

    private func approxEqual(_ lhs: Double?, _ rhs: Double, tolerance: Double = 1e-12) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) < tolerance
    }

    private func categoryValue(_ values: [String: Double?], _ key: String) -> Double? {
        switch values[key] {
        case .some(let value):
            return value
        case .none:
            return nil
        }
    }

    private func hasNilCategoryValue(_ values: [String: Double?], _ key: String) -> Bool {
        switch values[key] {
        case .some(.none):
            return true
        default:
            return false
        }
    }

    @Test func kanjiKanaCERIdenticalSubstitutionInsertionDeletion() {
        #expect(BenchmarkCER.clipNorm(ref: "今日は晴れです", hyp: "今日は晴れです") == 0.0)
        #expect(BenchmarkCER.clipStrict(ref: "今日は晴れです", hyp: "今日は晴れです") == 0.0)

        // Single substitution in an 8-character Japanese sentence -> exact 1/8 = 0.125.
        let subScore = BenchmarkCER.scoreNorm(ref: "日本語の音声認識", hyp: "日本語の音声認織")
        #expect(subScore.edits == 1)
        #expect(subScore.referenceLength == 8)
        #expect(approxEqual(subScore.cer, 0.125))
        #expect(approxEqual(BenchmarkCER.clipNorm(ref: "日本語の音声認識", hyp: "日本語の音声認織"), 0.125))

        // Insertion: 1 extra character over N_ref = 5 -> 0.2.
        let insScore = BenchmarkCER.scoreNorm(ref: "日本語認識", hyp: "日本語の認識")
        #expect(insScore.edits == 1)
        #expect(insScore.referenceLength == 5)
        #expect(approxEqual(insScore.cer, 0.2))

        // Deletion: 1 missing character over N_ref = 6 -> 1/6.
        let delScore = BenchmarkCER.scoreNorm(ref: "日本語の認識", hyp: "日本語認識")
        #expect(delScore.edits == 1)
        #expect(delScore.referenceLength == 6)
        #expect(approxEqual(delScore.cer, 1.0 / 6.0))

        // Insertions exceeding N_ref are not capped at 1.0 (3 edits / 2 chars = 1.5).
        #expect(approxEqual(BenchmarkCER.clipNorm(ref: "あい", hyp: "あいうえお"), 1.5))

        // Direct Levenshtein symmetry and mixed edit operations.
        #expect(BenchmarkLevenshtein.edits(Array("kitten"), Array("sitting")) == 3)
        #expect(BenchmarkLevenshtein.edits(Array("sitting"), Array("kitten")) == 3)
        #expect(BenchmarkLevenshtein.edits(Array("ab"), Array("ba")) == 2)
        #expect(BenchmarkLevenshtein.edits([], []) == 0)
        #expect(BenchmarkLevenshtein.edits(Array("abc"), []) == 3)
        #expect(BenchmarkLevenshtein.edits([], Array("abc")) == 3)
    }

    @Test func nfkcWidthHalfwidthKatakanaAndWhitespaceVariants() {
        // Fullwidth alphanumeric vs ASCII -> 0 under cer_norm, > 0 under cer_strict.
        #expect(BenchmarkCER.clipNorm(ref: "ＡＢＣ１２３", hyp: "abc123") == 0.0)
        #expect(BenchmarkCER.clipStrict(ref: "ＡＢＣ１２３", hyp: "abc123") == 1.0)
        #expect(BenchmarkCER.clipNorm(ref: "２０２６年１１月", hyp: "2026年11月") == 0.0)
        #expect(approxEqual(BenchmarkCER.clipStrict(ref: "２０２６年１１月", hyp: "2026年11月"), 0.75))

        // Halfwidth katakana (including dakuten/handakuten) composes to fullwidth under NFKC.
        let halfwidth = "ｱｲｳｴｵｶﾞｷﾞｸﾞｹﾞｺﾞﾊﾟ"
        let fullwidth = "アイウエオガギグゲゴパ"
        #expect(BenchmarkNormalize.forCER(halfwidth) == fullwidth)
        #expect(BenchmarkCER.clipNorm(ref: halfwidth, hyp: fullwidth) == 0.0)
        #expect(BenchmarkCER.clipStrict(ref: halfwidth, hyp: fullwidth) == 1.0)

        // NFC canonical equivalence holds even under cer_strict (decomposed NFD vs composed NFC).
        #expect(BenchmarkCER.clipStrict(ref: "が", hyp: "か\u{3099}") == 0.0)

        // All Unicode whitespace variants (ASCII, tab, newline, CRLF, ideographic U+3000, NBSP, em space, line separator) are stripped.
        let spaced = "東京 \t\n\r\n\u{3000}\u{00A0}\u{2003}\u{2028}駅"
        #expect(BenchmarkNormalize.forCER(spaced) == "東京駅")
        #expect(BenchmarkCER.clipNorm(ref: spaced, hyp: "東京駅") == 0.0)
    }

    @Test func punctuationStrippingAndASCIILowercase() {
        // Ref with Japanese/fullwidth punctuation vs plain hyp -> 0 (norm), 3/10 = 0.3 (strict).
        #expect(BenchmarkCER.clipNorm(ref: "今日は、晴れです！？", hyp: "今日は晴れです") == 0.0)
        #expect(approxEqual(BenchmarkCER.clipStrict(ref: "今日は、晴れです！？", hyp: "今日は晴れです"), 0.3))

        // Pin all 17 specified punctuation characters in the stripped set.
        let allStripped = "a、b。c,d.e！f？g!h?i・j「k」l『m』n（o）p(q)r"
        #expect(BenchmarkNormalize.forCER(allStripped) == "abcdefghijklmnopqr")

        // Non-stripped characters (e.g. prolonged sound mark ー and ASCII hyphen -) are preserved.
        #expect(BenchmarkNormalize.forCER("メール-送信") == "メール-送信")

        // Case-only ASCII difference -> 0 (norm), 6/10 = 0.6 (strict).
        #expect(BenchmarkCER.clipNorm(ref: "OpenAI API", hyp: "openai api") == 0.0)
        #expect(approxEqual(BenchmarkCER.clipStrict(ref: "OpenAI API", hyp: "openai api"), 0.6))

        // Lowercasing applies to ASCII A–Z only (non-ASCII uppercase such as É is preserved).
        #expect(BenchmarkNormalize.forCER("ÉＡZ") == "Éaz")
        #expect(BenchmarkCER.clipNorm(ref: "É", hyp: "é") == 1.0)
    }

    @Test func emptyHypothesisAndEmptyReferenceEdges() {
        // Empty hypothesis with non-empty reference -> CER 1.0.
        #expect(BenchmarkCER.clipNorm(ref: "こんにちは", hyp: "") == 1.0)
        #expect(BenchmarkCER.clipStrict(ref: "こんにちは", hyp: "") == 1.0)

        // Premise 4 edge 1: N_ref == 0 and edits == 0 -> 0.0.
        #expect(BenchmarkCER.clipNorm(ref: "", hyp: "") == 0.0)
        #expect(BenchmarkCER.clipStrict(ref: "", hyp: "") == 0.0)
        #expect(BenchmarkCER.clipNorm(ref: "。、！？", hyp: "") == 0.0)
        #expect(BenchmarkCER.clipStrict(ref: "。、！？", hyp: "") == 1.0)

        // Premise 4 edge 2: N_ref == 0 and edits > 0 -> 1.0.
        #expect(BenchmarkCER.clipNorm(ref: "", hyp: "ああ") == 1.0)
        #expect(BenchmarkCER.clipStrict(ref: "", hyp: "ああ") == 1.0)
        #expect(BenchmarkCER.clipNorm(ref: "。", hyp: "あ") == 1.0)

        // Corpus micro-average empty-reference edges (Premise 4):
        // (1) ΣN_ref == 0, Σedits == 0 -> 0.0
        let emptyCorpusAverage = BenchmarkCER.corpusMicroAverage(clips: [])
        #expect(emptyCorpusAverage != nil)
        #expect(emptyCorpusAverage == 0.0)
        #expect(BenchmarkCER.corpusMicroAverage(clips: [
            BenchmarkClip(category: "empty", reference: "", hypothesis: "")
        ]) == 0.0)
        // (2) ΣN_ref == 0, Σedits > 0 -> 1.0
        #expect(BenchmarkCER.corpusMicroAverage(clips: [
            BenchmarkClip(category: "empty", reference: "", hypothesis: "ああ")
        ]) == 1.0)
        // (3) Raw sums without per-clip capping: (3 + 0) / (0 + 6) = 0.5 (not capped to 1 / 6).
        let rawSumClips = [
            BenchmarkClip(category: "a", reference: "", hypothesis: "あいう"),
            BenchmarkClip(category: "a", reference: "かきくけこさ", hypothesis: "かきくけこさ")
        ]
        #expect(approxEqual(BenchmarkCER.corpusMicroAverage(clips: rawSumClips), 0.5))
    }

    @Test func emojiAndZWJExtendedGraphemeClusters() {
        // ZWJ family sequence 👨‍👩‍👧 (5 Unicode scalars) is a single Swift Character.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(Array(family).count == 1)
        #expect(BenchmarkNormalize.forCER(family) == family)
        #expect(BenchmarkLevenshtein.edits(Array(family), []) == 1)

        let normSolo = BenchmarkCER.scoreNorm(ref: family, hyp: "")
        #expect(normSolo.edits == 1)
        #expect(normSolo.referenceLength == 1)
        #expect(normSolo.cer == 1.0)

        let strictSolo = BenchmarkCER.scoreStrict(ref: family, hyp: "")
        #expect(strictSolo.edits == 1)
        #expect(strictSolo.referenceLength == 1)
        #expect(strictSolo.cer == 1.0)

        // Mixed Japanese + ZWJ emoji: deletion and substitution both count as 1 edit out of 5 Characters.
        let mixedRef = "家族\(family)です"
        let deleted = BenchmarkCER.scoreNorm(ref: mixedRef, hyp: "家族です")
        #expect(deleted.edits == 1)
        #expect(deleted.referenceLength == 5)
        #expect(approxEqual(deleted.cer, 0.2))

        let substituted = BenchmarkCER.scoreNorm(ref: mixedRef, hyp: "家族\u{1F600}です")
        #expect(substituted.edits == 1)
        #expect(substituted.referenceLength == 5)
        #expect(approxEqual(substituted.cer, 0.2))
    }

    @Test func corpusMicroAverageDiffersFromMeanOfClipCERs() {
        // Clip 1: N_ref = 2, edits = 1 (clip CER = 0.50)
        // Clip 2: N_ref = 8, edits = 0 (clip CER = 0.00)
        // Micro-average = (1 + 0) / (2 + 8) = 0.10, whereas mean of clip CERs = 0.25.
        let clips = [
            BenchmarkClip(category: "short", reference: "あい", hypothesis: "あう"),
            BenchmarkClip(category: "long", reference: "あいうえおかきく", hypothesis: "あいうえおかきく")
        ]
        #expect(clips[0].normalizedReferenceLength == 2)
        #expect(clips[1].normalizedReferenceLength == 8)

        let micro = BenchmarkCER.corpusMicroAverage(clips: clips)
        let meanOfClipCERs = (0.5 + 0.0) / 2.0
        #expect(approxEqual(micro, 0.1))
        #expect(!approxEqual(micro, meanOfClipCERs))

        let byCategory = BenchmarkCER.perCategoryMicroAverage(clips: clips)
        #expect(byCategory.count == 2)
        #expect(approxEqual(categoryValue(byCategory, "short"), 0.5))
        #expect(approxEqual(categoryValue(byCategory, "long"), 0.0))
    }

    @Test func failurePenaltyAndCompletionRate() {
        // Clip 1 ("a"): N_ref = 4, edits = 1
        // Clip 2 ("a"): N_ref = 6, edits = 0
        // Clip 3 ("b"): N_ref = 10, failed (hypothesis == nil -> penalty edits = 10, denominator += 10)
        let clips = [
            BenchmarkClip(category: "a", reference: "あいうえ", hypothesis: "あいうお"),
            BenchmarkClip(category: "a", reference: "かきくけこさ", hypothesis: "かきくけこさ"),
            BenchmarkClip(category: "b", reference: "たちつてとなにぬねの", hypothesis: nil)
        ]
        #expect(BenchmarkCER.succeededCount(clips: clips) == 2)
        #expect(BenchmarkCER.failedCount(clips: clips) == 1)
        #expect(approxEqual(BenchmarkCER.completionRate(clips: clips), 2.0 / 3.0))

        // Succeeded-only micro-average = (1 + 0) / (4 + 6) = 0.10.
        #expect(approxEqual(BenchmarkCER.corpusMicroAverage(clips: clips), 0.1))
        // Penalty micro-average = (1 + 0 + 10) / (4 + 6 + 10) = 11 / 20 = 0.55.
        #expect(approxEqual(BenchmarkCER.corpusMicroAverageWithFailurePenalty(clips: clips), 0.55))

        let perCatPenalty = BenchmarkCER.perCategoryMicroAverageWithFailurePenalty(clips: clips)
        #expect(approxEqual(perCatPenalty["a"] ?? -1, 0.1))
        #expect(approxEqual(perCatPenalty["b"] ?? -1, 1.0))

        // All-failed and empty corpus boundaries.
        let allFailed = [BenchmarkClip(category: "x", reference: "テスト", hypothesis: nil)]
        #expect(BenchmarkCER.completionRate(clips: allFailed) == 0.0)
        #expect(BenchmarkCER.corpusMicroAverage(clips: allFailed) == nil)
        #expect(BenchmarkCER.corpusMicroAverageWithFailurePenalty(clips: allFailed) == 1.0)
        #expect(BenchmarkCER.completionRate(clips: []) == 0.0)
        #expect(BenchmarkCER.corpusMicroAverageWithFailurePenalty(clips: []) == 0.0)
    }

    @Test func allFailedCorpusMicroAverageIsNil() {
        let allFailed = [
            BenchmarkClip(category: "x", reference: "テスト", hypothesis: nil),
            BenchmarkClip(category: "x", reference: "失敗", hypothesis: nil)
        ]
        #expect(BenchmarkCER.corpusMicroAverage(clips: allFailed) == nil)
    }

    @Test func perCategoryMicroAverageDistinguishesAllFailedCategories() {
        let clips = [
            BenchmarkClip(category: "a", reference: "あいうえおかきくけこ", hypothesis: "あいうえおかきくけさ"),
            BenchmarkClip(category: "b", reference: "たちつてとなにぬねの", hypothesis: nil)
        ]
        let byCategory = BenchmarkCER.perCategoryMicroAverage(clips: clips)
        #expect(byCategory.count == 2)
        #expect(approxEqual(categoryValue(byCategory, "a"), 0.1))
        #expect(hasNilCategoryValue(byCategory, "b"))
    }

    @Test func nearestRankPercentilesLatencySummaryAndClipIQR() throws {
        // n = 1
        let one = [42.0]
        #expect(BenchmarkPercentile.nearestRank(one, 50) == 42.0)
        #expect(BenchmarkPercentile.nearestRank(one, 90) == 42.0)
        #expect(BenchmarkPercentile.nearestRank(one, 95) == 42.0)
        let s1 = LatencySummary(samples: one)
        #expect(s1.count == 1)
        #expect(s1.p50 == 42.0)
        #expect(s1.p90 == 42.0)
        #expect(s1.p95 == 42.0)
        #expect(s1.max == 42.0)

        // n = 4: ranks for p25/p50/p75/p90/p95 = ceil(1, 2, 3, 3.6, 3.8) = 1, 2, 3, 4, 4.
        let four = [10.0, 20.0, 30.0, 40.0]
        #expect(BenchmarkPercentile.nearestRank(four, 25) == 10.0)
        #expect(BenchmarkPercentile.nearestRank(four, 50) == 20.0)
        #expect(BenchmarkPercentile.nearestRank(four, 75) == 30.0)
        #expect(BenchmarkPercentile.nearestRank(four, 90) == 40.0)
        #expect(BenchmarkPercentile.nearestRank(four, 95) == 40.0)
        let s4 = LatencySummary(samples: [30.0, 10.0, 40.0, 20.0])
        #expect(s4.count == 4)
        #expect(s4.p50 == 20.0)
        #expect(s4.p90 == 40.0)
        #expect(s4.p95 == 40.0)
        #expect(s4.max == 40.0)

        // n = 10: ranks for p25/p50/p75/p90/p95 = ceil(2.5, 5, 7.5, 9, 9.5) = 3, 5, 8, 9, 10.
        let ten = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0]
        #expect(BenchmarkPercentile.nearestRank(ten, 25) == 30.0)
        #expect(BenchmarkPercentile.nearestRank(ten, 50) == 50.0)
        #expect(BenchmarkPercentile.nearestRank(ten, 75) == 80.0)
        #expect(BenchmarkPercentile.nearestRank(ten, 90) == 90.0)
        #expect(BenchmarkPercentile.nearestRank(ten, 95) == 100.0)
        let s10 = LatencySummary(samples: Array(ten.reversed()))
        #expect(s10.count == 10)
        #expect(s10.p50 == 50.0)
        #expect(s10.p90 == 90.0)
        #expect(s10.p95 == 100.0)
        #expect(s10.max == 100.0)

        // Exact IEEE 754 rank boundary where (p / 100) * n would overshoot: p=14, n=100 -> rank 14.
        let hundred = (1...100).map { Double($0) }
        #expect(BenchmarkPercentile.nearestRank(hundred, 14) == 14.0)
        #expect(BenchmarkPercentile.nearestRank(hundred, 7) == 7.0)

        // Empty and non-finite inputs to LatencySummary yield nil metrics (distinct from 0 ms).
        #expect(LatencySummary(samples: []) == LatencySummary.empty)
        #expect(LatencySummary.empty.count == 0)
        #expect(LatencySummary.empty.p50 == nil)
        #expect(LatencySummary.empty.p90 == nil)
        #expect(LatencySummary.empty.p95 == nil)
        #expect(LatencySummary.empty.max == nil)
        let filtered = LatencySummary(samples: [.nan, 25.0, .infinity, -Double.infinity])
        #expect(filtered.count == 1)
        #expect(filtered.p50 == 25.0)
        #expect(filtered.max == 25.0)
        #expect(BenchmarkPercentile.nearestRank([], 50) == 0.0)
        #expect(BenchmarkPercentile.nearestRank(four, .nan) == 0.0)

        // Clip-level median and IQR (nearest-rank p50 and p75 - p25).
        // Clip CERs: 0.0, 0.1, 0.2, 0.5 -> p25 = 0.0, median = 0.1, p75 = 0.2, iqr = 0.2.
        let clips = [
            BenchmarkClip(category: "c", reference: "あいうえおかきくけこ", hypothesis: "あいうえおかきくけこ"), // 0.0
            BenchmarkClip(category: "c", reference: "あいうえおかきくけこ", hypothesis: "あいうえおかきくけさ"), // 0.1
            BenchmarkClip(category: "c", reference: "あいうえおかきくけこ", hypothesis: "あいうえおかきくさし"), // 0.2
            BenchmarkClip(category: "c", reference: "あい", hypothesis: "あう")                                // 0.5
        ]
        let dist = try #require(BenchmarkCER.clipDistribution(clips: clips))
        #expect(dist.count == 4)
        #expect(approxEqual(dist.p25, 0.0))
        #expect(approxEqual(dist.median, 0.1))
        #expect(approxEqual(dist.p75, 0.2))
        #expect(approxEqual(dist.iqr, 0.2))

        // With an added failed clip, penalty distribution includes 1.0 (sorted: 0.0, 0.1, 0.2, 0.5, 1.0).
        // Ranks for n=5: p25=ceil(1.25)=2 -> 0.1, p50=ceil(2.5)=3 -> 0.2, p75=ceil(3.75)=4 -> 0.5, IQR=0.4.
        let withFailure = clips + [BenchmarkClip(category: "c", reference: "テスト", hypothesis: nil)]
        let penaltyDist = try #require(BenchmarkCER.clipDistribution(clips: withFailure, includeFailurePenalty: true))
        #expect(penaltyDist.count == 5)
        #expect(approxEqual(penaltyDist.p25, 0.1))
        #expect(approxEqual(penaltyDist.median, 0.2))
        #expect(approxEqual(penaltyDist.p75, 0.5))
        #expect(approxEqual(penaltyDist.iqr, 0.4))
        #expect(BenchmarkCER.clipDistribution(clips: []) == nil)
    }

    @Test func costAndFreeQuotaLogic() throws {
        // AmiVoice free-tier boundary: 3,599 s / 3,600 s / 3,601 s.
        let below = BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: 3_599)
        #expect(below.freeSeconds == 3_599)
        #expect(below.billableSeconds == 0)
        #expect(below.marginalJPY == 0)

        let atCap = BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: 3_600)
        #expect(atCap.freeSeconds == 3_600)
        #expect(atCap.billableSeconds == 0)
        #expect(atCap.marginalJPY == 0)

        let overByOne = BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: 3_601)
        #expect(overByOne.freeSeconds == 3_600)
        #expect(overByOne.billableSeconds == 1)
        #expect(approxEqual(overByOne.marginalJPY, 0.04125))

        let tenMinutesOver = BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: 4_200)
        #expect(tenMinutesOver.freeSeconds == 3_600)
        #expect(tenMinutesOver.billableSeconds == 600)
        #expect(approxEqual(tenMinutesOver.marginalJPY, 24.75))

        // Invalid / negative speech seconds never produce negative cost or NaN.
        #expect(BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: -10) == BenchmarkCost.AmiVoiceQuota(freeSeconds: 0, billableSeconds: 0, marginalJPY: 0))
        #expect(BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: .nan) == BenchmarkCost.AmiVoiceQuota(freeSeconds: 0, billableSeconds: 0, marginalJPY: 0))
        #expect(BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: .infinity) == BenchmarkCost.AmiVoiceQuota(freeSeconds: 0, billableSeconds: 0, marginalJPY: 0))

        // Per-engine monthly buckets are independent.
        let byEngine = BenchmarkCost.amiVoiceQuotaByEngine([
            .e2eJapaneseGeneral: 3_601,
            .e2eJapaneseGeneralBatch: 3_000
        ])
        let general = try #require(byEngine[.e2eJapaneseGeneral])
        let batch = try #require(byEngine[.e2eJapaneseGeneralBatch])
        #expect(general.billableSeconds == 1)
        #expect(approxEqual(general.marginalJPY, 0.04125))
        #expect(batch.freeSeconds == 3_000)
        #expect(batch.billableSeconds == 0)
        #expect(batch.marginalJPY == 0)

        // AmiVoice effective ¥/audio-min = 2.475 * (speechSec / wallAudioSec), 0 when wallAudioSec == 0.
        #expect(approxEqual(BenchmarkCost.amiVoiceEffectiveJPYPerAudioMinute(speechSeconds: 30, wallAudioSeconds: 60), 1.2375))
        #expect(approxEqual(BenchmarkCost.amiVoiceEffectiveJPYPerAudioMinute(speechSeconds: 45, wallAudioSeconds: 60), 1.85625))
        #expect(BenchmarkCost.amiVoiceEffectiveJPYPerAudioMinute(speechSeconds: 30, wallAudioSeconds: 0) == 0.0)
        #expect(BenchmarkCost.amiVoiceEffectiveJPYPerAudioMinute(speechSeconds: 30, wallAudioSeconds: -10) == 0.0)

        // Gemini Live blended and token-derived cost at default FX (158) and custom FX (150).
        #expect(approxEqual(BenchmarkCost.geminiBlendedCostUSD(audioSeconds: 60), 0.009))
        #expect(approxEqual(BenchmarkCost.geminiBlendedCostJPY(audioSeconds: 60), 1.422))
        #expect(approxEqual(BenchmarkCost.geminiBlendedJPYPerAudioMinute(), 1.422))
        #expect(approxEqual(BenchmarkCost.geminiBlendedCostJPY(audioSeconds: 60, usdToJPY: 150), 1.35))

        // 100,000 prompt × $3.50/1M ($0.35) + 10,000 candidates × $21.00/1M ($0.21) = $0.56.
        let tokenUSD = BenchmarkCost.geminiTokenCostUSD(promptTokens: 100_000, candidateTokens: 10_000)
        #expect(approxEqual(tokenUSD, 0.56))
        #expect(approxEqual(BenchmarkCost.geminiTokenCostJPY(promptTokens: 100_000, candidateTokens: 10_000), 88.48))
        #expect(approxEqual(BenchmarkCost.geminiTokenCostJPY(promptTokens: 100_000, candidateTokens: 10_000, usdToJPY: 150), 84.0))
        #expect(approxEqual(BenchmarkCost.geminiTokenJPYPerAudioMinute(promptTokens: 100_000, candidateTokens: 10_000, wallAudioSeconds: 60), 88.48))
        #expect(BenchmarkCost.geminiTokenJPYPerAudioMinute(promptTokens: 100_000, candidateTokens: 10_000, wallAudioSeconds: 0) == 0.0)

        let fullEstimate = BenchmarkCost.geminiEstimate(audioSeconds: 60, promptTokens: 100_000, candidateTokens: 10_000)
        #expect(approxEqual(fullEstimate.blendedUSD, 0.009))
        #expect(approxEqual(fullEstimate.blendedJPY, 1.422))
        let fullTokenUSD = try #require(fullEstimate.tokenUSD)
        let fullTokenJPY = try #require(fullEstimate.tokenJPY)
        #expect(approxEqual(fullTokenUSD, 0.56))
        #expect(approxEqual(fullTokenJPY, 88.48))

        let partialEstimate = BenchmarkCost.geminiEstimate(audioSeconds: 60, promptTokens: 100_000, candidateTokens: nil)
        #expect(partialEstimate.tokenUSD == nil)
        #expect(partialEstimate.tokenJPY == nil)

        let symmetricPartialEstimate = BenchmarkCost.geminiEstimate(audioSeconds: 60, promptTokens: nil, candidateTokens: 10_000)
        #expect(symmetricPartialEstimate.tokenUSD == nil)
        #expect(symmetricPartialEstimate.tokenJPY == nil)

        // Apple is always ¥0.
        #expect(BenchmarkCost.appleCostJPY(audioSeconds: 0) == 0.0)
        #expect(BenchmarkCost.appleCostJPY(audioSeconds: 3_600) == 0.0)
        #expect(BenchmarkCost.appleJPYPerAudioMinute() == 0.0)
    }

    @Test func strictCERTransformInjection() {
        let stripSpaces: @Sendable (String) -> String = { $0.replacingOccurrences(of: " ", with: "") }

        // "東京 駅へ 行く" (8 chars) vs "東京駅へ行く" (6 chars):
        // Raw strict CER = 2 / 8 = 0.25; space-stripped strict CER = 0.0.
        #expect(approxEqual(BenchmarkCER.clipStrict(ref: "東京 駅へ 行く", hyp: "東京駅へ行く"), 0.25))
        #expect(BenchmarkCER.clipStrict(ref: "東京 駅へ 行く", hyp: "東京駅へ行く", transform: stripSpaces) == 0.0)

        // "今日 は 晴れ。" (8 chars) vs "今日は雨。" (5 chars):
        // Raw strict CER = 4 / 8 = 0.50; after stripping spaces ("今日は晴れ。" 6 chars vs "今日は雨。" 5 chars) = 2 / 6 = 1/3.
        #expect(approxEqual(BenchmarkCER.clipStrict(ref: "今日 は 晴れ。", hyp: "今日は雨。"), 0.5))
        #expect(approxEqual(BenchmarkCER.clipStrict(ref: "今日 は 晴れ。", hyp: "今日は雨。", transform: stripSpaces), 1.0 / 3.0))

        // Corpus mode with injected transform matches hand-computed raw sums: (0 + 2) / (6 + 6) = 1/6.
        let clips = [
            BenchmarkClip(category: "sp", reference: "東京 駅へ 行く", hypothesis: "東京駅へ行く"),
            BenchmarkClip(category: "sp", reference: "今日 は 晴れ。", hypothesis: "今日は雨。")
        ]
        #expect(approxEqual(BenchmarkCER.corpusMicroAverage(clips: clips, mode: .strict), 6.0 / 16.0))
        #expect(approxEqual(
            BenchmarkCER.corpusMicroAverage(clips: clips, mode: .strictTransformed(stripSpaces)),
            2.0 / 12.0
        ))

        // Failure penalty under .strict vs .strictTransformed uses transformed N_ref for failed clips.
        let clipsWithFailure = [
            BenchmarkClip(category: "sp", reference: "東京 駅へ 行く", hypothesis: "東京駅へ行く"),
            BenchmarkClip(category: "sp", reference: "今日 は 晴れ。", hypothesis: nil)
        ]
        #expect(approxEqual(
            BenchmarkCER.corpusMicroAverageWithFailurePenalty(clips: clipsWithFailure, mode: .strict),
            10.0 / 16.0
        ))
        #expect(approxEqual(
            BenchmarkCER.corpusMicroAverageWithFailurePenalty(clips: clipsWithFailure, mode: .strictTransformed(stripSpaces)),
            6.0 / 12.0
        ))

        // Injected transform also composes directly with KoeBridgeCore's JapaneseDictationSpacing.adopt.
        let adoptTransform: @Sendable (String) -> String = {
            JapaneseDictationSpacing.adopt($0, enabled: true, protectedTerms: [])
        }
        #expect(BenchmarkCER.clipStrict(ref: "東京 駅へ 行く", hyp: "東京駅へ行く", transform: adoptTransform) == 0.0)
        #expect(approxEqual(
            BenchmarkCER.clipStrict(ref: "今日 は 晴れ。", hyp: "今日は雨。", transform: adoptTransform),
            1.0 / 3.0
        ))
    }

    @Test func strictTransformPreservesCanonicalEquivalenceBeforeAdopt() {
        let adoptTransform: @Sendable (String) -> String = {
            JapaneseDictationSpacing.adopt($0, enabled: true, protectedTerms: [])
        }

        #expect(BenchmarkCER.clipStrict(ref: "が 駅", hyp: "か\u{3099} 駅", transform: adoptTransform) == 0.0)

        let nfdScore = BenchmarkCER.scoreStrict(ref: "か\u{3099} 駅", hyp: "", transform: adoptTransform)
        #expect(nfdScore.referenceLength == 2)

        let penaltyClips = [
            BenchmarkClip(category: "nfd", reference: "たち", hypothesis: "たち"),
            BenchmarkClip(category: "nfd", reference: "か\u{3099} 駅", hypothesis: nil)
        ]
        #expect(approxEqual(
            BenchmarkCER.corpusMicroAverageWithFailurePenalty(clips: penaltyClips, mode: .strictTransformed(adoptTransform)),
            0.5
        ))
    }
}
