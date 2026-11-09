import Foundation
import KoeBridgeCore

struct UsageSummaryTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        return value
    }
    private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private var today: Date { calendar.startOfDay(for: now) }

    func zeroFillsThroughToday() {
        let rows = UsageSummary.dailyTotals(events: [], days: 7, now: now, calendar: calendar)
        check(rows.count == 7)
        check(rows.last?.dayStart == today)
        check(rows.allSatisfy { $0.takes == 0 && $0.totalSeconds == 0 })
        check(rows.first?.dayStart == calendar.date(byAdding: .day, value: -6, to: today))
        check(UsageSummary.dailyTotals(events: [], days: 0, now: now, calendar: calendar).isEmpty)
        check(UsageSummary.dailyTotals(events: [], days: -1, now: now, calendar: calendar).isEmpty)
    }

    func bucketsAtCalendarDayBoundaries() {
        let samples = [
            EngineUsageSample(at: today.addingTimeInterval(-86_400), engine: .gemini, audioSeconds: 10, outcome: .success),
            EngineUsageSample(at: today.addingTimeInterval(-1), engine: .apple, audioSeconds: 20, outcome: .failure),
            EngineUsageSample(at: today, engine: .gemini, audioSeconds: 30, outcome: .cancelled),
            EngineUsageSample(at: today.addingTimeInterval(-3 * 86_400), engine: .apple, audioSeconds: 99, outcome: .success),
            EngineUsageSample(at: today.addingTimeInterval(86_400), engine: .apple, audioSeconds: 99, outcome: .success)
        ]
        let rows = UsageSummary.dailyTotals(events: samples, days: 3, now: now, calendar: calendar)
        check(rows.map(\.takes) == [0, 2, 1])
        check(rows.map(\.totalSeconds) == [0, 30, 30])
        check(UsageSummary.todayTotals(events: samples, now: now, calendar: calendar) == rows[2])
    }

    func excludesAudioRechecks() {
        let samples = [
            EngineUsageSample(at: now, engine: .gemini, audioSeconds: 90, outcome: .success, purpose: .audioRecheck),
            EngineUsageSample(at: now, engine: .apple, audioSeconds: 30, outcome: .failure, purpose: .audioRecheck)
        ]
        let row = UsageSummary.todayTotals(events: samples, now: now, calendar: calendar)
        check(row.takes == 0)
        check(row.geminiSeconds == 0)
        check(row.appleSeconds == 0)
    }

    func splitsEnginesAndCountsEveryOutcome() {
        let samples = [
            EngineUsageSample(at: now, engine: .gemini, audioSeconds: 60, outcome: .success),
            EngineUsageSample(at: now, engine: .gemini, audioSeconds: 12, outcome: .failure),
            EngineUsageSample(at: now, engine: .apple, audioSeconds: 18, outcome: .cancelled, fallback: true)
        ]
        let row = UsageSummary.todayTotals(events: samples, now: now, calendar: calendar)
        check(row.takes == 3)
        check(row.geminiSeconds == 72)
        check(row.appleSeconds == 18)
        check(row.totalSeconds == 90)
    }

    func estimatesBlendedCost() {
        check(abs(UsageSummary.estimatedCostUSD(geminiSeconds: 60) - 0.009) < 1e-12)
        check(abs(UsageSummary.estimatedCostUSD(geminiSeconds: 3600) - 0.54) < 1e-12)
    }
}
