import Foundation
import Testing
@testable import KoeBridgeCore

/// Wiring tests for the B-2 -> B-1 bridge (review finding B-N7): the adapter
/// mapping, tracker seeding idempotence, and a store -> pipeline -> adapter ->
/// sync-input end-to-end pass including the empty-ready-set no-upload case.
struct VocabularySyncAdapterTests {
    private let hybridKey = AmiVoiceDictionaryProfileKey(engine: .hybridJapaneseConversation, samplingRate: .rate16k)
    private let e2eKey = AmiVoiceDictionaryProfileKey(engine: .e2eJapaneseGeneral, samplingRate: .rate16k)

    private func makeEngine() throws -> (AmiVoiceDictionarySyncEngine, MockAmiVoiceDictionaryTransport, @Sendable () -> Void) {
        let suite = "KoeBridge.VocabularySync." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = AmiVoiceDictionarySyncStore(defaults: defaults)
        let transport = MockAmiVoiceDictionaryTransport()
        let engine = AmiVoiceDictionarySyncEngine(store: store, transport: transport, apiKeyProvider: { "fixture-key" })
        // Only the suite name crosses the @Sendable boundary; UserDefaults is
        // not Sendable, so the cleanup closure rebuilds it inside.
        return (engine, transport, { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) })
    }

    private func apply(
        _ plan: VocabularySyncCoordinator.Plan,
        to engine: AmiVoiceDictionarySyncEngine,
        for key: AmiVoiceDictionaryProfileKey
    ) async {
        for id in plan.ignoredIDs {
            _ = await engine.transitionEntry(id: id, for: key, to: .ignored)
        }
        for id in plan.archivedIDs {
            _ = await engine.transitionEntry(id: id, for: key, to: .archived)
        }
        for entry in plan.pendingUpserts {
            _ = await engine.upsertEntry(entry, for: key, state: .pendingReview)
        }
        for entry in plan.readyUpserts {
            _ = await engine.upsertEntry(entry, for: key, state: .readyToSync)
        }
    }

    // MARK: - Adapter mapping

    @Test func adapterMapsOnlyReadyOutcomesInOrder() {
        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)
        let id1 = UUID(), id2 = UUID(), id3 = UUID(), id4 = UUID()
        let outcomes: [VocabularyCandidateOutcome] = [
            .ready(VocabularyCandidate(written: "クロハネ", reading: "くろはね", type: .kana, learnedTermID: id1, createdAt: t1, sourceRecordID: nil)),
            .pendingReview(.shortReadingGuard, VocabularyCandidate(written: "QA", reading: "", type: .alphabet, learnedTermID: id2, createdAt: t1, sourceRecordID: nil)),
            .excluded(.noiseOnly),
            .ready(VocabularyCandidate(written: "ハルカゼ", reading: "はるかぜ", type: .kana, learnedTermID: id3, createdAt: t2, sourceRecordID: nil)),
            // Same LearnedTerm id as the first ready outcome: deduped by id so a
            // repeated pipeline run stays upsert-stable.
            .ready(VocabularyCandidate(written: "クロハネ", reading: "くろはね", type: .kana, learnedTermID: id1, createdAt: t1, sourceRecordID: nil)),
            .ready(VocabularyCandidate(written: "シロガネ", reading: "しろがね", type: .kana, learnedTermID: id4, createdAt: t2, sourceRecordID: nil)),
        ]
        let entries = VocabularySyncAdapter.entries(from: outcomes, for: .hybridJapaneseConversation)
        #expect(entries.map(\.id) == [id1, id3, id4])
        #expect(entries.map(\.written) == ["クロハネ", "ハルカゼ", "シロガネ"])
        #expect(entries[0].spoken == "くろはね")
        #expect(entries[0].createdAt == t1)
        #expect(entries[0].engineStates.isEmpty)
        #expect(!entries[0].isProtected)
    }

    @Test func adapterReusesB1ValidationForTheTargetEngine() {
        // A ready candidate whose reading is not valid Hybrid spoken input must
        // be dropped for the hybrid engine but is legal for e2e (spoken is not
        // part of the e2e payload).
        let invalid = VocabularyCandidate(
            written: "混在ワード", reading: "abc123", type: .numericMixed,
            learnedTermID: UUID(), createdAt: Date(), sourceRecordID: nil
        )
        let valid = VocabularyCandidate(
            written: "クロハネ", reading: "くろはね", type: .kana,
            learnedTermID: UUID(), createdAt: Date(), sourceRecordID: nil
        )
        let outcomes: [VocabularyCandidateOutcome] = [.ready(invalid), .ready(valid)]
        let hybridEntries = VocabularySyncAdapter.entries(from: outcomes, for: .hybridJapaneseConversation)
        #expect(hybridEntries.map(\.written) == ["クロハネ"])
        let e2eEntries = VocabularySyncAdapter.entries(from: outcomes, for: .e2eJapaneseGeneral)
        #expect(e2eEntries.map(\.written) == ["混在ワード", "クロハネ"])
        // An empty written fails B-1 validation for both engine families.
        let emptyWritten = VocabularyCandidate(
            written: "", reading: "から", type: .kana,
            learnedTermID: UUID(), createdAt: Date(), sourceRecordID: nil
        )
        #expect(VocabularySyncAdapter.entries(from: [.ready(emptyWritten)], for: .e2eJapaneseGeneral).isEmpty)
    }

    // MARK: - Tracker seeding

    @Test func seedingFromStoreIsIdempotentAndFreshStartKeepsCollisionState() {
        let terms = [
            LearnedTerm(term: "クロハネ", originalFragment: "黒羽"),
            LearnedTerm(term: "ハルカゼ", originalFragment: "春風"),
        ]
        let coordinator = VocabularySyncCoordinator()
        let first = coordinator.ingest(terms: terms, existingEntries: [], for: hybridKey)
        let seeded = coordinator.trackedCandidates
        #expect(first.readyUpserts.map(\.written) == ["クロハネ", "ハルカゼ"])
        #expect(seeded.map(\.learnedTermID) == terms.map(\.id))

        let second = coordinator.ingest(terms: terms, existingEntries: [], for: hybridKey)
        #expect(coordinator.trackedCandidates == seeded)
        #expect(second.outcomes == first.outcomes)

        // A brand-new coordinator (a fresh app start) replays the same store
        // into identical candidate state instead of starting empty.
        let restarted = VocabularySyncCoordinator()
        _ = restarted.ingest(terms: terms, existingEntries: [], for: hybridKey)
        #expect(restarted.trackedCandidates == seeded)

        // The seeded set still drives the duplicate-reading guard: a new term
        // sharing くろはね with a different written form is held, not admitted.
        let colliding = LearnedTerm(term: "Kurohane", originalFragment: "黒羽")
        let grown = restarted.ingest(terms: terms + [colliding], existingEntries: [], for: hybridKey)
        guard let last = grown.outcomes.last, case .pendingReview(let reason, _) = last else {
            Issue.record("seeded tracker lost the くろはね collision state")
            return
        }
        #expect(reason == .duplicateReadingCollision)
    }

    @Test func seedingReplacesEditedTermsAndDropsNonReadySeeds() {
        let term = LearnedTerm(term: "クロハネ", originalFragment: "黒羽")
        let coordinator = VocabularySyncCoordinator()
        _ = coordinator.ingest(terms: [term], existingEntries: [], for: hybridKey)
        #expect(coordinator.trackedCandidates.count == 1)

        // Same LearnedTerm id, new written form: the seed is replaced, not
        // appended, so caps and collisions see the current form only.
        let edited = LearnedTerm(id: term.id, term: "くろはね", originalFragment: "黒羽",
                                 sourceRecordID: term.sourceRecordID, createdAt: term.createdAt)
        _ = coordinator.ingest(terms: [edited], existingEntries: [], for: hybridKey)
        #expect(coordinator.trackedCandidates.map(\.written) == ["くろはね"])

        // A term that stops being ready loses its tracked slot entirely.
        let held = LearnedTerm(id: term.id, term: "QA", originalFragment: "課",
                               sourceRecordID: term.sourceRecordID, createdAt: term.createdAt)
        let plan = coordinator.ingest(terms: [held], existingEntries: [], for: hybridKey)
        #expect(plan.outcomes.first?.isReady == false)
        #expect(coordinator.trackedCandidates.isEmpty)
        _ = coordinator.ingest(terms: [], existingEntries: [], for: hybridKey)
        #expect(coordinator.trackedCandidates.isEmpty)
    }

    // MARK: - Tracker eviction on delete

    @Test func deletingATermEvictsItsTrackedCandidate() {
        let deleted = LearnedTerm(term: "クロハネ", originalFragment: "黒羽")
        let kept = LearnedTerm(term: "ハルカゼ", originalFragment: "春風")
        let coordinator = VocabularySyncCoordinator()
        let first = coordinator.ingest(terms: [deleted, kept], existingEntries: [], for: e2eKey)
        #expect(first.readyUpserts.count == 2)
        let syncedRows = first.readyUpserts.map { entry -> AmiVoiceDictionaryEntry in
            var row = entry
            row.engineStates = [AmiVoiceDictionaryEngineState(key: e2eKey, state: .autoSynced)]
            return row
        }

        // The terms list shrinks with no replacement row for the deleted id.
        let removal = coordinator.ingest(terms: [kept], existingEntries: syncedRows, for: e2eKey)
        #expect(removal.archivedIDs == [deleted.id])
        #expect(coordinator.trackedCandidates.map(\.learnedTermID) == [kept.id])

        // A new term reusing the deleted term's reading is admitted instead of
        // colliding with the evicted ghost.
        let revived = LearnedTerm(term: "くろはね", originalFragment: "黒羽")
        let grown = coordinator.ingest(terms: [kept, revived], existingEntries: syncedRows, for: e2eKey)
        guard let last = grown.outcomes.last, case .ready = last else {
            Issue.record("deleted term's reading still collides after eviction")
            return
        }
        #expect(grown.readyUpserts.map(\.written) == ["くろはね"])
    }

    @Test func deletedTermsStopCountingTowardCaps() {
        var config = VocabularyCandidatePipeline.Configuration()
        config.softCap = 1
        config.safetyCap = 2
        let coordinator = VocabularySyncCoordinator(configuration: config)
        let first = LearnedTerm(term: "クロハネ", originalFragment: "黒羽")
        let second = LearnedTerm(term: "ハルカゼ", originalFragment: "春風")

        _ = coordinator.ingest(terms: [first], existingEntries: [], for: e2eKey)
        let held = coordinator.ingest(terms: [first, second], existingEntries: [], for: e2eKey)
        guard let heldOutcome = held.outcomes.last,
              case .pendingReview(let reason, _) = heldOutcome else {
            Issue.record("second term was not cap-held before the delete")
            return
        }
        #expect(reason == .capExceededSoft)

        // Deleting the first term frees its cap slot, so the previously held
        // term is admitted on the next reconcile.
        let regrown = coordinator.ingest(terms: [second], existingEntries: [], for: e2eKey)
        guard let outcome = regrown.outcomes.last, case .ready = outcome else {
            Issue.record("deleted term still counts toward the caps")
            return
        }
        #expect(coordinator.trackedCandidates.map(\.learnedTermID) == [second.id])
    }

    // MARK: - Reconcile vs. terminal engine states

    private func existingRow(
        _ entry: AmiVoiceDictionaryEntry,
        state: AmiVoiceDictionaryEntryState
    ) -> AmiVoiceDictionaryEntry {
        var row = entry
        row.engineStates = [AmiVoiceDictionaryEngineState(key: e2eKey, state: state)]
        return row
    }

    @Test func reconcileNeverResurrectsParkedRows() {
        let archivedTerm = LearnedTerm(term: "クロハネ", originalFragment: "黒羽")
        let ignoredTerm = LearnedTerm(term: "ハルカゼ", originalFragment: "春風")
        let failedTerm = LearnedTerm(term: "シロガネ", originalFragment: "白銀")
        let disabledTerm = LearnedTerm(term: "アカツキ", originalFragment: "暁")
        let heldTerm = LearnedTerm(term: "QA", originalFragment: "課")
        let heldArchivedTerm = LearnedTerm(term: "QB", originalFragment: "級")
        let heldIgnoredTerm = LearnedTerm(term: "QC", originalFragment: "休")
        let heldDisabledTerm = LearnedTerm(term: "QD", originalFragment: "駄")
        let excludedTerm = LearnedTerm(term: "子ども", originalFragment: "子供")
        let ignoredExcludedTerm = LearnedTerm(term: "アストラ同期", originalFragment: "アストラ同期、")
        let terms = [
            archivedTerm, ignoredTerm, failedTerm, disabledTerm,
            heldTerm, heldArchivedTerm, heldIgnoredTerm, heldDisabledTerm,
            excludedTerm, ignoredExcludedTerm,
        ]

        // Seed the tracker and reuse the coordinator's own emitted entries so
        // every parked row below is content-identical to a fresh upsert.
        let coordinator = VocabularySyncCoordinator()
        let seed = coordinator.ingest(terms: terms, existingEntries: [], for: e2eKey)
        let readyByID = Dictionary(uniqueKeysWithValues: seed.readyUpserts.map { ($0.id, $0) })
        let pendingByID = Dictionary(uniqueKeysWithValues: seed.pendingUpserts.map { ($0.id, $0) })
        #expect(readyByID.count == 4)
        #expect(pendingByID.count == 4)

        let existing = [
            existingRow(readyByID[archivedTerm.id]!, state: .archived),
            existingRow(readyByID[ignoredTerm.id]!, state: .ignored),
            existingRow(readyByID[failedTerm.id]!, state: .syncFailed),
            existingRow(readyByID[disabledTerm.id]!, state: .autoDisabled),
            existingRow(pendingByID[heldTerm.id]!, state: .pendingReview),
            existingRow(pendingByID[heldArchivedTerm.id]!, state: .archived),
            existingRow(pendingByID[heldIgnoredTerm.id]!, state: .ignored),
            existingRow(pendingByID[heldDisabledTerm.id]!, state: .autoDisabled),
            existingRow(
                AmiVoiceDictionaryEntry(id: excludedTerm.id, written: "子ども"),
                state: .readyToSync
            ),
            existingRow(
                AmiVoiceDictionaryEntry(id: ignoredExcludedTerm.id, written: "アストラ同期"),
                state: .ignored
            ),
        ]
        let plan = coordinator.ingest(terms: terms, existingEntries: existing, for: e2eKey)
        // Parked rows are never re-emitted; the only mutation left is the
        // participating row whose term became pipeline-excluded.
        #expect(plan.readyUpserts.isEmpty)
        #expect(plan.pendingUpserts.isEmpty)
        #expect(plan.ignoredIDs == [excludedTerm.id])
        #expect(plan.archivedIDs.isEmpty)
    }

    @Test func deleteAllThenIngestEmitsNoUpserts() async throws {
        let (engine, transport, cleanup) = try makeEngine()
        defer { cleanup() }
        await engine.setAutomaticSyncEnabled(true)
        let terms = [
            LearnedTerm(term: "クロハネ", originalFragment: "黒羽"),
            LearnedTerm(term: "ハルカゼ", originalFragment: "春風"),
            LearnedTerm(term: "QA", originalFragment: "課"),
        ]
        let coordinator = VocabularySyncCoordinator()
        await apply(coordinator.ingest(terms: terms, existingEntries: [], for: e2eKey), to: engine, for: e2eKey)
        #expect(await engine.syncNow(for: e2eKey).kind == .success)

        let delete = await engine.deleteAllServerWords(for: e2eKey)
        #expect(delete.kind == .success)
        let rows = await engine.entries()
        #expect(rows.allSatisfy {
            let state = $0.engineState(for: e2eKey)?.state
            return state == .archived || state == .pendingReview
        })

        // The delete-all archive is terminal for reconcile: the next ingest
        // must not re-upload the whole dictionary.
        let plan = coordinator.ingest(terms: terms, existingEntries: rows, for: e2eKey)
        #expect(plan.readyUpserts.isEmpty)
        #expect(plan.pendingUpserts.isEmpty)
        #expect(plan.ignoredIDs.isEmpty)
        #expect(plan.archivedIDs.isEmpty)
        await apply(plan, to: engine, for: e2eKey)
        transport.resetCalls()
        try? await Task.sleep(for: .milliseconds(200))
        _ = await engine.syncNow(for: e2eKey)
        #expect(transport.calls.filter { $0.method == "POST" }.isEmpty)
    }

    // MARK: - End-to-end store -> pipeline -> adapter -> sync input

    @Test func readyTermsReachTheSyncSnapshotAsReadyToSync() async throws {
        let (engine, transport, cleanup) = try makeEngine()
        defer { cleanup() }
        await engine.setAutomaticSyncEnabled(true)
        let terms = [
            LearnedTerm(term: "クロハネ", originalFragment: "黒羽"),
            LearnedTerm(term: "ハルカゼ", originalFragment: "春風"),
            LearnedTerm(term: "QA", originalFragment: "課"),          // held: short reading
            LearnedTerm(term: "子ども", originalFragment: "子供"),      // excluded: out of scope
        ]
        let coordinator = VocabularySyncCoordinator()
        let plan = coordinator.ingest(terms: terms, existingEntries: [], for: e2eKey)
        #expect(plan.readyUpserts.map(\.written).sorted() == ["クロハネ", "ハルカゼ"])
        #expect(plan.pendingUpserts.count == 1)
        #expect(plan.ignoredIDs.isEmpty && plan.archivedIDs.isEmpty)

        await apply(plan, to: engine, for: e2eKey)
        let rows = await engine.entries()
        let readyIDs = Set(plan.readyUpserts.map(\.id))
        for row in rows where readyIDs.contains(row.id) {
            #expect(row.engineState(for: e2eKey)?.state == .readyToSync)
            #expect(row.engineState(for: e2eKey)?.dirty == true)
        }

        let outcome = await engine.syncNow(for: e2eKey)
        #expect(outcome.kind == .success)
        let posts = transport.calls.filter { $0.method == "POST" }
        #expect(posts.count == 1)
        // sync-input equality: the posted payload set is exactly the adapter's
        // validated entry set for this engine.
        let expected = Set(plan.readyUpserts.compactMap {
            try? AmiVoiceDictionaryValidator.payload(for: $0, engine: e2eKey.engine)
        }.map(\.written))
        #expect(Set(posts[0].payloads.map(\.written)) == expected)
    }

    @Test func emptyReadySetNeverPostsAnUpload() async throws {
        let (engine, transport, cleanup) = try makeEngine()
        defer { cleanup() }
        await engine.setAutomaticSyncEnabled(true)

        // Store where nothing is ready: one held term, one excluded term.
        let held = LearnedTerm(term: "QA", originalFragment: "課")
        let excluded = LearnedTerm(term: "子ども", originalFragment: "子供")
        let coordinator = VocabularySyncCoordinator()
        let plan = coordinator.ingest(terms: [held, excluded], existingEntries: [], for: e2eKey)
        #expect(plan.readyUpserts.isEmpty)
        // Excluded terms create no rows; held terms become pendingReview rows.
        #expect(plan.ignoredIDs.isEmpty)

        await apply(plan, to: engine, for: e2eKey)
        let outcome = await engine.syncNow(for: e2eKey)
        // fix5 semantics: an empty snapshot without deleteAll intent is a no-op.
        #expect(outcome.kind != .success)
        #expect(transport.calls.filter { $0.method == "POST" }.isEmpty)
    }

    @Test func deletingTheLastReadyTermNeverPostsAnEmptyUpload() async throws {
        let (engine, transport, cleanup) = try makeEngine()
        defer { cleanup() }
        await engine.setAutomaticSyncEnabled(true)
        let terms = [LearnedTerm(term: "クロハネ", originalFragment: "黒羽")]
        let coordinator = VocabularySyncCoordinator()
        let plan = coordinator.ingest(terms: terms, existingEntries: [], for: e2eKey)
        await apply(plan, to: engine, for: e2eKey)
        let first = await engine.syncNow(for: e2eKey)
        #expect(first.kind == .success)
        #expect(transport.calls.filter { $0.method == "POST" }.count == 1)

        // The learned term is deleted: its row is orphaned and archived, the
        // snapshot becomes empty, and the fix5 guard must stop the upload.
        let existing = await engine.entries()
        let removal = coordinator.ingest(terms: [], existingEntries: existing, for: e2eKey)
        #expect(removal.readyUpserts.isEmpty)
        #expect(removal.archivedIDs == [terms[0].id])
        await apply(removal, to: engine, for: e2eKey)
        transport.resetCalls()

        // Let the archive-triggered immediate sync settle, then force one more.
        try? await Task.sleep(for: .milliseconds(200))
        let outcome = await engine.syncNow(for: e2eKey)
        #expect(outcome.kind != .success)
        #expect(transport.calls.filter { $0.method == "POST" }.isEmpty)
        let row = await engine.entries().first { $0.id == terms[0].id }
        #expect(row?.engineState(for: e2eKey)?.state == .archived)
    }

    @Test func removingOneOfTwoReadyTermsUploadsOnlyTheRemainder() async throws {
        let (engine, transport, cleanup) = try makeEngine()
        defer { cleanup() }
        await engine.setAutomaticSyncEnabled(true)
        let terms = [
            LearnedTerm(term: "クロハネ", originalFragment: "黒羽"),
            LearnedTerm(term: "ハルカゼ", originalFragment: "春風"),
        ]
        let coordinator = VocabularySyncCoordinator()
        await apply(coordinator.ingest(terms: terms, existingEntries: [], for: e2eKey), to: engine, for: e2eKey)
        #expect(await engine.syncNow(for: e2eKey).kind == .success)

        let existing = await engine.entries()
        let removal = coordinator.ingest(terms: [terms[1]], existingEntries: existing, for: e2eKey)
        #expect(removal.archivedIDs == [terms[0].id])
        #expect(removal.readyUpserts.isEmpty, "unchanged synced row must not be re-queued")
        await apply(removal, to: engine, for: e2eKey)

        try? await Task.sleep(for: .milliseconds(200))
        _ = await engine.syncNow(for: e2eKey)
        let lastPost = transport.calls.filter { $0.method == "POST" }.last
        #expect(lastPost?.payloads.map(\.written) == ["ハルカゼ"])
    }
}
