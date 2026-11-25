import Foundation

/// Text normalization rules for KoeBridge benchmark CER calculations (design §5.3).
/// Pure, locale-independent Foundation helpers with no I/O, dates, or global mutable state.
public enum BenchmarkNormalize {
    /// Exact punctuation set stripped during `cer_norm` normalization (design §5.3).
    /// NFKC maps `！`→`!`, `？`→`?`, `（`→`(`, `）`→`)` beforehand; all 17 scalars
    /// are listed explicitly to mirror the specification verbatim.
    public static let strippedPunctuation: Set<Unicode.Scalar> = Set("、。,.！？!?・「」『』（）()".unicodeScalars)

    /// Normalizes text identically for `cer_norm` (design §5.3):
    /// 1. Unicode NFKC compatibility composition
    /// 2. ASCII uppercase A–Z lowercased to a–z only (fullwidth Ａ–Ｚ become ASCII in step 1)
    /// 3. Strip every Unicode whitespace scalar and the exact `strippedPunctuation` set
    public static func forCER(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        var result = String.UnicodeScalarView()
        for scalar in nfkc.unicodeScalars {
            if scalar.properties.isWhitespace || strippedPunctuation.contains(scalar) {
                continue
            }
            if scalar.value >= 0x41 && scalar.value <= 0x5A,
               let lowered = Unicode.Scalar(scalar.value + 0x20) {
                result.append(lowered)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// Normalizes text to Unicode NFC for `cer_strict` (design §5.3), preserving
    /// punctuation, casing, whitespace, and width differences.
    public static func forStrictCER(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }
}

/// Exact unweighted Levenshtein edit distance over Swift `Character` (extended grapheme clusters).
public enum BenchmarkLevenshtein {
    /// Returns the minimum number of single-`Character` substitutions, insertions, and deletions
    /// required to transform `source` into `target` in O(min(m, n)) space.
    /// Extended grapheme clusters (such as ZWJ emoji sequences) count as one `Character`.
    public static func edits(_ source: [Character], _ target: [Character]) -> Int {
        var start = 0
        var sourceEnd = source.count
        var targetEnd = target.count

        while start < sourceEnd && start < targetEnd && source[start] == target[start] {
            start += 1
        }
        while sourceEnd > start && targetEnd > start && source[sourceEnd - 1] == target[targetEnd - 1] {
            sourceEnd -= 1
            targetEnd -= 1
        }

        let a = source[start..<sourceEnd]
        let b = target[start..<targetEnd]
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        let (long, short) = a.count >= b.count ? (a, b) : (b, a)
        let shortCount = short.count
        var previous = Array(0...shortCount)
        var current = Array(repeating: 0, count: shortCount + 1)

        for (i, longChar) in long.enumerated() {
            current[0] = i + 1
            for (j, shortChar) in short.enumerated() {
                let cost = longChar == shortChar ? 0 : 1
                let deletion = previous[j + 1] + 1
                let insertion = current[j] + 1
                let substitution = previous[j] + cost
                current[j + 1] = min(deletion, min(insertion, substitution))
            }
            swap(&previous, &current)
        }
        return previous[shortCount]
    }
}

/// A single evaluated benchmark clip carrying its category, reference text,
/// optional hypothesis (`nil` denotes a failed or timed-out clip), and precomputed `N_ref` counts.
public struct BenchmarkClip: Equatable, Sendable {
    public let category: String
    public let reference: String
    /// `nil` represents a failed or timed-out clip with no hypothesis text.
    public let hypothesis: String?
    /// `N_ref` in Swift `Character`s after `BenchmarkNormalize.forCER(_:)`.
    public let normalizedReferenceLength: Int
    /// `N_ref` in Swift `Character`s after `BenchmarkNormalize.forStrictCER(_:)`.
    public let strictReferenceLength: Int

    public var isSucceeded: Bool { hypothesis != nil }

    public init(category: String = "", reference: String, hypothesis: String?) {
        self.category = category
        self.reference = reference
        self.hypothesis = hypothesis
        self.normalizedReferenceLength = BenchmarkNormalize.forCER(reference).count
        self.strictReferenceLength = BenchmarkNormalize.forStrictCER(reference).count
    }
}

/// Raw edit count and reference length for a single clip comparison.
public struct BenchmarkEditScore: Equatable, Sendable {
    public let edits: Int
    public let referenceLength: Int

    /// Clip CER using the empty-reference rule: `0.0` when `referenceLength == 0 && edits == 0`,
    /// `1.0` when `referenceLength == 0 && edits > 0`, otherwise `Double(edits) / Double(referenceLength)`.
    public var cer: Double {
        BenchmarkCER.cerRatio(edits: edits, referenceLength: referenceLength)
    }

    public init(edits: Int, referenceLength: Int) {
        self.edits = max(0, edits)
        self.referenceLength = max(0, referenceLength)
    }
}

/// Nearest-rank clip-level CER distribution (`p25`, `median` = p50, `p75`, `iqr = p75 - p25`).
public struct BenchmarkCERDistribution: Equatable, Sendable {
    public let count: Int
    public let p25: Double
    public let median: Double
    public let p75: Double
    public let iqr: Double

    /// Computes nearest-rank quartiles from finite clip CER values.
    /// Returns `nil` when no finite values are provided.
    public init?(values: [Double]) {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        self.count = sorted.count
        self.p25 = BenchmarkPercentile.nearestRank(sorted, 25)
        self.median = BenchmarkPercentile.nearestRank(sorted, 50)
        self.p75 = BenchmarkPercentile.nearestRank(sorted, 75)
        self.iqr = self.p75 - self.p25
    }
}

/// Character Error Rate (CER), completion rate, and corpus aggregation functions (design §5.3).
public enum BenchmarkCER {
    public typealias Clip = BenchmarkClip

    /// Comparison mode for corpus-level and per-category CER aggregation.
    public enum Mode: Sendable {
        case normalized
        case strict
        case strictTransformed(@Sendable (String) -> String)
    }

    /// Computes CER ratio from raw edit and reference counts without capping above 1.0:
    /// if `referenceLength == 0`, returns `0.0` when `edits == 0` else `1.0`.
    public static func cerRatio(edits: Int, referenceLength: Int) -> Double {
        let safeEdits = max(0, edits)
        let safeRef = max(0, referenceLength)
        if safeRef == 0 {
            return safeEdits == 0 ? 0.0 : 1.0
        }
        return Double(safeEdits) / Double(safeRef)
    }

    /// Raw edit score for `cer_norm` (NFKC + ASCII lowercase + strip whitespace/punctuation).
    public static func scoreNorm(ref: String, hyp: String) -> BenchmarkEditScore {
        let refChars = Array(BenchmarkNormalize.forCER(ref))
        let hypChars = Array(BenchmarkNormalize.forCER(hyp))
        return BenchmarkEditScore(
            edits: BenchmarkLevenshtein.edits(refChars, hypChars),
            referenceLength: refChars.count
        )
    }

    /// Raw edit score for `cer_strict` on raw NFC text.
    public static func scoreStrict(ref: String, hyp: String) -> BenchmarkEditScore {
        let refChars = Array(BenchmarkNormalize.forStrictCER(ref))
        let hypChars = Array(BenchmarkNormalize.forStrictCER(hyp))
        return BenchmarkEditScore(
            edits: BenchmarkLevenshtein.edits(refChars, hypChars),
            referenceLength: refChars.count
        )
    }

    /// Raw edit score for `cer_strict` after NFC-normalizing both texts and applying
    /// `transform` uniformly to them.
    public static func scoreStrict(
        ref: String,
        hyp: String,
        transform: (String) -> String
    ) -> BenchmarkEditScore {
        scoreStrict(
            ref: transform(BenchmarkNormalize.forStrictCER(ref)),
            hyp: transform(BenchmarkNormalize.forStrictCER(hyp))
        )
    }

    /// Clip-level `cer_norm` (primary metric).
    public static func clipNorm(ref: String, hyp: String) -> Double {
        scoreNorm(ref: ref, hyp: hyp).cer
    }

    /// Clip-level `cer_strict` on raw NFC text.
    public static func clipStrict(ref: String, hyp: String) -> Double {
        scoreStrict(ref: ref, hyp: hyp).cer
    }

    /// Clip-level `cer_strict` after NFC-normalizing both texts and applying `transform` uniformly to them.
    public static func clipStrict(
        ref: String,
        hyp: String,
        transform: (String) -> String
    ) -> Double {
        scoreStrict(ref: ref, hyp: hyp, transform: transform).cer
    }

    /// Corpus micro-average (`Σedits / ΣN_ref`) over succeeded clips (`hypothesis != nil`) using raw sums.
    /// Failed clips are reported separately via `completionRate(clips:)` / `failedCount(clips:)`
    /// and penalized in `corpusMicroAverageWithFailurePenalty(clips:)`.
    /// Returns `nil` when all clips failed so a fully failed corpus is not reported as CER 0.0;
    /// empty input remains `0.0`.
    public static func corpusMicroAverage(
        clips: [BenchmarkClip],
        mode: Mode = .normalized
    ) -> Double? {
        let succeeded = succeededCount(clips: clips)
        let failed = clips.count - succeeded
        if succeeded == 0 && failed > 0 {
            return nil
        }

        var totalEdits = 0
        var totalRef = 0
        for clip in clips {
            guard let hyp = clip.hypothesis else { continue }
            let editScore = Self.score(ref: clip.reference, hyp: hyp, mode: mode)
            totalEdits += editScore.edits
            totalRef += editScore.referenceLength
        }
        return cerRatio(edits: totalEdits, referenceLength: totalRef)
    }

    /// Corpus micro-average (`Σedits / ΣN_ref`) where every failed clip (`hypothesis == nil`)
    /// incurs a 100% deletion penalty (`edits = N_ref`, denominator `+= N_ref`).
    public static func corpusMicroAverageWithFailurePenalty(
        clips: [BenchmarkClip],
        mode: Mode = .normalized
    ) -> Double {
        var totalEdits = 0
        var totalRef = 0
        for clip in clips {
            if let hyp = clip.hypothesis {
                let editScore = Self.score(ref: clip.reference, hyp: hyp, mode: mode)
                totalEdits += editScore.edits
                totalRef += editScore.referenceLength
            } else {
                let nRef = Self.referenceLength(for: clip, mode: mode)
                totalEdits += nRef
                totalRef += nRef
            }
        }
        return cerRatio(edits: totalEdits, referenceLength: totalRef)
    }

    /// Per-category corpus micro-average over succeeded clips.
    /// A category whose clips all failed maps to `nil` rather than CER 0.0.
    public static func perCategoryMicroAverage(
        clips: [BenchmarkClip],
        mode: Mode = .normalized
    ) -> [String: Double?] {
        let grouped = Dictionary(grouping: clips, by: \.category)
        return grouped.mapValues { corpusMicroAverage(clips: $0, mode: mode) }
    }

    /// Per-category corpus micro-average with 100% deletion penalty on failed clips.
    public static func perCategoryMicroAverageWithFailurePenalty(
        clips: [BenchmarkClip],
        mode: Mode = .normalized
    ) -> [String: Double] {
        let grouped = Dictionary(grouping: clips, by: \.category)
        return grouped.mapValues { corpusMicroAverageWithFailurePenalty(clips: $0, mode: mode) }
    }

    /// Clip-level nearest-rank median and IQR (`p75 - p25`) over clip CER values.
    /// When `includeFailurePenalty` is `false`, only succeeded clips are included;
    /// when `true`, each failed clip contributes `cerRatio(edits: N_ref, referenceLength: N_ref)`.
    public static func clipDistribution(
        clips: [BenchmarkClip],
        mode: Mode = .normalized,
        includeFailurePenalty: Bool = false
    ) -> BenchmarkCERDistribution? {
        var values: [Double] = []
        values.reserveCapacity(clips.count)
        for clip in clips {
            if let hyp = clip.hypothesis {
                values.append(Self.score(ref: clip.reference, hyp: hyp, mode: mode).cer)
            } else if includeFailurePenalty {
                let nRef = Self.referenceLength(for: clip, mode: mode)
                values.append(cerRatio(edits: nRef, referenceLength: nRef))
            }
        }
        return BenchmarkCERDistribution(values: values)
    }

    /// Fraction of clips that succeeded (`succeeded_clips / total_clips`).
    /// Returns `0.0` when `clips` is empty.
    public static func completionRate(clips: [BenchmarkClip]) -> Double {
        guard !clips.isEmpty else { return 0.0 }
        return Double(succeededCount(clips: clips)) / Double(clips.count)
    }

    /// Number of succeeded clips (`hypothesis != nil`).
    public static func succeededCount(clips: [BenchmarkClip]) -> Int {
        clips.reduce(into: 0) { count, clip in
            if clip.isSucceeded { count += 1 }
        }
    }

    /// Number of failed or timed-out clips (`hypothesis == nil`).
    public static func failedCount(clips: [BenchmarkClip]) -> Int {
        clips.count - succeededCount(clips: clips)
    }

    private static func score(ref: String, hyp: String, mode: Mode) -> BenchmarkEditScore {
        switch mode {
        case .normalized:
            return scoreNorm(ref: ref, hyp: hyp)
        case .strict:
            return scoreStrict(ref: ref, hyp: hyp)
        case .strictTransformed(let transform):
            return scoreStrict(ref: ref, hyp: hyp, transform: transform)
        }
    }

    private static func referenceLength(for clip: BenchmarkClip, mode: Mode) -> Int {
        switch mode {
        case .normalized:
            return clip.normalizedReferenceLength
        case .strict:
            return clip.strictReferenceLength
        case .strictTransformed(let transform):
            let normalizedReference = BenchmarkNormalize.forStrictCER(clip.reference)
            return BenchmarkNormalize.forStrictCER(transform(normalizedReference)).count
        }
    }
}

/// Nearest-rank percentile calculations for latency and clip-level CER distributions.
public enum BenchmarkPercentile {
    /// Nearest-rank percentile over an ascending-sorted array of `n` samples:
    /// `p_k` is the element at 1-based rank `ceil(k / 100 * n)`.
    /// Computed as `((p * Double(n)) / 100.0).rounded(.up)` to prevent binary float drift
    /// when `p * n` is an exact multiple of 100 (e.g. `p = 14, n = 100`).
    /// Returns `0.0` when `sorted` is empty or `p` is NaN; clamps `p <= 0` to `sorted[0]`
    /// and `p >= 100` to `sorted[n - 1]`.
    public static func nearestRank(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty, !p.isNaN else { return 0.0 }
        if p <= 0 { return sorted[0] }
        if p >= 100 { return sorted[sorted.count - 1] }
        let rank = Int(((p * Double(sorted.count)) / 100.0).rounded(.up))
        let index = min(max(rank - 1, 0), sorted.count - 1)
        return sorted[index]
    }
}

/// Latency summary (`p50`, `p90`, `p95`, `max`) in milliseconds using nearest-rank percentiles.
/// For empty input (such as `ttfi_ms` on `-a2b-ja-general`), `count` is `0` and all
/// percentile/max fields are `nil` so missing measurements (`N/A`) are distinct from `0 ms`.
public struct LatencySummary: Equatable, Sendable {
    public static let empty = LatencySummary(samples: [])

    public let count: Int
    public let p50: Double?
    public let p90: Double?
    public let p95: Double?
    public let max: Double?

    /// Summarizes millisecond latency samples (sorted internally; non-finite values ignored).
    public init(samples: [Double]) {
        let sorted = samples.filter(\.isFinite).sorted()
        self.count = sorted.count
        guard let maximum = sorted.last else {
            self.p50 = nil
            self.p90 = nil
            self.p95 = nil
            self.max = nil
            return
        }
        self.p50 = BenchmarkPercentile.nearestRank(sorted, 50)
        self.p90 = BenchmarkPercentile.nearestRank(sorted, 90)
        self.p95 = BenchmarkPercentile.nearestRank(sorted, 95)
        self.max = maximum
    }
}

/// Pure cost and monthly free-quota calculations for Apple, Gemini Live, and AmiVoice (design §5.3).
public enum BenchmarkCost {
    /// Default illustrative FX rate per `docs/cost-estimate.md:15` (1 USD = 158 JPY).
    public static let defaultUSDJPY: Double = 158.0
    /// AmiVoice monthly free VAD speech allowance per individual engine (60 min = 3,600 s).
    public static let amiVoiceFreeSecondsPerMonth: Double = UsageSummary.amiVoiceFreeSecondsPerEnginePerMonth
    /// AmiVoice WebSocket/Sync `nolog` General tax-included marginal rate (¥0.04125 / speech-second).
    public static let amiVoiceNologJPYPerSecond: Double = UsageSummary.amiVoiceNologJPYPerSecond
    /// AmiVoice `nolog` marginal rate per speech-minute (¥2.475 / speech-min = 60 × ¥0.04125/s).
    public static let amiVoiceNologJPYPerSpeechMinute: Double = 2.475
    /// Published Gemini Live blended reference rate ($0.009 / audio-min).
    public static let geminiBlendedUSDPerMinute: Double = UsageSummary.blendedUSDPerMinute
    /// Published Gemini Live audio input token rate ($3.50 / 1M prompt tokens).
    public static let geminiPromptUSDPerMillionTokens: Double = 3.50
    /// Published Gemini Live output token rate including thinking tokens ($21.00 / 1M candidate tokens).
    public static let geminiCandidateUSDPerMillionTokens: Double = 21.00

    /// Per-engine AmiVoice monthly speech quota split into free tier and marginal paid usage.
    public struct AmiVoiceQuota: Equatable, Sendable {
        public let freeSeconds: Double
        public let billableSeconds: Double
        public let marginalJPY: Double

        public init(freeSeconds: Double, billableSeconds: Double, marginalJPY: Double) {
            self.freeSeconds = freeSeconds
            self.billableSeconds = billableSeconds
            self.marginalJPY = marginalJPY
        }
    }

    /// Gemini Live cost estimate separating the published blended rate and optional token-derived cost.
    public struct GeminiEstimate: Equatable, Sendable {
        public let blendedUSD: Double
        public let blendedJPY: Double
        public let tokenUSD: Double?
        public let tokenJPY: Double?

        public init(blendedUSD: Double, blendedJPY: Double, tokenUSD: Double?, tokenJPY: Double?) {
            self.blendedUSD = blendedUSD
            self.blendedJPY = blendedJPY
            self.tokenUSD = tokenUSD
            self.tokenJPY = tokenJPY
        }
    }

    /// Splits an engine's monthly AmiVoice speech seconds into free-tier and billable seconds,
    /// returning the marginal paid JPY cost (`billableSeconds × ¥0.04125/s`).
    /// Uses continuous seconds so `freeSeconds + billableSeconds == max(0, monthlySpeechSeconds)`.
    public static func amiVoiceQuota(
        monthlySpeechSeconds: Double,
        freeTierSeconds: Double = amiVoiceFreeSecondsPerMonth,
        jpyPerSpeechSecond: Double = amiVoiceNologJPYPerSecond
    ) -> AmiVoiceQuota {
        let speech = nonNegativeFinite(monthlySpeechSeconds)
        let freeTier = nonNegativeFinite(freeTierSeconds)
        let rate = nonNegativeFinite(jpyPerSpeechSecond)
        let freeSeconds = min(speech, freeTier)
        let billableSeconds = max(0.0, speech - freeTier)
        let marginalJPY = billableSeconds * rate
        return AmiVoiceQuota(
            freeSeconds: freeSeconds,
            billableSeconds: billableSeconds,
            marginalJPY: marginalJPY
        )
    }

    /// Evaluates independent per-engine monthly free-tier buckets for AmiVoice engines.
    public static func amiVoiceQuotaByEngine(
        _ monthlySpeechSecondsByEngine: [AmiVoiceEngine: Double],
        freeTierSeconds: Double = amiVoiceFreeSecondsPerMonth
    ) -> [AmiVoiceEngine: AmiVoiceQuota] {
        var result: [AmiVoiceEngine: AmiVoiceQuota] = [:]
        result.reserveCapacity(monthlySpeechSecondsByEngine.count)
        for (engine, speechSeconds) in monthlySpeechSecondsByEngine {
            result[engine] = amiVoiceQuota(
                monthlySpeechSeconds: speechSeconds,
                freeTierSeconds: freeTierSeconds,
                jpyPerSpeechSecond: engine.nologPriceJPYPerSecond
            )
        }
        return result
    }

    /// Effective marginal AmiVoice cost per wall-clock audio minute:
    /// `2.475 × (speechSeconds / wallAudioSeconds)`, or `0.0` when `wallAudioSeconds <= 0` or non-finite.
    public static func amiVoiceEffectiveJPYPerAudioMinute(
        speechSeconds: Double,
        wallAudioSeconds: Double,
        jpyPerSpeechMinute: Double = amiVoiceNologJPYPerSpeechMinute
    ) -> Double {
        let wall = nonNegativeFinite(wallAudioSeconds)
        let speech = nonNegativeFinite(speechSeconds)
        let rate = nonNegativeFinite(jpyPerSpeechMinute)
        guard wall > 0, speech > 0, rate > 0 else { return 0.0 }
        return rate * (speech / wall)
    }

    /// Apple on-device recognition has zero API cost.
    public static func appleCostJPY(audioSeconds: Double) -> Double {
        _ = audioSeconds
        return 0.0
    }

    /// Apple on-device recognition cost per audio minute is always ¥0.00/min.
    public static func appleJPYPerAudioMinute() -> Double {
        0.0
    }

    /// Gemini Live published blended USD estimate (`audioSeconds / 60 × $0.009/min`).
    public static func geminiBlendedCostUSD(audioSeconds: Double) -> Double {
        (nonNegativeFinite(audioSeconds) / 60.0) * geminiBlendedUSDPerMinute
    }

    /// Gemini Live published blended JPY estimate at `usdToJPY` (default 158).
    public static func geminiBlendedCostJPY(
        audioSeconds: Double,
        usdToJPY: Double = defaultUSDJPY
    ) -> Double {
        geminiBlendedCostUSD(audioSeconds: audioSeconds) * nonNegativeFinite(usdToJPY)
    }

    /// Gemini Live published blended JPY per audio minute (`$0.009 × usdToJPY`).
    public static func geminiBlendedJPYPerAudioMinute(usdToJPY: Double = defaultUSDJPY) -> Double {
        geminiBlendedUSDPerMinute * nonNegativeFinite(usdToJPY)
    }

    /// Gemini Live token-derived USD estimate:
    /// `promptTokens × $3.50/1M + candidateTokens × $21.00/1M`.
    public static func geminiTokenCostUSD(promptTokens: Int, candidateTokens: Int) -> Double {
        let safePrompt = max(0, promptTokens)
        let safeCandidates = max(0, candidateTokens)
        return (Double(safePrompt) * geminiPromptUSDPerMillionTokens
                + Double(safeCandidates) * geminiCandidateUSDPerMillionTokens) / 1_000_000.0
    }

    /// Gemini Live token-derived JPY estimate converted at `usdToJPY` (default 158).
    public static func geminiTokenCostJPY(
        promptTokens: Int,
        candidateTokens: Int,
        usdToJPY: Double = defaultUSDJPY
    ) -> Double {
        geminiTokenCostUSD(promptTokens: promptTokens, candidateTokens: candidateTokens)
            * nonNegativeFinite(usdToJPY)
    }

    /// Gemini Live token-derived effective JPY per wall-clock audio minute.
    /// Returns `0.0` when `wallAudioSeconds <= 0` or non-finite.
    public static func geminiTokenJPYPerAudioMinute(
        promptTokens: Int,
        candidateTokens: Int,
        wallAudioSeconds: Double,
        usdToJPY: Double = defaultUSDJPY
    ) -> Double {
        let wall = nonNegativeFinite(wallAudioSeconds)
        guard wall > 0 else { return 0.0 }
        let totalJPY = geminiTokenCostJPY(
            promptTokens: promptTokens,
            candidateTokens: candidateTokens,
            usdToJPY: usdToJPY
        )
        return totalJPY / (wall / 60.0)
    }

    /// Combined Gemini Live estimate returning blended USD/JPY plus token-derived USD/JPY
    /// whenever both `promptTokens` and `candidateTokens` are observed.
    public static func geminiEstimate(
        audioSeconds: Double,
        promptTokens: Int? = nil,
        candidateTokens: Int? = nil,
        usdToJPY: Double = defaultUSDJPY
    ) -> GeminiEstimate {
        let fx = nonNegativeFinite(usdToJPY)
        let blendedUSD = geminiBlendedCostUSD(audioSeconds: audioSeconds)
        let blendedJPY = blendedUSD * fx
        let tokenUSD: Double?
        let tokenJPY: Double?
        if let promptTokens, let candidateTokens {
            let usd = geminiTokenCostUSD(promptTokens: promptTokens, candidateTokens: candidateTokens)
            tokenUSD = usd
            tokenJPY = usd * fx
        } else {
            tokenUSD = nil
            tokenJPY = nil
        }
        return GeminiEstimate(
            blendedUSD: blendedUSD,
            blendedJPY: blendedJPY,
            tokenUSD: tokenUSD,
            tokenJPY: tokenJPY
        )
    }

    private static func nonNegativeFinite(_ value: Double) -> Double {
        (value.isFinite && value > 0) ? value : 0.0
    }
}
