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
        check(rows.allSatisfy { $0.takes == 0 && $0.totalSeconds == 0 && $0.amiVoiceSeconds == 0 && $0.amiVoiceSpeechSeconds == 0 })
        check(rows.first?.dayStart == calendar.date(byAdding: .day, value: -6, to: today))
        check(UsageSummary.dailyTotals(events: [], days: 0, now: now, calendar: calendar).isEmpty)
        check(UsageSummary.dailyTotals(events: [], days: -1, now: now, calendar: calendar).isEmpty)
    }

    func bucketsAtCalendarDayBoundaries() {
        let samples = [
            EngineUsageSample(at: today.addingTimeInterval(-86_400), engine: .gemini, audioSeconds: 10, outcome: .success),
            EngineUsageSample(at: today.addingTimeInterval(-1), engine: .apple, audioSeconds: 20, outcome: .failure),
            EngineUsageSample(at: today, engine: .gemini, audioSeconds: 30, outcome: .cancelled),
            EngineUsageSample(at: today, engine: .amivoice, audioSeconds: 15, outcome: .success,
                              speechSeconds: 12, engineVariant: AmiVoiceEngine.e2eJapaneseGeneral.rawValue),
            EngineUsageSample(at: today.addingTimeInterval(-3 * 86_400), engine: .apple, audioSeconds: 99, outcome: .success),
            EngineUsageSample(at: today.addingTimeInterval(86_400), engine: .apple, audioSeconds: 99, outcome: .success)
        ]
        let rows = UsageSummary.dailyTotals(events: samples, days: 3, now: now, calendar: calendar)
        check(rows.map(\.takes) == [0, 2, 2])
        check(rows.map(\.totalSeconds) == [0, 30, 45])
        check(rows[2].amiVoiceSeconds == 15)
        check(rows[2].amiVoiceSpeechSeconds == 12)
        check(UsageSummary.todayTotals(events: samples, now: now, calendar: calendar) == rows[2])
        check(InputDiagnosticEvent.Token.amivoice.rawValue == "amivoice")
        check(InputDiagnosticEvent.Value.reason("amivoice") == .token(.amivoice))
    }

    func excludesAudioRechecks() {
        let samples = [
            EngineUsageSample(at: now, engine: .gemini, audioSeconds: 90, outcome: .success, purpose: .audioRecheck),
            EngineUsageSample(at: now, engine: .apple, audioSeconds: 30, outcome: .failure, purpose: .audioRecheck),
            EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 45, outcome: .success, purpose: .audioRecheck,
                              speechSeconds: 40, engineVariant: AmiVoiceEngine.e2eJapaneseGeneral.rawValue)
        ]
        let row = UsageSummary.todayTotals(events: samples, now: now, calendar: calendar)
        check(row.takes == 0)
        check(row.geminiSeconds == 0)
        check(row.appleSeconds == 0)
        check(row.amiVoiceSeconds == 0)
        check(row.amiVoiceSpeechSeconds == 0)
        check(UsageSummary.amiVoiceMonthlyUsage(events: samples, now: now, calendar: calendar).isEmpty)
    }

    func splitsEnginesAndCountsEveryOutcome() {
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
        check(row.takes == 6)
        check(row.geminiSeconds == 72)
        check(row.appleSeconds == 18)
        check(row.amiVoiceSeconds == 55)
        check(row.amiVoiceSpeechSeconds == 35)
        check(row.totalSeconds == 145)
        check(UsageEngine.amivoice.rawValue == "amivoice")
        check(UsageEngine.amivoice.label == "AmiVoice API")
        // Verify legacy JSON record lacking purpose, speechSeconds, and engineVariant decodes cleanly.
        let legacyJSON = Data("""
        {"id":"00000000-0000-4000-8000-000000000001","at":789000000,"engine":"gemini","audioSeconds":12.5,"outcome":"success","fallback":false}
        """.utf8)
        let decodedLegacy = try? JSONDecoder().decode(EngineUsageSample.self, from: legacyJSON)
        check(decodedLegacy?.engine == .gemini)
        check(decodedLegacy?.audioSeconds == 12.5)
        check(decodedLegacy?.speechSeconds == nil)
        check(decodedLegacy?.engineVariant == nil)
    }

    func estimatesBlendedCost() {
        check(abs(UsageSummary.estimatedCostUSD(geminiSeconds: 60) - 0.009) < 1e-12)
        check(abs(UsageSummary.estimatedCostUSD(geminiSeconds: 3600) - 0.54) < 1e-12)
        check(UsageSummary.estimatedAmiVoiceCostJPY(speechSeconds: 3_600) == 0)
        check(UsageSummary.estimatedAmiVoiceCostJPY(speechSeconds: 3_600.999) == 0)
        check(abs(UsageSummary.estimatedAmiVoiceCostJPY(speechSeconds: 3_601) - 0.04125) < 1e-12)
        check(UsageSummary.estimatedAmiVoiceCostJPY(speechSeconds: .nan) == 0)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let prevMonth = utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 14, minute: 59, second: 59))!
        let novStart = utc.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 15, minute: 0, second: 0))!
        let novMid = utc.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12, minute: 0, second: 0))!
        let e2e = AmiVoiceEngine.e2eJapaneseGeneral.rawValue
        let batch = AmiVoiceEngine.e2eJapaneseGeneralBatch.rawValue
        let monthlySamples = [
            EngineUsageSample(at: prevMonth, engine: .amivoice, audioSeconds: 4_000, outcome: .success,
                              speechSeconds: 4_000, engineVariant: e2e),
            EngineUsageSample(at: novStart, engine: .amivoice, audioSeconds: 4_200, outcome: .success,
                              speechSeconds: 3_900, engineVariant: e2e),
            EngineUsageSample(at: novMid, engine: .amivoice, audioSeconds: 3_000, outcome: .success,
                              speechSeconds: 2_400, engineVariant: batch),
            EngineUsageSample(at: novMid, engine: .amivoice, audioSeconds: 90, outcome: .failure)
        ]
        let buckets = UsageSummary.amiVoiceMonthlyUsage(events: monthlySamples, now: novMid)
        check(buckets.count == 3)
        check(buckets[0].engineVariant == e2e && buckets[0].billableSeconds == 300)
        check(abs(buckets[0].estimatedCostJPY - 12.375) < 1e-9)
        check(buckets[1].engineVariant == batch && buckets[1].billableSeconds == 0 && buckets[1].freeRemainingSeconds == 1_200)
        check(buckets[2].engineVariant == nil && buckets[2].speechSeconds == 90 && buckets[2].fallbackToAudioCount == 1)
    }
}
