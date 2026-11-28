import Foundation
import KoeBridgeCore

struct LocalDiagnosticsSelfTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("koebridge-local-diagnostics-\(UUID().uuidString).json")
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func fixedNow(_ day: String, calendar: Calendar) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    func fieldReadBucketsAndTimeouts() {
        let samples: [(Int, String)] = [
            (0, "0-5ms"), (5, "0-5ms"), (6, "6-10ms"), (10, "6-10ms"),
            (11, "11-20ms"), (20, "11-20ms"), (21, "21-40ms"), (40, "21-40ms"),
            (41, "41-80ms"), (80, "41-80ms"), (81, "81-160ms"), (160, "81-160ms"),
            (161, "161ms+"), (4_000, "161ms+")
        ]
        var summary = LocalDiagnosticDailySummary()
        for (milliseconds, expected) in samples {
            check(LocalDiagnosticDailySummary.fieldReadBucket(milliseconds: milliseconds) == expected)
            summary.apply(.fieldRead(milliseconds: milliseconds, timedOut: false))
        }
        check(summary.fieldReadMilliseconds.values.reduce(0, +) == samples.count)
        // Negative durations are dropped; a timed-out read still lands in its bucket.
        summary.apply(.fieldRead(milliseconds: -1, timedOut: false))
        check(summary.fieldReadMilliseconds.values.reduce(0, +) == samples.count)
        summary.apply(.fieldRead(milliseconds: 1, timedOut: true))
        check(summary.fieldReadMilliseconds["0-5ms"] == 3)
        check(summary.fieldReadTimeouts == 1)
    }

    func countersAndCodeAllowlist() {
        var summary = LocalDiagnosticDailySummary()
        summary.apply(.failure(code: "recognition_failed"))
        summary.apply(.failure(code: "recognition_failed"))
        summary.apply(.failure(code: "not a code"))
        summary.apply(.failure(code: "文章のような自由文"))
        summary.apply(.failure(code: ""))
        summary.apply(.failClosed(code: "secure_text_field"))
        summary.apply(.micReplacementAttempt)
        summary.apply(.micVerificationDeferral)
        summary.apply(.micRecoverySuccess)
        summary.apply(.micUnrecovered)
        summary.apply(.fieldNature(.protected))
        summary.apply(.fieldNature(.normal))
        summary.apply(.fieldNature(.unknown))
        summary.apply(.volumeGuardActivation)
        check(summary.failures == ["recognition_failed": 2])
        check(summary.failClosed == ["secure_text_field": 1])
        check(summary.micReplacementAttempts == 1 && summary.micVerificationDeferrals == 1)
        check(summary.micRecoverySuccesses == 1 && summary.micUnrecovered == 1)
        check(summary.fieldNatureProtected == 1 && summary.fieldNatureNormal == 1 && summary.fieldNatureUnknown == 1)
        check(summary.volumeGuardActivations == 1)
        check(LocalDiagnosticDailySummary.isAllowedCode("first_chunk_focused_field_changed"))
        check(!LocalDiagnosticDailySummary.isAllowedCode("with space"))
        check(!LocalDiagnosticDailySummary.isAllowedCode(String(repeating: "a", count: 65)))
    }

    func dailyRollupMergesStoredAndNewCounts() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let calendar = Self.utcCalendar
        let now = fixedNow("2026-11-28", calendar: calendar)
        var seeded = LocalDiagnosticDailySummary()
        seeded.apply(.failure(code: "recognition_failed"))
        seeded.apply(.micReplacementAttempt)
        try JSONEncoder().encode(LocalDiagnosticArchive(build: 41, days: ["2026-11-28": seeded]))
            .write(to: url)

        let counter = LocalDiagnosticCounter(fileURL: url, build: { 42 }, now: { now }, calendar: calendar)
        counter.record(.failure(code: "recognition_failed"))
        counter.record(.failure(code: "recognition_failed"))
        counter.record(.fieldRead(milliseconds: 3, timedOut: false))
        counter.flushBlocking()

        let archive = try JSONDecoder().decode(LocalDiagnosticArchive.self, from: Data(contentsOf: url))
        check(archive.build == 42 && archive.schema == LocalDiagnosticArchive.currentSchema)
        let day = try require(archive.days["2026-11-28"])
        check(day.failures == ["recognition_failed": 3])
        check(day.micReplacementAttempts == 1)
        check(day.fieldReadMilliseconds == ["0-5ms": 1])
        check(archive.days.count == 1)
    }

    func rollingRetentionPrunesOldFutureAndOverCapDays() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let calendar = Self.utcCalendar
        let now = fixedNow("2026-11-28", calendar: calendar)
        var days: [String: LocalDiagnosticDailySummary] = [:]
        // 31 consecutive in-window days (2026-10-29 ... 2026-11-28).
        for stamp in (29...31).map({ String(format: "2026-10-%02d", $0) })
            + (1...28).map({ String(format: "2026-11-%02d", $0) }) {
            var summary = LocalDiagnosticDailySummary()
            summary.apply(.volumeGuardActivation)
            days[stamp] = summary
        }
        days["2026-10-28"] = LocalDiagnosticDailySummary()   // older than the 30-day window
        days["2026-12-05"] = LocalDiagnosticDailySummary()   // future day stamp
        days["not-a-day"] = LocalDiagnosticDailySummary()    // malformed key
        try JSONEncoder().encode(LocalDiagnosticArchive(build: 1, days: days)).write(to: url)

        let counter = LocalDiagnosticCounter(fileURL: url, build: { 1 }, now: { now }, calendar: calendar)
        counter.flushBlocking()

        let archive = try JSONDecoder().decode(LocalDiagnosticArchive.self, from: Data(contentsOf: url))
        check(archive.days["2026-10-28"] == nil)
        check(archive.days["2026-12-05"] == nil)
        check(archive.days["not-a-day"] == nil)
        check(archive.days.count == LocalDiagnosticCounter.retentionDays)
        check(archive.days["2026-10-29"] == nil)  // oldest in-window day loses the cap
        check(archive.days["2026-11-28"] != nil)
    }

    func disabledCounterNeverWrites() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let off = LocalDiagnosticCounter(fileURL: url, enabled: false)
        off.record(.volumeGuardActivation)
        off.record(.failure(code: "recognition_failed"))
        off.flushBlocking()
        check(!FileManager.default.fileExists(atPath: url.path))
        check(off.snapshot().days.isEmpty)

        // Turning OFF mid-run cancels the queued write and clears memory.
        let on = LocalDiagnosticCounter(fileURL: url, enabled: true)
        on.record(.volumeGuardActivation)
        on.setEnabled(false)
        on.flushBlocking()
        check(!FileManager.default.fileExists(atPath: url.path))
        check(on.snapshot().days.isEmpty)
    }

    func deleteAllRemovesFileAndCounters() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let counter = LocalDiagnosticCounter(fileURL: url)
        counter.record(.volumeGuardActivation)
        counter.flushBlocking()
        check(FileManager.default.fileExists(atPath: url.path))
        try counter.deleteAll()
        check(!FileManager.default.fileExists(atPath: url.path))
        check(counter.snapshot().days.isEmpty)
    }

    func failingWriterDoesNotPropagateOrLoseCounters() {
        struct WriteError: Error {}
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let counter = LocalDiagnosticCounter(fileURL: url, enabled: true,
                                             write: { _, _ in throw WriteError() })
        counter.record(.volumeGuardActivation)
        counter.flushBlocking()  // A failing writer must not propagate.
        check(counter.snapshot().days.values.contains { $0.volumeGuardActivations == 1 })
    }

    func serializedAggregateContainsOnlyNumbersAndCodes() throws {
        var summary = LocalDiagnosticDailySummary()
        summary.apply(.fieldRead(milliseconds: 25, timedOut: true))
        summary.apply(.failure(code: "recognition_failed"))
        summary.apply(.failure(code: "not a code 文章"))
        summary.apply(.failClosed(code: "focus_verification_failed"))
        summary.apply(.fieldNature(.unknown))
        check(summary.failures == ["recognition_failed": 1])
        let archive = LocalDiagnosticArchive(build: 42, days: ["2026-11-28": summary])
        let root = try require(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(archive)) as? [String: Any])
        check(Set(root.keys) == ["schema", "build", "days"])
        check(root["schema"] is NSNumber && root["build"] is NSNumber)
        let days = try require(root["days"] as? [String: Any])
        let scalarKeys: Set<String> = [
            "fieldReadTimeouts", "micReplacementAttempts", "micVerificationDeferrals",
            "micRecoverySuccesses", "micUnrecovered", "fieldNatureNormal",
            "fieldNatureProtected", "fieldNatureUnknown", "volumeGuardActivations"
        ]
        for (dayKey, dayValue) in days {
            check(dayKey.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
            let dayObject = try require(dayValue as? [String: Any])
            for (key, value) in dayObject {
                switch key {
                case "fieldReadMilliseconds", "failures", "failClosed":
                    let counts = try require(value as? [String: Any])
                    for (code, count) in counts {
                        check(LocalDiagnosticDailySummary.isAllowedCode(code))
                        check(count is NSNumber)
                    }
                default:
                    check(scalarKeys.contains(key))
                    check(value is NSNumber)
                }
            }
        }
    }
}
