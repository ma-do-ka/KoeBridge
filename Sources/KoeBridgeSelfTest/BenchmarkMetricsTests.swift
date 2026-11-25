import Foundation
import KoeBridgeCore

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

    func kanjiKanaCERIdenticalSubstitutionInsertionDeletion() {
        check(BenchmarkCER.clipNorm(ref: "今日は晴れです", hyp: "今日は晴れです") == 0.0)
        check(BenchmarkCER.clipStrict(ref: "今日は晴れです", hyp: "今日は晴れです") == 0.0)

        let subScore = BenchmarkCER.scoreNorm(ref: "日本語の音声認識", hyp: "日本語の音声認織")
        check(subScore.edits == 1)
        check(subScore.referenceLength == 8)
        check(approxEqual(subScore.cer, 0.125))
        check(approxEqual(BenchmarkCER.clipNorm(ref: "日本語の音声認識", hyp: "日本語の音声認織"), 0.125))

        let insScore = BenchmarkCER.scoreNorm(ref: "日本語認識", hyp: "日本語の認識")
        check(insScore.edits == 1)
        check(insScore.referenceLength == 5)
        check(approxEqual(insScore.cer, 0.2))

        let delScore = BenchmarkCER.scoreNorm(ref: "日本語の認識", hyp: "日本語認識")
        check(delScore.edits == 1)
        check(delScore.referenceLength == 6)
        check(approxEqual(delScore.cer, 1.0 / 6.0))

        check(approxEqual(BenchmarkCER.clipNorm(ref: "あい", hyp: "あいうえお"), 1.5))

        check(BenchmarkLevenshtein.edits(Array("kitten"), Array("sitting")) == 3)
        check(BenchmarkLevenshtein.edits(Array("sitting"), Array("kitten")) == 3)
        check(BenchmarkLevenshtein.edits(Array("ab"), Array("ba")) == 2)
        check(BenchmarkLevenshtein.edits([], []) == 0)
        check(BenchmarkLevenshtein.edits(Array("abc"), []) == 3)
        check(BenchmarkLevenshtein.edits([], Array("abc")) == 3)
    }

    func nfkcWidthHalfwidthKatakanaAndWhitespaceVariants() {
        check(BenchmarkCER.clipNorm(ref: "ＡＢＣ１２３", hyp: "abc123") == 0.0)
        check(BenchmarkCER.clipStrict(ref: "ＡＢＣ１２３", hyp: "abc123") == 1.0)
        check(BenchmarkCER.clipNorm(ref: "２０２６年１１月", hyp: "2026年11月") == 0.0)
        check(approxEqual(BenchmarkCER.clipStrict(ref: "２０２６年１１月", hyp: "2026年11月"), 0.75))

        let halfwidth = "ｱｲｳｴｵｶﾞｷﾞｸﾞｹﾞｺﾞﾊﾟ"
        let fullwidth = "アイウエオガギグゲゴパ"
        check(BenchmarkNormalize.forCER(halfwidth) == fullwidth)
        check(BenchmarkCER.clipNorm(ref: halfwidth, hyp: fullwidth) == 0.0)
        check(BenchmarkCER.clipStrict(ref: halfwidth, hyp: fullwidth) == 1.0)

        check(BenchmarkCER.clipStrict(ref: "が", hyp: "か\u{3099}") == 0.0)

        let spaced = "東京 \t\n\r\n\u{3000}\u{00A0}\u{2003}\u{2028}駅"
        check(BenchmarkNormalize.forCER(spaced) == "東京駅")
        check(BenchmarkCER.clipNorm(ref: spaced, hyp: "東京駅") == 0.0)
    }

    func punctuationStrippingAndASCIILowercase() {
        check(BenchmarkCER.clipNorm(ref: "今日は、晴れです！？", hyp: "今日は晴れです") == 0.0)
        check(approxEqual(BenchmarkCER.clipStrict(ref: "今日は、晴れです！？", hyp: "今日は晴れです"), 0.3))

        let allStripped = "a、b。c,d.e！f？g!h?i・j「k」l『m』n（o）p(q)r"
        check(BenchmarkNormalize.forCER(allStripped) == "abcdefghijklmnopqr")
        check(BenchmarkNormalize.forCER("メール-送信") == "メール-送信")

        check(BenchmarkCER.clipNorm(ref: "OpenAI API", hyp: "openai api") == 0.0)
        check(approxEqual(BenchmarkCER.clipStrict(ref: "OpenAI API", hyp: "openai api"), 0.6))

        check(BenchmarkNormalize.forCER("ÉＡZ") == "Éaz")
        check(BenchmarkCER.clipNorm(ref: "É", hyp: "é") == 1.0)
    }

    func emptyHypothesisAndEmptyReferenceEdges() {
        check(BenchmarkCER.clipNorm(ref: "こんにちは", hyp: "") == 1.0)
        check(BenchmarkCER.clipStrict(ref: "こんにちは", hyp: "") == 1.0)

        check(BenchmarkCER.clipNorm(ref: "", hyp: "") == 0.0)
        check(BenchmarkCER.clipStrict(ref: "", hyp: "") == 0.0)
        check(BenchmarkCER.clipNorm(ref: "。、！？", hyp: "") == 0.0)
        check(BenchmarkCER.clipStrict(ref: "。、！？", hyp: "") == 1.0)

        check(BenchmarkCER.clipNorm(ref: "", hyp: "ああ") == 1.0)
        check(BenchmarkCER.clipStrict(ref: "", hyp: "ああ") == 1.0)
        check(BenchmarkCER.clipNorm(ref: "。", hyp: "あ") == 1.0)

        let emptyCorpusAverage = BenchmarkCER.corpusMicroAverage(clips: [])
        check(emptyCorpusAverage != nil)
        check(emptyCorpusAverage == 0.0)
        check(BenchmarkCER.corpusMicroAverage(clips: [
            BenchmarkClip(category: "empty", reference: "", hypothesis: "")
        ]) == 0.0)
        check(BenchmarkCER.corpusMicroAverage(clips: [
            BenchmarkClip(category: "empty", reference: "", hypothesis: "ああ")
        ]) == 1.0)
        let rawSumClips = [
            BenchmarkClip(category: "a", reference: "", hypothesis: "あいう"),
            BenchmarkClip(category: "a", reference: "かきくけこさ", hypothesis: "かきくけこさ")
        ]
        check(approxEqual(BenchmarkCER.corpusMicroAverage(clips: rawSumClips), 0.5))
    }

    func emojiAndZWJExtendedGraphemeClusters() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        check(Array(family).count == 1)
        check(BenchmarkNormalize.forCER(family) == family)
        check(BenchmarkLevenshtein.edits(Array(family), []) == 1)

        let normSolo = BenchmarkCER.scoreNorm(ref: family, hyp: "")
        check(normSolo.edits == 1)
        check(normSolo.referenceLength == 1)
        check(normSolo.cer == 1.0)

        let strictSolo = BenchmarkCER.scoreStrict(ref: family, hyp: "")
        check(strictSolo.edits == 1)
        check(strictSolo.referenceLength == 1)
        check(strictSolo.cer == 1.0)

        let mixedRef = "家族\(family)です"
        let deleted = BenchmarkCER.scoreNorm(ref: mixedRef, hyp: "家族です")
        check(deleted.edits == 1)
        check(deleted.referenceLength == 5)
        check(approxEqual(deleted.cer, 0.2))

        let substituted = BenchmarkCER.scoreNorm(ref: mixedRef, hyp: "家族\u{1F600}です")
        check(substituted.edits == 1)
        check(substituted.referenceLength == 5)
        check(approxEqual(substituted.cer, 0.2))
    }

    func corpusMicroAverageDiffersFromMeanOfClipCERs() {
        let clips = [
            BenchmarkClip(category: "short", reference: "あい", hypothesis: "あう"),
            BenchmarkClip(category: "long", reference: "あいうえおかきく", hypothesis: "あいうえおかきく")
        ]
        check(clips[0].normalizedReferenceLength == 2)
        check(clips[1].normalizedReferenceLength == 8)

        let micro = BenchmarkCER.corpusMicroAverage(clips: clips)
        let meanOfClipCERs = (0.5 + 0.0) / 2.0
        check(approxEqual(micro, 0.1))
        check(!approxEqual(micro, meanOfClipCERs))

        let byCategory = BenchmarkCER.perCategoryMicroAverage(clips: clips)
        check(byCategory.count == 2)
        check(approxEqual(categoryValue(byCategory, "short"), 0.5))
        check(approxEqual(categoryValue(byCategory, "long"), 0.0))
    }

    func failurePenaltyAndCompletionRate() {
        let clips = [
            BenchmarkClip(category: "a", reference: "あいうえ", hypothesis: "あいうお"),
            BenchmarkClip(category: "a", reference: "かきくけこさ", hypothesis: "かきくけこさ"),
            BenchmarkClip(category: "b", reference: "たちつてとなにぬねの", hypothesis: nil)
        ]
        check(BenchmarkCER.succeededCount(clips: clips) == 2)
        check(BenchmarkCER.failedCount(clips: clips) == 1)
        check(approxEqual(BenchmarkCER.completionRate(clips: clips), 2.0 / 3.0))

        check(approxEqual(BenchmarkCER.corpusMicroAverage(clips: clips), 0.1))
        check(approxEqual(BenchmarkCER.corpusMicroAverageWithFailurePenalty(clips: clips), 0.55))

        let perCatPenalty = BenchmarkCER.perCategoryMicroAverageWithFailurePenalty(clips: clips)
        check(approxEqual(perCatPenalty["a"] ?? -1, 0.1))
        check(approxEqual(perCatPenalty["b"] ?? -1, 1.0))

        let allFailed = [BenchmarkClip(category: "x", reference: "テスト", hypothesis: nil)]
        check(BenchmarkCER.completionRate(clips: allFailed) == 0.0)
        check(BenchmarkCER.corpusMicroAverage(clips: allFailed) == nil)
        check(BenchmarkCER.corpusMicroAverageWithFailurePenalty(clips: allFailed) == 1.0)
        check(BenchmarkCER.completionRate(clips: []) == 0.0)
        check(BenchmarkCER.corpusMicroAverageWithFailurePenalty(clips: []) == 0.0)
    }

    func allFailedCorpusMicroAverageIsNil() {
        let allFailed = [
            BenchmarkClip(category: "x", reference: "テスト", hypothesis: nil),
            BenchmarkClip(category: "x", reference: "失敗", hypothesis: nil)
        ]
        check(BenchmarkCER.corpusMicroAverage(clips: allFailed) == nil)
    }

    func perCategoryMicroAverageDistinguishesAllFailedCategories() {
        let clips = [
            BenchmarkClip(category: "a", reference: "あいうえおかきくけこ", hypothesis: "あいうえおかきくけさ"),
            BenchmarkClip(category: "b", reference: "たちつてとなにぬねの", hypothesis: nil)
        ]
        let byCategory = BenchmarkCER.perCategoryMicroAverage(clips: clips)
        check(byCategory.count == 2)
        check(approxEqual(categoryValue(byCategory, "a"), 0.1))
        check(hasNilCategoryValue(byCategory, "b"))
    }

    func nearestRankPercentilesLatencySummaryAndClipIQR() throws {
        let one = [42.0]
        check(BenchmarkPercentile.nearestRank(one, 50) == 42.0)
        check(BenchmarkPercentile.nearestRank(one, 90) == 42.0)
        check(BenchmarkPercentile.nearestRank(one, 95) == 42.0)
        let s1 = LatencySummary(samples: one)
        check(s1.count == 1 && s1.p50 == 42.0 && s1.p90 == 42.0 && s1.p95 == 42.0 && s1.max == 42.0)

        let four = [10.0, 20.0, 30.0, 40.0]
        check(BenchmarkPercentile.nearestRank(four, 25) == 10.0)
        check(BenchmarkPercentile.nearestRank(four, 50) == 20.0)
        check(BenchmarkPercentile.nearestRank(four, 75) == 30.0)
        check(BenchmarkPercentile.nearestRank(four, 90) == 40.0)
        check(BenchmarkPercentile.nearestRank(four, 95) == 40.0)
        let s4 = LatencySummary(samples: [30.0, 10.0, 40.0, 20.0])
        check(s4.count == 4 && s4.p50 == 20.0 && s4.p90 == 40.0 && s4.p95 == 40.0 && s4.max == 40.0)

        let ten = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0]
        check(BenchmarkPercentile.nearestRank(ten, 25) == 30.0)
        check(BenchmarkPercentile.nearestRank(ten, 50) == 50.0)
        check(BenchmarkPercentile.nearestRank(ten, 75) == 80.0)
        check(BenchmarkPercentile.nearestRank(ten, 90) == 90.0)
        check(BenchmarkPercentile.nearestRank(ten, 95) == 100.0)
        let s10 = LatencySummary(samples: Array(ten.reversed()))
        check(s10.count == 10 && s10.p50 == 50.0 && s10.p90 == 90.0 && s10.p95 == 100.0 && s10.max == 100.0)

        let hundred = (1...100).map { Double($0) }
        check(BenchmarkPercentile.nearestRank(hundred, 14) == 14.0)
        check(BenchmarkPercentile.nearestRank(hundred, 7) == 7.0)

        check(LatencySummary(samples: []) == LatencySummary.empty)
        check(LatencySummary.empty.count == 0)
        check(LatencySummary.empty.p50 == nil && LatencySummary.empty.p90 == nil && LatencySummary.empty.p95 == nil && LatencySummary.empty.max == nil)
        let filtered = LatencySummary(samples: [.nan, 25.0, .infinity, -Double.infinity])
        check(filtered.count == 1 && filtered.p50 == 25.0 && filtered.max == 25.0)
        check(BenchmarkPercentile.nearestRank([], 50) == 0.0)
        check(BenchmarkPercentile.nearestRank(four, .nan) == 0.0)

        let clips = [
            BenchmarkClip(category: "c", reference: "あいうえおかきくけこ", hypothesis: "あいうえおかきくけこ"),
            BenchmarkClip(category: "c", reference: "あいうえおかきくけこ", hypothesis: "あいうえおかきくけさ"),
            BenchmarkClip(category: "c", reference: "あいうえおかきくけこ", hypothesis: "あいうえおかきくさし"),
            BenchmarkClip(category: "c", reference: "あい", hypothesis: "あう")
        ]
        let dist = try require(BenchmarkCER.clipDistribution(clips: clips))
        check(dist.count == 4)
        check(approxEqual(dist.p25, 0.0))
        check(approxEqual(dist.median, 0.1))
        check(approxEqual(dist.p75, 0.2))
        check(approxEqual(dist.iqr, 0.2))

        let withFailure = clips + [BenchmarkClip(category: "c", reference: "テスト", hypothesis: nil)]
        let penaltyDist = try require(BenchmarkCER.clipDistribution(clips: withFailure, includeFailurePenalty: true))
        check(penaltyDist.count == 5)
        check(approxEqual(penaltyDist.p25, 0.1))
        check(approxEqual(penaltyDist.median, 0.2))
        check(approxEqual(penaltyDist.p75, 0.5))
        check(approxEqual(penaltyDist.iqr, 0.4))
        check(BenchmarkCER.clipDistribution(clips: []) == nil)
    }

    func costAndFreeQuotaLogic() throws {
        let below = BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: 3_599)
        check(below.freeSeconds == 3_599 && below.billableSeconds == 0 && below.marginalJPY == 0)

        let atCap = BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: 3_600)
        check(atCap.freeSeconds == 3_600 && atCap.billableSeconds == 0 && atCap.marginalJPY == 0)

        let overByOne = BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: 3_601)
        check(overByOne.freeSeconds == 3_600 && overByOne.billableSeconds == 1 && approxEqual(overByOne.marginalJPY, 0.04125))

        let tenMinutesOver = BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: 4_200)
        check(tenMinutesOver.freeSeconds == 3_600 && tenMinutesOver.billableSeconds == 600 && approxEqual(tenMinutesOver.marginalJPY, 24.75))

        check(BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: -10) == BenchmarkCost.AmiVoiceQuota(freeSeconds: 0, billableSeconds: 0, marginalJPY: 0))
        check(BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: .nan) == BenchmarkCost.AmiVoiceQuota(freeSeconds: 0, billableSeconds: 0, marginalJPY: 0))
        check(BenchmarkCost.amiVoiceQuota(monthlySpeechSeconds: .infinity) == BenchmarkCost.AmiVoiceQuota(freeSeconds: 0, billableSeconds: 0, marginalJPY: 0))

        let byEngine = BenchmarkCost.amiVoiceQuotaByEngine([
            .e2eJapaneseGeneral: 3_601,
            .e2eJapaneseGeneralBatch: 3_000
        ])
        let general = try require(byEngine[.e2eJapaneseGeneral])
        let batch = try require(byEngine[.e2eJapaneseGeneralBatch])
        check(general.billableSeconds == 1 && approxEqual(general.marginalJPY, 0.04125))
        check(batch.freeSeconds == 3_000 && batch.billableSeconds == 0 && batch.marginalJPY == 0)

        check(approxEqual(BenchmarkCost.amiVoiceEffectiveJPYPerAudioMinute(speechSeconds: 30, wallAudioSeconds: 60), 1.2375))
        check(approxEqual(BenchmarkCost.amiVoiceEffectiveJPYPerAudioMinute(speechSeconds: 45, wallAudioSeconds: 60), 1.85625))
        check(BenchmarkCost.amiVoiceEffectiveJPYPerAudioMinute(speechSeconds: 30, wallAudioSeconds: 0) == 0.0)
        check(BenchmarkCost.amiVoiceEffectiveJPYPerAudioMinute(speechSeconds: 30, wallAudioSeconds: -10) == 0.0)

        check(approxEqual(BenchmarkCost.geminiBlendedCostUSD(audioSeconds: 60), 0.009))
        check(approxEqual(BenchmarkCost.geminiBlendedCostJPY(audioSeconds: 60), 1.422))
        check(approxEqual(BenchmarkCost.geminiBlendedJPYPerAudioMinute(), 1.422))
        check(approxEqual(BenchmarkCost.geminiBlendedCostJPY(audioSeconds: 60, usdToJPY: 150), 1.35))

        let tokenUSD = BenchmarkCost.geminiTokenCostUSD(promptTokens: 100_000, candidateTokens: 10_000)
        check(approxEqual(tokenUSD, 0.56))
        check(approxEqual(BenchmarkCost.geminiTokenCostJPY(promptTokens: 100_000, candidateTokens: 10_000), 88.48))
        check(approxEqual(BenchmarkCost.geminiTokenCostJPY(promptTokens: 100_000, candidateTokens: 10_000, usdToJPY: 150), 84.0))
        check(approxEqual(BenchmarkCost.geminiTokenJPYPerAudioMinute(promptTokens: 100_000, candidateTokens: 10_000, wallAudioSeconds: 60), 88.48))
        check(BenchmarkCost.geminiTokenJPYPerAudioMinute(promptTokens: 100_000, candidateTokens: 10_000, wallAudioSeconds: 0) == 0.0)

        let fullEstimate = BenchmarkCost.geminiEstimate(audioSeconds: 60, promptTokens: 100_000, candidateTokens: 10_000)
        check(approxEqual(fullEstimate.blendedUSD, 0.009))
        check(approxEqual(fullEstimate.blendedJPY, 1.422))
        let fullTokenUSD = try require(fullEstimate.tokenUSD)
        let fullTokenJPY = try require(fullEstimate.tokenJPY)
        check(approxEqual(fullTokenUSD, 0.56))
        check(approxEqual(fullTokenJPY, 88.48))

        let partialEstimate = BenchmarkCost.geminiEstimate(audioSeconds: 60, promptTokens: 100_000, candidateTokens: nil)
        check(partialEstimate.tokenUSD == nil && partialEstimate.tokenJPY == nil)

        let symmetricPartialEstimate = BenchmarkCost.geminiEstimate(audioSeconds: 60, promptTokens: nil, candidateTokens: 10_000)
        check(symmetricPartialEstimate.tokenUSD == nil && symmetricPartialEstimate.tokenJPY == nil)

        check(BenchmarkCost.appleCostJPY(audioSeconds: 0) == 0.0)
        check(BenchmarkCost.appleCostJPY(audioSeconds: 3_600) == 0.0)
        check(BenchmarkCost.appleJPYPerAudioMinute() == 0.0)
    }

    func strictCERTransformInjection() {
        let stripSpaces: @Sendable (String) -> String = { $0.replacingOccurrences(of: " ", with: "") }

        check(approxEqual(BenchmarkCER.clipStrict(ref: "東京 駅へ 行く", hyp: "東京駅へ行く"), 0.25))
        check(BenchmarkCER.clipStrict(ref: "東京 駅へ 行く", hyp: "東京駅へ行く", transform: stripSpaces) == 0.0)

        check(approxEqual(BenchmarkCER.clipStrict(ref: "今日 は 晴れ。", hyp: "今日は雨。"), 0.5))
        check(approxEqual(BenchmarkCER.clipStrict(ref: "今日 は 晴れ。", hyp: "今日は雨。", transform: stripSpaces), 1.0 / 3.0))

        let clips = [
            BenchmarkClip(category: "sp", reference: "東京 駅へ 行く", hypothesis: "東京駅へ行く"),
            BenchmarkClip(category: "sp", reference: "今日 は 晴れ。", hypothesis: "今日は雨。")
        ]
        check(approxEqual(BenchmarkCER.corpusMicroAverage(clips: clips, mode: .strict), 6.0 / 16.0))
        check(approxEqual(
            BenchmarkCER.corpusMicroAverage(clips: clips, mode: .strictTransformed(stripSpaces)),
            2.0 / 12.0
        ))

        let clipsWithFailure = [
            BenchmarkClip(category: "sp", reference: "東京 駅へ 行く", hypothesis: "東京駅へ行く"),
            BenchmarkClip(category: "sp", reference: "今日 は 晴れ。", hypothesis: nil)
        ]
        check(approxEqual(
            BenchmarkCER.corpusMicroAverageWithFailurePenalty(clips: clipsWithFailure, mode: .strict),
            10.0 / 16.0
        ))
        check(approxEqual(
            BenchmarkCER.corpusMicroAverageWithFailurePenalty(clips: clipsWithFailure, mode: .strictTransformed(stripSpaces)),
            6.0 / 12.0
        ))

        let adoptTransform: @Sendable (String) -> String = {
            JapaneseDictationSpacing.adopt($0, enabled: true, protectedTerms: [])
        }
        check(BenchmarkCER.clipStrict(ref: "東京 駅へ 行く", hyp: "東京駅へ行く", transform: adoptTransform) == 0.0)
        check(approxEqual(
            BenchmarkCER.clipStrict(ref: "今日 は 晴れ。", hyp: "今日は雨。", transform: adoptTransform),
            1.0 / 3.0
        ))
    }

    func strictTransformPreservesCanonicalEquivalenceBeforeAdopt() {
        let adoptTransform: @Sendable (String) -> String = {
            JapaneseDictationSpacing.adopt($0, enabled: true, protectedTerms: [])
        }

        check(BenchmarkCER.clipStrict(ref: "が 駅", hyp: "か\u{3099} 駅", transform: adoptTransform) == 0.0)

        let nfdScore = BenchmarkCER.scoreStrict(ref: "か\u{3099} 駅", hyp: "", transform: adoptTransform)
        check(nfdScore.referenceLength == 2)

        let penaltyClips = [
            BenchmarkClip(category: "nfd", reference: "たち", hypothesis: "たち"),
            BenchmarkClip(category: "nfd", reference: "か\u{3099} 駅", hypothesis: nil)
        ]
        check(approxEqual(
            BenchmarkCER.corpusMicroAverageWithFailurePenalty(clips: penaltyClips, mode: .strictTransformed(adoptTransform)),
            0.5
        ))
    }
}
