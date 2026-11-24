import Foundation

/// Presentation-only totals of primary recognition attempts, including all outcomes.
public enum UsageSummary {
    /// Google's published blended estimate for gemini-3.5-transcribe-live,
    /// audio input + text output. Estimate only, not a billing calculation.
    public static let blendedUSDPerMinute = 0.009

    /// AmiVoice Cloud Platform monthly free VAD-detected speech allowance per individual engine (60 min).
    public static let amiVoiceFreeSecondsPerEnginePerMonth: Double = 3_600

    /// AmiVoice WebSocket/Sync `nolog` General tax-included rate (JPY per billed speech second).
    public static let amiVoiceNologJPYPerSecond: Double = AmiVoiceEngine.e2eJapaneseGeneral.nologPriceJPYPerSecond

    /// Gregorian calendar in JST (UTC+9), matching AmiVoice Cloud Platform monthly billing boundaries.
    public static var jstCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        return calendar
    }

    public struct DayTotal: Equatable, Sendable {
        public let dayStart: Date
        public var takes: Int
        public var geminiSeconds: Double
        public var appleSeconds: Double
        public var amiVoiceSeconds: Double
        public var amiVoiceSpeechSeconds: Double
        public var totalSeconds: Double { geminiSeconds + appleSeconds + amiVoiceSeconds }

        public init(dayStart: Date, takes: Int, geminiSeconds: Double, appleSeconds: Double,
                    amiVoiceSeconds: Double = 0, amiVoiceSpeechSeconds: Double = 0) {
            self.dayStart = dayStart
            self.takes = takes
            self.geminiSeconds = geminiSeconds
            self.appleSeconds = appleSeconds
            self.amiVoiceSeconds = amiVoiceSeconds
            self.amiVoiceSpeechSeconds = amiVoiceSpeechSeconds
        }
    }

    /// Estimated AmiVoice monthly usage for one engine variant bucket within a JST calendar month.
    /// `UsageMonitorArchive` retains 30 rolling days, so this is a local estimate; AmiVoice MyPage is authoritative.
    public struct AmiVoiceEngineMonthUsage: Equatable, Sendable {
        /// Provider engine variant (e.g. `"-a2-ja-general"`), or `nil` for untagged records.
        public let engineVariant: String?
        public let takes: Int
        public let audioSeconds: Double
        /// Sum of `speechSeconds ?? audioSeconds` across primary AmiVoice takes in the month.
        public let speechSeconds: Double
        /// Number of takes without VAD `speechSeconds` that fell back to `audioSeconds`.
        public let fallbackToAudioCount: Int
        public let freeAllowanceSeconds: Double
        public let priceJPYPerSecond: Double

        /// Whole billed speech seconds above the monthly free allowance (AmiVoice floors monthly totals to whole seconds).
        public var billableSeconds: Int {
            UsageSummary.wholeBillableSeconds(speechSeconds: speechSeconds,
                                              freeAllowanceSeconds: freeAllowanceSeconds)
        }

        public var freeRemainingSeconds: Double {
            let safeSpeech = max(0, speechSeconds.isFinite ? speechSeconds : 0)
            let safeFree = max(0, freeAllowanceSeconds.isFinite ? freeAllowanceSeconds : 0)
            return max(0, safeFree - safeSpeech)
        }

        public var freeUsageFraction: Double {
            let safeSpeech = max(0, speechSeconds.isFinite ? speechSeconds : 0)
            let safeFree = max(0, freeAllowanceSeconds.isFinite ? freeAllowanceSeconds : 0)
            guard safeFree > 0 else { return 1 }
            return min(1, safeSpeech / safeFree)
        }

        public var estimatedCostJPY: Double {
            let safePrice = max(0, priceJPYPerSecond.isFinite ? priceJPYPerSecond : 0)
            return Double(billableSeconds) * safePrice
        }

        public init(engineVariant: String?, takes: Int, audioSeconds: Double, speechSeconds: Double,
                    fallbackToAudioCount: Int = 0,
                    freeAllowanceSeconds: Double = UsageSummary.amiVoiceFreeSecondsPerEnginePerMonth,
                    priceJPYPerSecond: Double = UsageSummary.amiVoiceNologJPYPerSecond) {
            self.engineVariant = engineVariant
            self.takes = takes
            self.audioSeconds = audioSeconds
            self.speechSeconds = speechSeconds
            self.fallbackToAudioCount = fallbackToAudioCount
            self.freeAllowanceSeconds = freeAllowanceSeconds
            self.priceJPYPerSecond = priceJPYPerSecond
        }
    }

    public static func effectiveAmiVoiceSpeechSeconds(for event: EngineUsageSample) -> Double {
        if let measured = event.speechSeconds, measured.isFinite, measured >= 0 {
            return measured
        }
        return event.audioSeconds
    }

    public static func dailyTotals(events: [EngineUsageSample], days: Int, now: Date,
                                   calendar: Calendar = .current) -> [DayTotal] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        return (0..<days).map { index in
            let start = calendar.date(byAdding: .day, value: index - days + 1, to: today)!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            var total = DayTotal(dayStart: start, takes: 0, geminiSeconds: 0, appleSeconds: 0)
            for event in events where event.purpose != .audioRecheck && event.at >= start && event.at < end {
                total.takes += 1
                switch event.engine {
                case .gemini:
                    total.geminiSeconds += event.audioSeconds
                case .apple:
                    total.appleSeconds += event.audioSeconds
                case .amivoice:
                    total.amiVoiceSeconds += event.audioSeconds
                    total.amiVoiceSpeechSeconds += effectiveAmiVoiceSpeechSeconds(for: event)
                }
            }
            return total
        }
    }

    public static func todayTotals(events: [EngineUsageSample], now: Date,
                                   calendar: Calendar = .current) -> DayTotal {
        dailyTotals(events: events, days: 1, now: now, calendar: calendar)[0]
    }

    /// Aggregates primary AmiVoice events within the calendar month containing `now` (JST by default),
    /// grouped per `engineVariant` because each AmiVoice engine gets its own 60-minute free bucket.
    public static func amiVoiceMonthlyUsage(events: [EngineUsageSample], now: Date,
                                            calendar: Calendar = UsageSummary.jstCalendar) -> [AmiVoiceEngineMonthUsage] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: now) else { return [] }
        struct Accumulator {
            var takes = 0
            var audioSeconds = 0.0
            var speechSeconds = 0.0
            var fallbackToAudioCount = 0
        }
        var grouped: [String?: Accumulator] = [:]
        for event in events where event.engine == .amivoice
            && event.purpose != .audioRecheck
            && event.at >= monthInterval.start
            && event.at < monthInterval.end
        {
            var bucket = grouped[event.engineVariant] ?? Accumulator()
            bucket.takes += 1
            bucket.audioSeconds += event.audioSeconds
            if let measured = event.speechSeconds, measured.isFinite, measured >= 0 {
                bucket.speechSeconds += measured
            } else {
                bucket.speechSeconds += event.audioSeconds
                bucket.fallbackToAudioCount += 1
            }
            grouped[event.engineVariant] = bucket
        }
        return grouped.map { variant, bucket in
            let rate = variant.flatMap(AmiVoiceEngine.init(rawValue:))?.nologPriceJPYPerSecond
                ?? amiVoiceNologJPYPerSecond
            return AmiVoiceEngineMonthUsage(
                engineVariant: variant,
                takes: bucket.takes,
                audioSeconds: bucket.audioSeconds,
                speechSeconds: bucket.speechSeconds,
                fallbackToAudioCount: bucket.fallbackToAudioCount,
                freeAllowanceSeconds: amiVoiceFreeSecondsPerEnginePerMonth,
                priceJPYPerSecond: rate
            )
        }.sorted { lhs, rhs in
            switch (lhs.engineVariant, rhs.engineVariant) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
    }

    public static func estimatedCostUSD(geminiSeconds: Double) -> Double {
        geminiSeconds / 60 * blendedUSDPerMinute
    }

    public static func estimatedAmiVoiceCostJPY(
        speechSeconds: Double,
        freeAllowanceSeconds: Double = amiVoiceFreeSecondsPerEnginePerMonth,
        priceJPYPerSecond: Double = amiVoiceNologJPYPerSecond
    ) -> Double {
        let safePrice = max(0, priceJPYPerSecond.isFinite ? priceJPYPerSecond : 0)
        return Double(wholeBillableSeconds(speechSeconds: speechSeconds,
                                           freeAllowanceSeconds: freeAllowanceSeconds)) * safePrice
    }

    private static func wholeBillableSeconds(speechSeconds: Double, freeAllowanceSeconds: Double) -> Int {
        let clampedSpeech = max(0, speechSeconds.isFinite ? speechSeconds : 0)
        let clampedFree = max(0, freeAllowanceSeconds.isFinite ? freeAllowanceSeconds : 0)
        let maxRepresentable = Double(Int64.max / 2)
        // Small epsilon (< 1 ns vs 1 ms AmiVoice resolution) neutralizes binary float sum drift.
        let wholeSpeech = Int(clamping: Int64(min((clampedSpeech + 1e-9).rounded(.down), maxRepresentable)))
        let wholeFree = Int(clamping: Int64(min((clampedFree + 1e-9).rounded(.down), maxRepresentable)))
        return max(0, wholeSpeech - wholeFree)
    }
}
