import Foundation

/// Presentation-only totals of primary recognition attempts, including all outcomes.
public enum UsageSummary {
    /// Google's published blended estimate for gemini-3.5-transcribe-live,
    /// audio input + text output. Estimate only, not a billing calculation.
    public static let blendedUSDPerMinute = 0.009

    public struct DayTotal: Equatable, Sendable {
        public let dayStart: Date
        public var takes: Int
        public var geminiSeconds: Double
        public var appleSeconds: Double
        public var totalSeconds: Double { geminiSeconds + appleSeconds }
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
                case .gemini: total.geminiSeconds += event.audioSeconds
                case .apple: total.appleSeconds += event.audioSeconds
                }
            }
            return total
        }
    }

    public static func todayTotals(events: [EngineUsageSample], now: Date,
                                   calendar: Calendar = .current) -> DayTotal {
        dailyTotals(events: events, days: 1, now: now, calendar: calendar)[0]
    }

    public static func estimatedCostUSD(geminiSeconds: Double) -> Double {
        geminiSeconds / 60 * blendedUSDPerMinute
    }
}
