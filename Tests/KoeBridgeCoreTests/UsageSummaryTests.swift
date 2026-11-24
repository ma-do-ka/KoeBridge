import Foundation
import Testing
@testable import KoeBridgeCore

struct UsageSummaryTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        return value
    }
    private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }
    private var today: Date { calendar.startOfDay(for: now) }

    @Test func zeroFillsThroughToday() {
        let rows = UsageSummary.dailyTotals(events: [], days: 7, now: now, calendar: calendar)
        #expect(rows.count == 7)
        #expect(rows.last?.dayStart == today)
        #expect(rows.allSatisfy { $0.takes == 0 && $0.totalSeconds == 0 })
        #expect(rows.first?.dayStart == calendar.date(byAdding: .day, value: -6, to: today))
        #expect(UsageSummary.dailyTotals(events: [], days: 0, now: now, calendar: calendar).isEmpty)
        #expect(UsageSummary.dailyTotals(events: [], days: -1, now: now, calendar: calendar).isEmpty)
    }

    @Test func bucketsAtCalendarDayBoundaries() {
        let samples = [
            EngineUsageSample(at: today.addingTimeInterval(-86_400), engine: .gemini, audioSeconds: 10, outcome: .success),
            EngineUsageSample(at: today.addingTimeInterval(-1), engine: .apple, audioSeconds: 20, outcome: .failure),
            EngineUsageSample(at: today, engine: .gemini, audioSeconds: 30, outcome: .cancelled),
            EngineUsageSample(at: today.addingTimeInterval(-3 * 86_400), engine: .apple, audioSeconds: 99, outcome: .success),
            EngineUsageSample(at: today.addingTimeInterval(86_400), engine: .apple, audioSeconds: 99, outcome: .success)
        ]
        let rows = UsageSummary.dailyTotals(events: samples, days: 3, now: now, calendar: calendar)
        #expect(rows.map(\.takes) == [0, 2, 1])
        #expect(rows.map(\.totalSeconds) == [0, 30, 30])
        #expect(UsageSummary.todayTotals(events: samples, now: now, calendar: calendar) == rows[2])
    }

    @Test func excludesAudioRechecks() {
        let samples = [
            EngineUsageSample(at: now, engine: .gemini, audioSeconds: 90, outcome: .success, purpose: .audioRecheck),
            EngineUsageSample(at: now, engine: .apple, audioSeconds: 30, outcome: .failure, purpose: .audioRecheck),
            EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 45, outcome: .success, purpose: .audioRecheck,
                              speechSeconds: 40, engineVariant: AmiVoiceEngine.e2eJapaneseGeneral.rawValue)
        ]
        let row = UsageSummary.todayTotals(events: samples, now: now, calendar: calendar)
        #expect(row.takes == 0)
        #expect(row.geminiSeconds == 0)
        #expect(row.appleSeconds == 0)
        #expect(row.amiVoiceSeconds == 0)
        #expect(row.amiVoiceSpeechSeconds == 0)
        #expect(UsageSummary.amiVoiceMonthlyUsage(events: samples, now: now, calendar: calendar).isEmpty)
    }

    @Test func splitsEnginesAndCountsEveryOutcome() {
        let samples = [
            EngineUsageSample(at: now, engine: .gemini, audioSeconds: 60, outcome: .success),
            EngineUsageSample(at: now, engine: .gemini, audioSeconds: 12, outcome: .failure),
            EngineUsageSample(at: now, engine: .apple, audioSeconds: 18, outcome: .cancelled, fallback: true),
            EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 30, outcome: .success,
                              speechSeconds: 20, engineVariant: AmiVoiceEngine.e2eJapaneseGeneral.rawValue),
            EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 10, outcome: .failure,
                              speechSeconds: 0, engineVariant: AmiVoiceEngine.e2eJapaneseGeneral.rawValue),
            EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 15, outcome: .cancelled)
        ]
        let row = UsageSummary.todayTotals(events: samples, now: now, calendar: calendar)
        #expect(row.takes == 6)
        #expect(row.geminiSeconds == 72)
        #expect(row.appleSeconds == 18)
        #expect(row.amiVoiceSeconds == 55)
        // 20 (measured) + 0 (measured silence) + 15 (nil fallback to audioSeconds)
        #expect(row.amiVoiceSpeechSeconds == 35)
        #expect(row.totalSeconds == 145)
    }

    @Test func estimatesBlendedCost() {
        #expect(abs(UsageSummary.estimatedCostUSD(geminiSeconds: 60) - 0.009) < 1e-12)
        #expect(abs(UsageSummary.estimatedCostUSD(geminiSeconds: 3600) - 0.54) < 1e-12)
    }

    @Test func amiVoiceMonthlyUsageIsolatesEnginesAndJSTMonthBoundaries() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        // 2026-10-31 14:59:59 UTC == 2026-10-31 23:59:59 JST (previous JST month)
        let prevMonthEnd = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 14, minute: 59, second: 59)))
        // 2026-10-31 15:00:00 UTC == 2026-11-01 00:00:00 JST (start of Nov JST)
        let novStart = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 15, minute: 0, second: 0)))
        let novMid = try #require(utc.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12, minute: 0, second: 0)))
        // 2026-11-30 15:00:00 UTC == 2026-12-01 00:00:00 JST (next JST month)
        let decStart = try #require(utc.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 15, minute: 0, second: 0)))

        let e2e = AmiVoiceEngine.e2eJapaneseGeneral.rawValue
        let batch = AmiVoiceEngine.e2eJapaneseGeneralBatch.rawValue
        let samples = [
            // Excluded: previous JST month
            EngineUsageSample(at: prevMonthEnd, engine: .amivoice, audioSeconds: 5000, outcome: .success,
                              speechSeconds: 4000, engineVariant: e2e),
            // Included in Nov JST for -a2-ja-general: 2000 + 2200 = 4200 speech s -> 600 billable s
            EngineUsageSample(at: novStart, engine: .amivoice, audioSeconds: 2500, outcome: .success,
                              speechSeconds: 2000, engineVariant: e2e),
            EngineUsageSample(at: novMid, engine: .amivoice, audioSeconds: 2400, outcome: .success,
                              speechSeconds: 2200, engineVariant: e2e),
            // Separate free bucket for -a2b-ja-general: 3000 speech s -> 0 billable s
            EngineUsageSample(at: novMid, engine: .amivoice, audioSeconds: 3200, outcome: .success,
                              speechSeconds: 3000, engineVariant: batch),
            // Silence-only take (speechSeconds == 0.0) does not fall back to audioSeconds
            EngineUsageSample(at: novMid, engine: .amivoice, audioSeconds: 120, outcome: .success,
                              speechSeconds: 0, engineVariant: batch),
            // Untagged AmiVoice take without speechSeconds falls back to audioSeconds
            EngineUsageSample(at: novMid, engine: .amivoice, audioSeconds: 180, outcome: .failure),
            // Excluded: non-AmiVoice and next JST month
            EngineUsageSample(at: novMid, engine: .gemini, audioSeconds: 5000, outcome: .success),
            EngineUsageSample(at: decStart, engine: .amivoice, audioSeconds: 5000, outcome: .success,
                              speechSeconds: 4000, engineVariant: e2e)
        ]

        let buckets = UsageSummary.amiVoiceMonthlyUsage(events: samples, now: novMid)
        #expect(buckets.count == 3)

        #expect(buckets[0].engineVariant == e2e)
        #expect(buckets[0].takes == 2)
        #expect(buckets[0].audioSeconds == 4_900)
        #expect(buckets[0].speechSeconds == 4_200)
        #expect(buckets[0].fallbackToAudioCount == 0)
        #expect(buckets[0].billableSeconds == 600)
        #expect(buckets[0].freeRemainingSeconds == 0)
        #expect(buckets[0].freeUsageFraction == 1)
        #expect(abs(buckets[0].estimatedCostJPY - 24.75) < 1e-9)

        #expect(buckets[1].engineVariant == batch)
        #expect(buckets[1].takes == 2)
        #expect(buckets[1].audioSeconds == 3_320)
        #expect(buckets[1].speechSeconds == 3_000)
        #expect(buckets[1].fallbackToAudioCount == 0)
        #expect(buckets[1].billableSeconds == 0)
        #expect(buckets[1].freeRemainingSeconds == 600)
        #expect(abs(buckets[1].freeUsageFraction - (3_000.0 / 3_600.0)) < 1e-12)
        #expect(buckets[1].estimatedCostJPY == 0)

        #expect(buckets[2].engineVariant == nil)
        #expect(buckets[2].takes == 1)
        #expect(buckets[2].audioSeconds == 180)
        #expect(buckets[2].speechSeconds == 180)
        #expect(buckets[2].fallbackToAudioCount == 1)
        #expect(buckets[2].billableSeconds == 0)
        #expect(buckets[2].estimatedCostJPY == 0)
    }

    @Test func estimatesAmiVoiceCostWithFloorAndFloatDriftSafety() {
        #expect(UsageSummary.estimatedAmiVoiceCostJPY(speechSeconds: 0) == 0)
        #expect(UsageSummary.estimatedAmiVoiceCostJPY(speechSeconds: 3_600) == 0)
        // Fractional second below 3601 floors to 3600 -> still within free tier
        #expect(UsageSummary.estimatedAmiVoiceCostJPY(speechSeconds: 3_600.999) == 0)
        #expect(abs(UsageSummary.estimatedAmiVoiceCostJPY(speechSeconds: 3_601.0) - 0.04125) < 1e-12)
        // Binary float sum of 10 * 360.1 (can drift slightly below 3601.0) must still bill 1 second
        let drifted = (0..<10).reduce(0.0) { acc, _ in acc + 360.1 }
        #expect(abs(UsageSummary.estimatedAmiVoiceCostJPY(speechSeconds: drifted) - 0.04125) < 1e-12)
        // Non-finite or negative values never trap
        #expect(UsageSummary.estimatedAmiVoiceCostJPY(speechSeconds: -50) == 0)
        #expect(UsageSummary.estimatedAmiVoiceCostJPY(speechSeconds: .nan) == 0)
        #expect(UsageSummary.estimatedAmiVoiceCostJPY(speechSeconds: .infinity) == 0)
    }
}
