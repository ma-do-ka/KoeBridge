import Foundation
import Testing
@testable import KoeBridgeCore

private final class MonitoringTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        current += interval
        lock.unlock()
    }
}

private final class MonitoringAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}

private struct MonitoringFixture {
    let suiteName: String
    let defaults: UserDefaults
    let store: AmiVoiceDictionarySyncStore
    let transport: MockAmiVoiceDictionaryTransport
    let clock: MonitoringTestClock
    let engine: AmiVoiceDictionarySyncEngine
    let monitor: AmiVoiceDictionarySyncMonitor
    let key: AmiVoiceDictionaryProfileKey

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private func makeMonitoringFixture(
    engine: AmiVoiceEngine = .e2eJapaneseGeneral,
    start: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> MonitoringFixture {
    let suite = "KoeBridge.AmiVoiceSyncMonitoring." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    let store = AmiVoiceDictionarySyncStore(defaults: defaults)
    let transport = MockAmiVoiceDictionaryTransport()
    let clock = MonitoringTestClock(start)
    let syncEngine = AmiVoiceDictionarySyncEngine(
        store: store,
        transport: transport,
        apiKeyProvider: { "fixture-key" },
        now: { clock.now }
    )
    let monitor = AmiVoiceDictionarySyncMonitor(
        store: store,
        engine: syncEngine,
        now: { clock.now }
    )
    return MonitoringFixture(
        suiteName: suite,
        defaults: defaults,
        store: store,
        transport: transport,
        clock: clock,
        engine: syncEngine,
        monitor: monitor,
        key: AmiVoiceDictionaryProfileKey(engine: engine, samplingRate: .rate16k)
    )
}

struct AmiVoiceDictionarySyncMonitoringTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Upserts one entry, enables sync, and syncs it so it lands in
    /// `autoSynced` with `lastSyncedAt` = the clock's current time.
    private func syncedEntry(
        _ fixture: MonitoringFixture,
        id: UUID = UUID(),
        written: String,
        createdAt: Date
    ) async throws -> UUID {
        #expect(await fixture.engine.upsertEntry(
            AmiVoiceDictionaryEntry(id: id, written: written, createdAt: createdAt),
            for: fixture.key,
            state: .readyToSync
        ))
        await fixture.engine.setAutomaticSyncEnabled(true)
        let outcome = await fixture.engine.syncNow(for: fixture.key)
        #expect(outcome.kind == .success)
        return id
    }

    @Test func reCorrectionBelowThresholdKeepsEntrySynced() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        let syncedAt = fixture.clock.now
        let source = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: t0.addingTimeInterval(-60))
        let c1 = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: syncedAt.addingTimeInterval(3_600))
        let c2 = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: syncedAt.addingTimeInterval(7_200))

        var report = await fixture.monitor.observe(learnedTerms: [source, c1], for: fixture.key)
        #expect(report.transitions.isEmpty)
        report = await fixture.monitor.observe(learnedTerms: [source, c1, c2], for: fixture.key)
        #expect(report.transitions.isEmpty)

        let rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == entryID }?.engineState(for: fixture.key)?.state == .autoSynced)
        let record = await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)
        #expect(record?.reCorrectionTimestamps.count == 2)
    }

    @Test func reCorrectionThirdOccurrenceWithinWindowMovesEntryToReview() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        let syncedAt = fixture.clock.now
        let source = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: t0.addingTimeInterval(-60))
        let corrections = (1...3).map {
            LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: syncedAt.addingTimeInterval(TimeInterval($0) * 3_600))
        }

        let report = await fixture.monitor.observe(learnedTerms: [source] + corrections, for: fixture.key)
        #expect(report.transitions.count == 1)
        #expect(report.transitions.first?.kind == .reCorrection)
        #expect(report.transitions.first?.toState == .pendingReview)
        #expect(report.transitions.first?.occurrenceCount == 3)
        #expect(report.transitions.first?.windowDays == Int(AmiVoiceDictionaryMonitoringPolicy.reCorrectionWindow / 86_400))

        // U-01: review state leaves the syncable set.
        let rows = await fixture.engine.entries()
        let engineState = rows.first { $0.id == entryID }?.engineState(for: fixture.key)
        #expect(engineState?.state == .pendingReview)
        #expect(engineState?.state.participatesInSnapshot == false)
        #expect(engineState?.lastErrorDetail?.contains("re-correction") == true)
        let status = await fixture.engine.status(for: fixture.key)
        #expect(status.pendingReviewCount == 1)

        let record = await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)
        #expect(record?.lastAutoTransition?.occurrenceTimestamps.count == 3)
    }

    @Test func correctionsBeforeEntrySyncNeverCount() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        let syncedAt = fixture.clock.now
        let source = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: t0.addingTimeInterval(-60))
        // Same pair as the source correction, but created before the sync.
        let preSync = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: syncedAt.addingTimeInterval(-10))

        let report = await fixture.monitor.observe(learnedTerms: [source, preSync], for: fixture.key)
        #expect(report.transitions.isEmpty)
        let record = await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)
        #expect(record?.reCorrectionTimestamps.isEmpty == true)
        #expect(record?.reverseCorrectionTimestamps.isEmpty == true)
    }

    @Test func occurrencesOutsideWindowDoNotAccumulate() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        let syncedAt = fixture.clock.now
        let source = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: t0.addingTimeInterval(-60))
        let c1 = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: syncedAt.addingTimeInterval(100))
        let c2 = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: syncedAt.addingTimeInterval(200))
        _ = await fixture.monitor.observe(learnedTerms: [source, c1, c2], for: fixture.key)
        #expect(await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)?.reCorrectionTimestamps.count == 2)

        // One day past the re-correction window the first two occurrences
        // fall outside it; the third alone cannot reach the threshold.
        fixture.clock.advance(by: AmiVoiceDictionaryMonitoringPolicy.reCorrectionWindow + 86_400)
        let c3 = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: fixture.clock.now)
        let report = await fixture.monitor.observe(learnedTerms: [source, c1, c2, c3], for: fixture.key)
        #expect(report.transitions.isEmpty)
        let record = await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)
        #expect(record?.reCorrectionTimestamps.count == 1)
        let rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == entryID }?.engineState(for: fixture.key)?.state == .autoSynced)
    }

    @Test func reverseCorrectionSingleOccurrenceNeverQuarantines() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        let syncedAt = fixture.clock.now
        let r1 = LearnedTerm(term: "Different", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(100))

        let report = await fixture.monitor.observe(learnedTerms: [r1], for: fixture.key)
        #expect(report.transitions.isEmpty)
        let rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == entryID }?.engineState(for: fixture.key)?.state == .autoSynced)
        #expect(await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)?.reverseCorrectionTimestamps.count == 1)
    }

    @Test func reverseCorrectionTwoOccurrencesQuarantineAndFireImmediateSync() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        fixture.transport.resetCalls()
        let syncedAt = fixture.clock.now
        let r1 = LearnedTerm(term: "Different", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(100))
        let r2 = LearnedTerm(term: "OtherText", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(200))

        let report = await fixture.monitor.observe(learnedTerms: [r1, r2], for: fixture.key)
        #expect(report.transitions.count == 1)
        #expect(report.transitions.first?.kind == .reverseCorrection)
        #expect(report.transitions.first?.toState == .autoDisabled)
        #expect(report.transitions.first?.windowDays == Int(AmiVoiceDictionaryMonitoringPolicy.reverseCorrectionWindow / 86_400))

        let rows = await fixture.engine.entries()
        let engineState = rows.first { $0.id == entryID }?.engineState(for: fixture.key)
        #expect(engineState?.state == .autoDisabled)
        #expect(engineState?.lastErrorDetail?.contains("reverse-correction") == true)

        // U-02: the immediate re-sync already ran before observe returned and
        // pushed the quarantined entry out of the server set.
        let posts = fixture.transport.calls.filter { $0.method == "POST" }
        #expect(posts.count == 1)
        #expect(posts.last?.payloads.map(\.written).contains("KoeBridge") == false)
    }

    @Test func manualEditWithinTwentyFourHoursSuppressesQuarantine() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        let syncedAt = fixture.clock.now

        // B-4 reset hook after a manual edit arms the 24-hour guard.
        await fixture.monitor.resetCorrectionTracking(entryID: entryID, for: fixture.key)
        let r1 = LearnedTerm(term: "Different", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(100))
        let r2 = LearnedTerm(term: "OtherText", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(200))
        var report = await fixture.monitor.observe(learnedTerms: [r1, r2], for: fixture.key)
        #expect(report.transitions.isEmpty)
        var rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == entryID }?.engineState(for: fixture.key)?.state == .autoSynced)

        // Once the guard interval elapses, the same accumulated count fires.
        fixture.clock.advance(by: AmiVoiceDictionaryMonitoringPolicy.manualEditGuardInterval + 3_600)
        let r3 = LearnedTerm(term: "YetAnother", originalFragment: "KoeBridge", createdAt: fixture.clock.now)
        report = await fixture.monitor.observe(learnedTerms: [r1, r2, r3], for: fixture.key)
        #expect(report.transitions.first?.kind == .reverseCorrection)
        rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == entryID }?.engineState(for: fixture.key)?.state == .autoDisabled)
    }

    @Test func contentEditResetsBothCountersAndRearmsGuard() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        let syncedAt = fixture.clock.now
        let source = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: t0.addingTimeInterval(-60))
        let c1 = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: syncedAt.addingTimeInterval(100))
        let r1 = LearnedTerm(term: "Different", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(150))
        _ = await fixture.monitor.observe(learnedTerms: [source, c1, r1], for: fixture.key)
        var record = await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)
        #expect(record?.reCorrectionTimestamps.count == 1)
        #expect(record?.reverseCorrectionTimestamps.count == 1)

        // A content edit through upsertEntry advances updatedAt; the monitor
        // treats it as a manual edit and zeroes both counters.
        fixture.clock.advance(by: 60)
        #expect(await fixture.engine.upsertEntry(
            AmiVoiceDictionaryEntry(id: entryID, written: "KoeBridgePro", createdAt: t0, updatedAt: fixture.clock.now),
            for: fixture.key,
            state: .readyToSync
        ))
        _ = await fixture.monitor.observe(learnedTerms: [source, c1, r1], for: fixture.key)
        record = await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)
        #expect(record?.reCorrectionTimestamps.isEmpty == true)
        #expect(record?.reverseCorrectionTimestamps.isEmpty == true)
        #expect(record?.lastManualEditAt == fixture.clock.now)
    }

    @Test func reApprovalIntoSyncedSetResetsCounters() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        let syncedAt = fixture.clock.now
        let r1 = LearnedTerm(term: "Different", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(100))
        let r2 = LearnedTerm(term: "OtherText", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(200))
        _ = await fixture.monitor.observe(learnedTerms: [r1, r2], for: fixture.key)
        var rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == entryID }?.engineState(for: fixture.key)?.state == .autoDisabled)

        // User re-approves the quarantined entry; the next evaluation must see
        // zeroed counters and a re-armed manual-edit guard.
        #expect(await fixture.engine.transitionEntry(id: entryID, for: fixture.key, to: .readyToSync))
        _ = await fixture.monitor.observe(learnedTerms: [r1, r2], for: fixture.key)
        let record = await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)
        #expect(record?.reCorrectionTimestamps.isEmpty == true)
        #expect(record?.reverseCorrectionTimestamps.isEmpty == true)
        #expect(record?.lastManualEditAt != nil)
    }

    @Test func monitoringIsInertWhileSyncDisabled() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        await fixture.engine.setAutomaticSyncEnabled(false)
        fixture.transport.resetCalls()

        let syncedAt = fixture.clock.now
        let r1 = LearnedTerm(term: "Different", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(100))
        let r2 = LearnedTerm(term: "OtherText", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(200))
        let report = await fixture.monitor.observe(learnedTerms: [r1, r2], for: fixture.key)
        #expect(report.monitoringActive == false)
        #expect(report.transitions.isEmpty)
        let rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == entryID }?.engineState(for: fixture.key)?.state == .autoSynced)
        #expect(fixture.transport.calls.isEmpty)
        // Counting is skipped while off (stated choice): no counters accrue.
        let record = await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)
        #expect(record == nil || (record?.reverseCorrectionTimestamps.isEmpty == true))
    }

    @Test func corruptMonitoringStoreFailsSafeCountersResetEntriesUntouched() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        fixture.defaults.set(Data("not-json".utf8), forKey: AmiVoiceDictionarySyncStore.monitoringRecordsKey)
        fixture.defaults.set(Data("not-json".utf8), forKey: AmiVoiceDictionarySyncStore.observedCorrectionsKey)
        fixture.defaults.set(Data("not-json".utf8), forKey: AmiVoiceDictionarySyncStore.snapshotsKey)

        // A store constructed over corrupt values recovers them on load —
        // counters/history reset, entries untouched.
        let recoveredStore = AmiVoiceDictionarySyncStore(defaults: fixture.defaults)
        #expect(recoveredStore.loadMonitoringRecords().isEmpty)
        #expect(recoveredStore.loadObservedCorrections().isEmpty)
        #expect(recoveredStore.loadSnapshots().isEmpty)
        let rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == entryID }?.engineState(for: fixture.key)?.state == .autoSynced)
    }

    @Test func snapshotRecordedPerCompletedSyncWithSentSetAndTrigger() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        _ = try await syncedEntry(fixture, id: UUID(), written: "KoeBridge", createdAt: t0)

        var snapshots = await fixture.engine.syncSnapshots(for: fixture.key)
        #expect(snapshots.count == 1)
        #expect(snapshots[0].trigger == .manualImmediate)
        #expect(snapshots[0].status == .reflected)
        #expect(snapshots[0].entries.map(\.written) == ["KoeBridge"])
        #expect(snapshots[0].profileKey == fixture.key)
        #expect(snapshots[0].profileID != nil)
        #expect(snapshots[0].entries.first?.entryID != nil)
        #expect(snapshots[0].entries.first?.stateAtSend == .readyToSync)

        // Launch-restore trigger gets its own kind on the next send.
        fixture.clock.advance(by: 60)
        fixture.transport.fetchHandler = { [] }
        let launch = await fixture.engine.performLaunchConsistencyPass(for: fixture.key)
        #expect(launch.kind == .success)
        snapshots = await fixture.engine.syncSnapshots(for: fixture.key)
        #expect(snapshots.count == 2)
        #expect(snapshots.first?.trigger == .launchRestore)
        #expect(snapshots.first?.status == .reflected)
    }

    @Test func failedSyncRecordsFailedSnapshotAndLatestReflectedSkipsIt() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        #expect(await fixture.engine.upsertEntry(
            AmiVoiceDictionaryEntry(written: "KoeBridge", createdAt: t0),
            for: fixture.key,
            state: .readyToSync
        ))
        await fixture.engine.setAutomaticSyncEnabled(true)
        fixture.transport.replaceHandler = { _ in throw AmiVoiceDictionaryTransportError.temporary(.network) }
        let failed = await fixture.engine.syncNow(for: fixture.key)
        #expect(failed.kind == .temporaryFailure)

        var snapshots = await fixture.engine.syncSnapshots(for: fixture.key)
        #expect(snapshots.count == 1)
        #expect(snapshots[0].status == .failed)
        #expect(snapshots[0].entries.map(\.written) == ["KoeBridge"])
        #expect(await fixture.engine.latestReflectedSyncSnapshot(for: fixture.key) == nil)

        fixture.clock.advance(by: 60)
        fixture.transport.replaceHandler = nil
        let retried = await fixture.engine.syncNow(for: fixture.key)
        #expect(retried.kind == .success)
        snapshots = await fixture.engine.syncSnapshots(for: fixture.key)
        #expect(snapshots.count == 2)
        let latestReflected = await fixture.engine.latestReflectedSyncSnapshot(for: fixture.key)
        #expect(latestReflected?.status == .reflected)
        #expect(latestReflected?.id == snapshots.first?.id)
    }

    @Test func snapshotRetentionKeepsThirtyNewestPerProfile() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        _ = try await syncedEntry(fixture, id: UUID(), written: "KoeBridge", createdAt: t0)
        let firstSnapshotID = try #require(await fixture.engine.syncSnapshots(for: fixture.key).first?.id)

        for _ in 0..<(AmiVoiceDictionaryMonitoringPolicy.snapshotRetentionLimit + 4) {
            fixture.clock.advance(by: 1)
            let outcome = await fixture.engine.syncNow(for: fixture.key)
            #expect(outcome.kind == .success)
        }
        let snapshots = await fixture.engine.syncSnapshots(for: fixture.key)
        #expect(snapshots.count == AmiVoiceDictionaryMonitoringPolicy.snapshotRetentionLimit)
        #expect(!snapshots.map(\.id).contains(firstSnapshotID))
        #expect(snapshots.first?.createdAt == fixture.clock.now)

        // Other profiles keep an independent history.
        let otherKey = AmiVoiceDictionaryProfileKey(engine: .hybridJapaneseConversation, samplingRate: .rate8k)
        #expect(await fixture.engine.upsertEntry(
            AmiVoiceDictionaryEntry(written: "霧峰システム", spoken: "きりみねしすてむ", createdAt: t0),
            for: otherKey,
            state: .readyToSync
        ))
        _ = await fixture.engine.syncNow(for: otherKey)
        #expect(await fixture.engine.syncSnapshots(for: otherKey).count == 1)
    }

    @Test func rollbackRestoresSetKeepsIgnoredAndAppendsRollbackSnapshot() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let aID = UUID()
        let bID = UUID()
        _ = try await syncedEntry(fixture, id: aID, written: "AlphaWord", createdAt: t0)
        #expect(await fixture.engine.upsertEntry(
            AmiVoiceDictionaryEntry(id: bID, written: "BetaWord", createdAt: t0),
            for: fixture.key,
            state: .readyToSync
        ))
        fixture.clock.advance(by: 60)
        #expect(await fixture.engine.syncNow(for: fixture.key).kind == .success)
        let snapshotAB = try #require(await fixture.engine.latestReflectedSyncSnapshot(for: fixture.key))
        #expect(Set(snapshotAB.entries.map(\.written)) == ["AlphaWord", "BetaWord"])

        // C joins and is later ignored; D is added but never synced.
        let cID = UUID()
        let dID = UUID()
        #expect(await fixture.engine.upsertEntry(
            AmiVoiceDictionaryEntry(id: cID, written: "GammaWord", createdAt: t0),
            for: fixture.key,
            state: .readyToSync
        ))
        fixture.clock.advance(by: 60)
        #expect(await fixture.engine.syncNow(for: fixture.key).kind == .success)
        #expect(await fixture.engine.transitionEntry(id: cID, for: fixture.key, to: .ignored))
        // The ignored-transition spawns an immediate sync; drain it fully so
        // the rollback send below is not blocked by the single-flight gate.
        await drainSyncs(in: fixture, expectedPOSTs: 4)
        #expect(await fixture.engine.upsertEntry(
            AmiVoiceDictionaryEntry(id: dID, written: "DeltaWord", createdAt: t0),
            for: fixture.key,
            state: .readyToSync
        ))
        fixture.transport.resetCalls()

        let outcome = await fixture.engine.rollbackProfile(for: fixture.key, toSnapshotID: snapshotAB.id)
        #expect(outcome.kind == .applied)
        #expect(outcome.restoredEntryCount == 2)
        #expect(outcome.keptIgnoredCount == 0)
        #expect(outcome.archivedEntryCount == 1)

        // The immediate send carried exactly the restored set.
        let posts = fixture.transport.calls.filter { $0.method == "POST" }
        #expect(posts.count == 1)
        #expect(Set(posts[0].payloads.map(\.written)) == ["AlphaWord", "BetaWord"])

        let rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == aID }?.engineState(for: fixture.key)?.state == .autoSynced)
        #expect(rows.first { $0.id == bID }?.engineState(for: fixture.key)?.state == .autoSynced)
        #expect(rows.first { $0.id == dID }?.engineState(for: fixture.key)?.state == .archived)

        // History grew by one rollback snapshot; nothing was rewritten. The
        // four prior snapshots are the three explicit syncs plus the
        // immediate sync spawned by the ignored-transition.
        let snapshots = await fixture.engine.syncSnapshots(for: fixture.key)
        #expect(snapshots.count == 5)
        let rollbackSnapshot = try #require(snapshots.first)
        #expect(rollbackSnapshot.trigger == .rollback)
        #expect(rollbackSnapshot.status == .reflected)
        #expect(rollbackSnapshot.rollbackSourceSnapshotID == snapshotAB.id)
        #expect(Set(rollbackSnapshot.entries.map(\.written)) == ["AlphaWord", "BetaWord"])
        #expect(outcome.rollbackSnapshotID == rollbackSnapshot.id)
        #expect(snapshots.dropFirst().map(\.id).contains(snapshotAB.id))

        // Post-snapshot `ignored` stays ignored: rolling back to the latest
        // snapshot (which contains C) must not revive it — and here C was
        // ignored after snapshotAB, so membership alone does not restore it.
        let snapshotABC = snapshots.first { snapshot in
            Set(snapshot.entries.map(\.written)) == ["AlphaWord", "BetaWord", "GammaWord"]
        }
        if let snapshotABC {
            // C is still ignored after the first rollback, so this transition
            // is a no-op that spawns no extra sync.
            #expect(await fixture.engine.transitionEntry(id: cID, for: fixture.key, to: .ignored))
            fixture.transport.resetCalls()
            let second = await fixture.engine.rollbackProfile(for: fixture.key, toSnapshotID: snapshotABC.id)
            #expect(second.keptIgnoredCount == 1)
            let rowsAfter = await fixture.engine.entries()
            #expect(rowsAfter.first { $0.id == cID }?.engineState(for: fixture.key)?.state == .ignored)
            let secondPosts = fixture.transport.calls.filter { $0.method == "POST" }
            #expect(secondPosts.count == 1)
            #expect(Set(secondPosts[0].payloads.map(\.written)) == ["AlphaWord", "BetaWord"])
        } else {
            Issue.record("expected a snapshot containing GammaWord")
        }
    }

    @Test func rollbackSendFailureLeavesRestoreInPlaceAndNextNormalTriggerRetries() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let aID = UUID()
        _ = try await syncedEntry(fixture, id: aID, written: "AlphaWord", createdAt: t0)
        let snapshotA = try #require(await fixture.engine.latestReflectedSyncSnapshot(for: fixture.key))
        let bID = UUID()
        #expect(await fixture.engine.upsertEntry(
            AmiVoiceDictionaryEntry(id: bID, written: "BetaWord", createdAt: t0),
            for: fixture.key,
            state: .readyToSync
        ))
        fixture.clock.advance(by: 60)
        #expect(await fixture.engine.syncNow(for: fixture.key).kind == .success)

        fixture.transport.replaceHandler = { _ in throw AmiVoiceDictionaryTransportError.temporary(.network) }
        let outcome = await fixture.engine.rollbackProfile(for: fixture.key, toSnapshotID: snapshotA.id)
        #expect(outcome.kind == .appliedReflectionPending)
        #expect(outcome.syncResult == .temporaryFailure)

        // The local restore stands even though the send failed.
        var rows = await fixture.engine.entries()
        let aState = rows.first { $0.id == aID }?.engineState(for: fixture.key)
        #expect(aState?.state == .readyToSync)
        #expect(aState?.dirty == true)
        #expect(rows.first { $0.id == bID }?.engineState(for: fixture.key)?.state == .archived)
        let rollbackSnapshot = try #require(await fixture.engine.syncSnapshots(for: fixture.key).first)
        #expect(rollbackSnapshot.trigger == .rollback)
        #expect(rollbackSnapshot.status == .failed)
        #expect(rollbackSnapshot.rollbackSourceSnapshotID == snapshotA.id)

        // U-04: the next normal trigger retries the pending reflection.
        fixture.transport.replaceHandler = nil
        fixture.transport.resetCalls()
        let retried = await fixture.engine.syncNow(for: fixture.key)
        #expect(retried.kind == .success)
        #expect(Set(fixture.transport.calls.filter { $0.method == "POST" }.last?.payloads.map(\.written) ?? []) == ["AlphaWord"])
        rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == aID }?.engineState(for: fixture.key)?.state == .autoSynced)
    }

    @Test func staleInFlightSyncCannotMarkRestoredSetReflected() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let aID = UUID()
        _ = try await syncedEntry(fixture, id: aID, written: "AlphaWord", createdAt: t0)
        let snapshotA = try #require(await fixture.engine.latestReflectedSyncSnapshot(for: fixture.key))
        let bID = UUID()
        #expect(await fixture.engine.upsertEntry(
            AmiVoiceDictionaryEntry(id: bID, written: "BetaWord", createdAt: t0),
            for: fixture.key,
            state: .readyToSync
        ))

        // Hold the normal sync's POST open, then roll back underneath it.
        let gate = MonitoringAsyncGate()
        let postEntered = LockedFlag()
        fixture.transport.replaceHandler = { payloads in
            postEntered.set()
            await gate.wait()
            return payloads
        }
        let syncEngine = fixture.engine
        let profileKey = fixture.key
        let staleSync = Task { await syncEngine.syncNow(for: profileKey) }
        while !postEntered.isSet {
            try? await Task.sleep(for: .milliseconds(1))
        }

        let outcome = await fixture.engine.rollbackProfile(for: fixture.key, toSnapshotID: snapshotA.id)
        // Single-flight: the rollback send could not run while the stale sync
        // held the profile, so the restored set is a pending reflection.
        #expect(outcome.kind == .appliedReflectionPending)
        gate.open()
        _ = await staleSync.value

        // Revision check: the stale sync's completion must not mark the
        // restored rows autoSynced — their generations moved past the
        // snapshot it captured.
        var rows = await fixture.engine.entries()
        let aState = rows.first { $0.id == aID }?.engineState(for: fixture.key)
        #expect(aState?.state == .readyToSync)
        #expect(aState?.dirty == true)
        #expect(rows.first { $0.id == bID }?.engineState(for: fixture.key)?.state == .archived)

        fixture.transport.replaceHandler = nil
        let retry = await fixture.engine.retryPendingRollbackReflection(for: fixture.key)
        #expect(retry.kind == .success)
        rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == aID }?.engineState(for: fixture.key)?.state == .autoSynced)
    }

    @Test func reverseCorrectionOutsideWindowDoesNotAccumulateOrResync() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        let syncedAt = fixture.clock.now
        let r1 = LearnedTerm(term: "Different", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(100))
        let first = await fixture.monitor.observe(learnedTerms: [r1], for: fixture.key)
        #expect(first.transitions.isEmpty)
        #expect(await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)?.reverseCorrectionTimestamps.count == 1)

        // GD-731 AC-07: past the reverse-correction window the first
        // occurrence ages out; a new one must not reach the threshold nor
        // fire the immediate re-sync path.
        fixture.clock.advance(by: AmiVoiceDictionaryMonitoringPolicy.reverseCorrectionWindow + 3_600)
        fixture.transport.resetCalls()
        let r2 = LearnedTerm(term: "OtherText", originalFragment: "KoeBridge", createdAt: fixture.clock.now)
        let report = await fixture.monitor.observe(learnedTerms: [r1, r2], for: fixture.key)
        #expect(report.transitions.isEmpty)
        #expect(await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)?.reverseCorrectionTimestamps.count == 1)
        let rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == entryID }?.engineState(for: fixture.key)?.state == .autoSynced)
        #expect(fixture.transport.calls.filter { $0.method == "POST" }.isEmpty)
    }

    @Test func resetCorrectionTrackingClearsAccumulatedCounters() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        let syncedAt = fixture.clock.now
        let source = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: t0.addingTimeInterval(-60))
        let c1 = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: syncedAt.addingTimeInterval(100))
        let r1 = LearnedTerm(term: "Different", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(150))
        _ = await fixture.monitor.observe(learnedTerms: [source, c1, r1], for: fixture.key)
        var record = await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)
        #expect(record?.reCorrectionTimestamps.count == 1)
        #expect(record?.reverseCorrectionTimestamps.count == 1)

        // The B-4 hook must clear counters that already accumulated, not only
        // arm the guard on an empty record.
        fixture.clock.advance(by: 60)
        await fixture.monitor.resetCorrectionTracking(entryID: entryID, for: fixture.key)
        record = await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key)
        #expect(record?.reCorrectionTimestamps.isEmpty == true)
        #expect(record?.reverseCorrectionTimestamps.isEmpty == true)
        #expect(record?.lastManualEditAt == fixture.clock.now)
    }

    @Test func monitoringRecordPersistsFingerprintNotFragmentText() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        let syncedAt = fixture.clock.now
        let source = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: t0.addingTimeInterval(-60))
        let c1 = LearnedTerm(term: "KoeBridge", originalFragment: "KoeBride", createdAt: syncedAt.addingTimeInterval(100))
        _ = await fixture.monitor.observe(learnedTerms: [source, c1], for: fixture.key)

        // Pair matching still works through the fingerprint alone.
        let record = try #require(await fixture.monitor.monitoringRecord(entryID: entryID, for: fixture.key))
        #expect(record.sourceTermID == source.id)
        #expect(record.sourcePairFingerprint != nil)
        #expect(record.reCorrectionTimestamps.count == 1)

        // The persisted row carries no fragment text.
        let raw = try #require(fixture.defaults.data(forKey: AmiVoiceDictionarySyncStore.monitoringRecordsKey))
        let persisted = String(decoding: raw, as: UTF8.self)
        #expect(!persisted.contains("KoeBride"))
        #expect(!persisted.contains("originalFragment"))
    }

    @Test func legacyMonitoringRecordWithPlaintextFragmentStillDecodes() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        // Rows written before the fingerprint migration carried the fragment
        // in plaintext; the decoder ignores the dropped key instead of
        // corrupting the whole store.
        let legacyRow: [String: Any] = [
            "entryID": entryID.uuidString,
            "profileKey": [
                "engine": fixture.key.engine.rawValue,
                "samplingRate": fixture.key.samplingRate.rawValue
            ],
            "originalFragment": "KoeBride",
            "reCorrectionTimestamps": [],
            "reverseCorrectionTimestamps": []
        ]
        let data = try JSONSerialization.data(withJSONObject: [legacyRow])
        fixture.defaults.set(data, forKey: AmiVoiceDictionarySyncStore.monitoringRecordsKey)

        // A store constructed over the legacy value decodes it; provenance is
        // simply absent until the next observe re-derives it.
        let reloaded = AmiVoiceDictionarySyncStore(defaults: fixture.defaults)
        let records = reloaded.loadMonitoringRecords()
        #expect(records.count == 1)
        #expect(records.first?.entryID == entryID)
        #expect(records.first?.sourcePairFingerprint == nil)
        #expect(records.first?.sourceTermID == nil)
    }

    @Test func appendSnapshotRecoversAfterCorruptStoreInsteadOfDropping() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        _ = try await syncedEntry(fixture, id: UUID(), written: "KoeBridge", createdAt: t0)

        fixture.defaults.set(Data("not-json".utf8), forKey: AmiVoiceDictionarySyncStore.snapshotsKey)
        let corrupted = AmiVoiceDictionarySyncSnapshot(
            createdAt: t0,
            profileKey: fixture.key,
            trigger: .normal,
            status: .reflected,
            entries: []
        )
        // The first append exposes the conflict: the save fails and the store
        // reloads the value as corrupt. The NEXT append must run the same
        // recovery the load paths do instead of silently dropping snapshots.
        _ = fixture.store.appendSnapshot(corrupted)
        let healed = AmiVoiceDictionarySyncSnapshot(
            createdAt: t0.addingTimeInterval(1),
            profileKey: fixture.key,
            trigger: .normal,
            status: .reflected,
            entries: []
        )
        #expect(fixture.store.appendSnapshot(healed))
        #expect(fixture.store.loadSnapshots().map(\.id) == [healed.id])
    }

    @Test func rollbackToEmptySnapshotRetriesPushEmptyOverwrite() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let aID = UUID()
        _ = try await syncedEntry(fixture, id: aID, written: "AlphaWord", createdAt: t0)

        // A reflected snapshot of the empty set, e.g. left by an earlier
        // delete-all. Rolling back to it must clear the server again.
        let emptySnapshot = AmiVoiceDictionarySyncSnapshot(
            createdAt: t0,
            profileKey: fixture.key,
            trigger: .manualImmediate,
            status: .reflected,
            entries: []
        )
        #expect(fixture.store.appendSnapshot(emptySnapshot))

        fixture.transport.replaceHandler = { _ in throw AmiVoiceDictionaryTransportError.temporary(.network) }
        let outcome = await fixture.engine.rollbackProfile(for: fixture.key, toSnapshotID: emptySnapshot.id)
        #expect(outcome.kind == .appliedReflectionPending)
        #expect(outcome.syncResult == .temporaryFailure)
        let rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == aID }?.engineState(for: fixture.key)?.state == .archived)

        // The failed empty send is the pending-operation record (U-04).
        let pending = try #require(await fixture.engine.syncSnapshots(for: fixture.key).first)
        #expect(pending.status == .failed)
        #expect(pending.trigger == .rollback)
        #expect(pending.entries.isEmpty)

        // The explicit retry still pushes [] — it is not swallowed by the
        // ordinary empty-snapshot guard.
        fixture.transport.replaceHandler = nil
        fixture.transport.resetCalls()
        let retry = await fixture.engine.retryPendingRollbackReflection(for: fixture.key)
        #expect(retry.kind == .success)
        let posts = fixture.transport.calls.filter { $0.method == "POST" }
        #expect(posts.count == 1)
        #expect(posts[0].payloads.isEmpty)
    }

    @Test func loneQuarantineFailedResyncRetryPushesRemoval() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        let syncedAt = fixture.clock.now
        fixture.transport.replaceHandler = { _ in throw AmiVoiceDictionaryTransportError.temporary(.network) }
        fixture.transport.resetCalls()

        let r1 = LearnedTerm(term: "Different", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(100))
        let r2 = LearnedTerm(term: "OtherText", originalFragment: "KoeBridge", createdAt: syncedAt.addingTimeInterval(200))
        let report = await fixture.monitor.observe(learnedTerms: [r1, r2], for: fixture.key)
        #expect(report.transitions.count == 1)

        // The immediate U-02 re-sync attempted the empty overwrite and failed.
        let posts = fixture.transport.calls.filter { $0.method == "POST" }
        #expect(posts.count == 1)
        #expect(posts[0].payloads.isEmpty)
        let rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == entryID }?.engineState(for: fixture.key)?.state == .autoDisabled)

        // The failed empty send is the pending-operation record: the backoff
        // retry still pushes the removal.
        fixture.transport.replaceHandler = nil
        fixture.transport.resetCalls()
        let retried = await fixture.engine.syncNow(for: fixture.key, trigger: .retry)
        #expect(retried.kind == .success)
        let retryPosts = fixture.transport.calls.filter { $0.method == "POST" }
        #expect(retryPosts.count == 1)
        #expect(retryPosts[0].payloads.isEmpty)
    }

    @Test func ordinaryEmptySetNeverPostsDeleteAll() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        fixture.transport.resetCalls()

        // fix5 stays intact: the last synced word leaving the set by an
        // ordinary transition must not become a delete-all — no pending
        // empty-overwrite operation was ever recorded.
        #expect(await fixture.engine.transitionEntry(id: entryID, for: fixture.key, to: .ignored))
        // The transition spawns an immediate sync; wait until it finishes.
        for _ in 0..<400 {
            if await !fixture.engine.isSyncInFlight(for: fixture.key),
               await fixture.engine.status(for: fixture.key).lastResult == .noChanges { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let outcome = await fixture.engine.syncNow(for: fixture.key)
        #expect(outcome.kind == .noChanges)
        #expect(fixture.transport.calls.filter { $0.method == "POST" }.isEmpty)
    }

    @Test func rollbackWhileSyncDisabledMutatesNothing() async throws {
        let fixture = try makeMonitoringFixture(start: t0)
        defer { fixture.cleanup() }
        let entryID = UUID()
        _ = try await syncedEntry(fixture, id: entryID, written: "KoeBridge", createdAt: t0)
        let snapshot = try #require(await fixture.engine.latestReflectedSyncSnapshot(for: fixture.key))
        let snapshotCount = await fixture.engine.syncSnapshots(for: fixture.key).count
        await fixture.engine.setAutomaticSyncEnabled(false)
        fixture.transport.resetCalls()

        // Same contract as deleteAllServerWords: no local mutation and no
        // failed-snapshot append while sync is OFF.
        let outcome = await fixture.engine.rollbackProfile(for: fixture.key, toSnapshotID: snapshot.id)
        #expect(outcome.kind == .disabled)
        let rows = await fixture.engine.entries()
        #expect(rows.first { $0.id == entryID }?.engineState(for: fixture.key)?.state == .autoSynced)
        #expect(await fixture.engine.syncSnapshots(for: fixture.key).count == snapshotCount)
        #expect(fixture.transport.calls.isEmpty)
    }
}

/// Polls until the mock transport has recorded at least `expectedPOSTs` POSTs
/// AND no sync is inside the engine's single-flight section. Used to drain
/// immediate syncs spawned as background tasks before asserting send counts.
private func drainSyncs(in fixture: MonitoringFixture, expectedPOSTs: Int) async {
    for _ in 0..<400 {
        let posts = fixture.transport.calls.filter { $0.method == "POST" }.count
        if posts >= expectedPOSTs, await !fixture.engine.isSyncInFlight(for: fixture.key) { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
