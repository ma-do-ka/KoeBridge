#if os(macOS)
import Foundation
import Testing
import KoeBridgeCore
@testable import KoeBridge

@MainActor struct UsageMonitorAggregationTests {
    @Test func recentTotalsRoutesAmiVoiceIntoAmiVoiceBucketNeverApple() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [
            EngineUsageSample(at: now.addingTimeInterval(-60), engine: .amivoice,
                              audioSeconds: 20, outcome: .success,
                              speechSeconds: 14.5, engineVariant: AmiVoiceEngine.e2eJapaneseGeneral.rawValue),
            EngineUsageSample(at: now.addingTimeInterval(-30), engine: .amivoice,
                              audioSeconds: 10, outcome: .failure,
                              speechSeconds: 0, engineVariant: AmiVoiceEngine.e2eJapaneseGeneral.rawValue),
            EngineUsageSample(at: now.addingTimeInterval(-20), engine: .gemini,
                              audioSeconds: 12, outcome: .success),
            EngineUsageSample(at: now.addingTimeInterval(-10), engine: .apple,
                              audioSeconds: 8, outcome: .success, fallback: true),
            // Excluded: older than 24 hours
            EngineUsageSample(at: now.addingTimeInterval(-86_401), engine: .amivoice,
                              audioSeconds: 100, outcome: .success, speechSeconds: 90)
        ]

        let totals = UsageMonitorView.RecentTotals.aggregate(events: events, at: now)
        #expect(totals.amivoice == 2)
        #expect(totals.apple == 1)
        #expect(totals.gemini == 1)
        #expect(totals.fallback == 1)
        #expect(totals.failed == 1)
        #expect(totals.amiVoiceSeconds == 30)
        #expect(totals.amiVoiceSpeechSeconds == 14.5)
    }

    @Test func chartTotalsRoutesAmiVoiceToAmiVoiceSeriesAndOutcomes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let bucketStart = try #require(calendar.dateInterval(of: .hour, for: start)?.start)

        let events = [
            EngineUsageSample(at: bucketStart.addingTimeInterval(60), engine: .amivoice,
                              audioSeconds: 24, outcome: .success, speechSeconds: 18,
                              engineVariant: AmiVoiceEngine.e2eJapaneseGeneral.rawValue),
            EngineUsageSample(at: bucketStart.addingTimeInterval(120), engine: .amivoice,
                              audioSeconds: 6, outcome: .failure, speechSeconds: 0,
                              engineVariant: AmiVoiceEngine.e2eJapaneseGeneral.rawValue),
            EngineUsageSample(at: bucketStart.addingTimeInterval(180), engine: .gemini,
                              audioSeconds: 15, outcome: .success)
        ]

        let chart = UsageMonitorView.ChartTotals.aggregate(
            events: events, tokens: [], scale: .hour, calendar: calendar, start: bucketStart
        )

        let amiVoiceBars = chart.engines.filter { $0.engine == .amivoice }
        let appleBars = chart.engines.filter { $0.engine == .apple }
        let geminiBars = chart.engines.filter { $0.engine == .gemini }

        #expect(amiVoiceBars.count == 1)
        #expect(amiVoiceBars[0].count == 2)
        #expect(amiVoiceBars[0].seconds == 30)
        #expect(appleBars.isEmpty)
        #expect(geminiBars.count == 1)
        #expect(geminiBars[0].count == 1)
        #expect(chart.outcomes[.amivoice]?[.success] == 1)
        #expect(chart.outcomes[.amivoice]?[.failure] == 1)
        #expect(chart.outcomes[.apple] == nil)
        #expect(chart.outcomes[.gemini]?[.success] == 1)
    }
}
#endif
