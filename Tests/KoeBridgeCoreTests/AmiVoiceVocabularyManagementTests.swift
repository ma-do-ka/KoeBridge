import Foundation
import Testing
@testable import KoeBridgeCore

struct AmiVoiceVocabularyManagementTests {
    private func makeManagement(
        suite: String
    ) throws -> (
        defaults: UserDefaults,
        store: AmiVoiceDictionarySyncStore,
        transport: MockAmiVoiceDictionaryTransport,
        engine: AmiVoiceDictionarySyncEngine,
        monitor: AmiVoiceDictionarySyncMonitor,
        management: AmiVoiceVocabularyManagement
    ) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = AmiVoiceDictionarySyncStore(defaults: defaults)
        let transport = MockAmiVoiceDictionaryTransport()
        let engine = AmiVoiceDictionarySyncEngine(
            store: store, transport: transport, apiKeyProvider: { "fixture-key" }
        )
        let monitor = AmiVoiceDictionarySyncMonitor(store: store, engine: engine)
        let management = AmiVoiceVocabularyManagement(
            store: store,
            engine: engine,
            monitor: monitor,
            consentStore: AmiVoiceDictionarySyncConsentStore(defaults: defaults)
        )
        return (defaults, store, transport, engine, monitor, management)
    }

    private let key = AmiVoiceDictionaryProfileKey(
        engine: .hybridJapaneseConversation, samplingRate: .rate16k
    )

    @Test func consentGateRequiresRecordedConsentAndPersistsAcrossRelaunch() async throws {
        let suite = "KoeBridge.AmiVoiceVocabMgmt." + UUID().uuidString
        let (defaults, store, transport, _, _, management) = try makeManagement(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Decline path: no record is written, the feature stays OFF, and the
        // management surface never reaches the transport.
        #expect(!management.hasRecordedSyncConsent)
        #expect(!store.automaticSyncEnabled)
        let declinedSync = await management.syncNow(for: key)
        #expect(declinedSync.kind == .disabled)
        #expect(transport.calls.isEmpty)

        // Agree path: the record persists the shown copy identifier and a date.
        let consent = management.recordSyncConsent()
        #expect(consent.copyIdentifier == AmiVoiceVocabularyManagementCopy.consentCopyIdentifier)
        #expect(management.hasRecordedSyncConsent)
        // Recording consent alone never enables the feature.
        #expect(!store.automaticSyncEnabled)

        // Round-trip through a fresh store instance ("relaunch").
        let reloaded = AmiVoiceDictionarySyncConsentStore(defaults: defaults)
        let persisted = try #require(reloaded.recordedConsent)
        #expect(persisted.copyIdentifier == consent.copyIdentifier)
        #expect(abs(persisted.consentedAt.timeIntervalSince(consent.consentedAt)) < 0.001)

        // A corrupt record fails safe to "no consent" — the panel shows again.
        defaults.set(Data("not-json".utf8), forKey: AmiVoiceDictionarySyncConsentStore.consentKey)
        #expect(reloaded.recordedConsent == nil)
    }

    @Test func offInertnessProducesZeroTransportCallsAcrossSurfaces() async throws {
        let suite = "KoeBridge.AmiVoiceVocabMgmt." + UUID().uuidString
        let (defaults, store, transport, _, _, management) = try makeManagement(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        var local = AmiVoiceDictionaryEntry(written: "KoeBridge", isProtected: true)
        local.updateEngineState(for: key) { $0.state = .ignored }
        #expect(store.saveEntries([local]))

        // Every display surface reads the local store only.
        #expect(management.rows(for: key, filter: .all, query: "").count == 1)
        #expect(management.summary(for: key).totalCount == 1)
        #expect(management.snapshotHistory(for: key).isEmpty)

        // Local edits save with the sync outcome reporting .disabled.
        let saveOutcome = await management.saveManualEntry(
            id: nil, written: "アストラ", spoken: "あすとら", className: nil,
            mode: .sync, for: key
        )
        #expect(saveOutcome.saved)
        #expect(saveOutcome.syncOutcome?.kind == .disabled)

        let entryID = try #require(saveOutcome.entryID)
        let deleteOutcome = await management.deleteEntry(id: entryID, for: key)
        #expect(deleteOutcome.kind == .disabled)

        // Delete-all with sync OFF is local-only by construction.
        let allOutcomes = await management.deleteAll(scope: .localAndServer, currentKey: key)
        #expect(allOutcomes[key]?.kind == .disabled)
        #expect(store.loadEntries().isEmpty)
        #expect(transport.calls.isEmpty)
    }

    @Test func approveReviewEntryMovesToSyncableAndFiresImmediateSync() async throws {
        let suite = "KoeBridge.AmiVoiceVocabMgmt." + UUID().uuidString
        let (defaults, store, transport, engine, _, management) = try makeManagement(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let entryID = UUID()
        // Seed while OFF so no debounced sync fires before the action.
        #expect(await engine.upsertEntry(
            AmiVoiceDictionaryEntry(id: entryID, written: "霧峰システム", spoken: "きりみねしすてむ"),
            for: key, state: .pendingReview
        ))
        await engine.setAutomaticSyncEnabled(true)
        transport.resetCalls()

        let approved = await management.approveReviewEntry(id: entryID, reading: "きりみねしすてむ", for: key)
        #expect(approved)
        // The approval fired B-1's immediate user-action sync and the entry
        // landed on the server set.
        #expect(transport.calls.contains { $0.method == "POST" })
        let rows = await engine.entries()
        let row = try #require(rows.first { $0.id == entryID })
        #expect(row.isProtected)
        #expect(row.engineState(for: key)?.state == .autoSynced)
        // The approval also armed the monitor's manual-edit bookkeeping.
        #expect(store.loadMonitoringRecords().first { $0.entryID == entryID }?.lastManualEditAt != nil)
    }

    @Test func rejectReviewEntryMovesToTerminalIgnoredState() async throws {
        let suite = "KoeBridge.AmiVoiceVocabMgmt." + UUID().uuidString
        let (defaults, _, transport, engine, _, management) = try makeManagement(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let entryID = UUID()
        #expect(await engine.upsertEntry(
            AmiVoiceDictionaryEntry(id: entryID, written: "霧峰システム", spoken: "きりみねしすてむ"),
            for: key, state: .pendingReview
        ))
        await engine.setAutomaticSyncEnabled(true)

        let rejected = await management.rejectReviewEntry(id: entryID, for: key)
        #expect(rejected)
        var rows = await engine.entries()
        #expect(rows.first { $0.id == entryID }?.engineState(for: key)?.state == .ignored)

        // The ignored state is terminal: a follow-up sync neither re-adds nor
        // auto-revives the entry.
        _ = await management.syncNow(for: key)
        rows = await engine.entries()
        #expect(rows.first { $0.id == entryID }?.engineState(for: key)?.state == .ignored)
        #expect(transport.calls
            .filter { $0.method == "POST" }
            .allSatisfy { !$0.payloads.contains { $0.written == "霧峰システム" } })
    }

    @Test func manualEditResetsMonitoringCountersAndFiresImmediateSync() async throws {
        let suite = "KoeBridge.AmiVoiceVocabMgmt." + UUID().uuidString
        let (defaults, store, transport, engine, _, management) = try makeManagement(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let entryID = UUID()
        #expect(await engine.upsertEntry(
            AmiVoiceDictionaryEntry(id: entryID, written: "霧峰システム", spoken: "きりみねしすてむ"),
            for: key, state: .readyToSync
        ))
        #expect(store.saveMonitoringRecords([AmiVoiceDictionaryMonitoringRecord(
            entryID: entryID,
            profileKey: key,
            reCorrectionTimestamps: [Date()],
            reverseCorrectionTimestamps: [Date(), Date()]
        )]))
        await engine.setAutomaticSyncEnabled(true)
        transport.resetCalls()

        let outcome = await management.saveManualEntry(
            id: entryID, written: "霧峰システム", spoken: "きりみねしすてむ",
            className: nil, mode: .sync, for: key
        )
        #expect(outcome.saved)
        #expect(transport.calls.contains { $0.method == "POST" })
        let record = try #require(store.loadMonitoringRecords().first { $0.entryID == entryID })
        #expect(record.reCorrectionTimestamps.isEmpty)
        #expect(record.reverseCorrectionTimestamps.isEmpty)
        #expect(record.lastManualEditAt != nil)
        // A manual save always marks the entry protected.
        let rows = await engine.entries()
        #expect(rows.first { $0.id == entryID }?.isProtected == true)
    }

    @Test func deleteAllWithSyncOnSendsEmptyArrayPerProfileAndTurnsSyncOff() async throws {
        let suite = "KoeBridge.AmiVoiceVocabMgmt." + UUID().uuidString
        let (defaults, store, transport, engine, _, management) = try makeManagement(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(await engine.upsertEntry(
            AmiVoiceDictionaryEntry(written: "霧峰システム", spoken: "きりみねしすてむ"),
            for: key, state: .readyToSync
        ))
        await engine.setAutomaticSyncEnabled(true)
        let initial = await engine.syncNow(for: key)
        #expect(initial.kind == .success)
        transport.resetCalls()

        let outcomes = await management.deleteAll(scope: .serverOnly, currentKey: key)
        #expect(outcomes[key]?.kind == .success)
        // Every configured profile received the empty-array overwrite.
        let posts = transport.calls.filter { $0.method == "POST" }
        #expect(posts.contains { $0.payloads.isEmpty })
        // The copy promises automatic sync turns OFF afterwards.
        #expect(!store.automaticSyncEnabled)
        // .serverOnly keeps the local rows.
        #expect(store.loadEntries().count == 1)

        // .localAndServer also clears the local list.
        await engine.setAutomaticSyncEnabled(true)
        transport.resetCalls()
        _ = await management.deleteAll(scope: .localAndServer, currentKey: key)
        #expect(store.loadEntries().isEmpty)
        #expect(transport.calls.filter { $0.method == "POST" }.contains { $0.payloads.isEmpty })
    }

    @Test func deleteAllWithSyncOffSendsNothingAndClearsOnlyLocal() async throws {
        let suite = "KoeBridge.AmiVoiceVocabMgmt." + UUID().uuidString
        let (defaults, store, transport, engine, _, management) = try makeManagement(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(await engine.upsertEntry(
            AmiVoiceDictionaryEntry(written: "霧峰システム", spoken: "きりみねしすてむ"),
            for: key, state: .readyToSync
        ))

        let outcomes = await management.deleteAll(scope: .localAndServer, currentKey: key)
        #expect(outcomes[key]?.kind == .disabled)
        #expect(store.loadEntries().isEmpty)
        #expect(transport.calls.isEmpty)
    }

    @Test func listSortsProtectedFirstThenNewestAndFiltersByState() throws {
        let suite = "KoeBridge.AmiVoiceVocabMgmt." + UUID().uuidString
        let (defaults, store, _, _, _, management) = try makeManagement(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        var protectedOld = AmiVoiceDictionaryEntry(
            written: "ProtectedOld", isProtected: true,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        protectedOld.updateEngineState(for: key) { $0.state = .autoSynced }
        var plainNew = AmiVoiceDictionaryEntry(
            written: "PlainNew", createdAt: Date(timeIntervalSince1970: 3_000)
        )
        plainNew.updateEngineState(for: key) { $0.state = .autoSynced }
        var plainOld = AmiVoiceDictionaryEntry(
            written: "PlainOld", createdAt: Date(timeIntervalSince1970: 2_000)
        )
        plainOld.updateEngineState(for: key) { $0.state = .pendingReview }
        #expect(store.saveEntries([protectedOld, plainNew, plainOld]))

        let rows = management.rows(for: key, filter: .all, query: "")
        #expect(rows.map(\.entry.written) == ["ProtectedOld", "PlainNew", "PlainOld"])
        #expect(management.rows(for: key, filter: .pendingReview, query: "")
            .map(\.entry.written) == ["PlainOld"])
        #expect(management.rows(for: key, filter: .all, query: "plainnew")
            .map(\.entry.written) == ["PlainNew"])
    }

    @Test func summaryFlagsSoftAndHardCapsAtTheirThresholds() throws {
        let suite = "KoeBridge.AmiVoiceVocabMgmt." + UUID().uuidString
        let (defaults, store, _, _, _, management) = try makeManagement(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        func seededEntries(_ count: Int) -> [AmiVoiceDictionaryEntry] {
            (0..<count).map { index in
                var entry = AmiVoiceDictionaryEntry(written: "Word\(index)")
                entry.updateEngineState(for: key) { $0.state = .autoSynced }
                return entry
            }
        }
        #expect(store.saveEntries(seededEntries(AmiVoiceDictionarySyncPolicy.softEntryLimit - 1)))
        var summary = management.summary(for: key)
        #expect(!summary.softCapExceeded)
        #expect(!summary.hardCapReached)

        #expect(store.saveEntries(seededEntries(AmiVoiceDictionarySyncPolicy.softEntryLimit)))
        summary = management.summary(for: key)
        #expect(summary.softCapExceeded)
        #expect(!summary.hardCapReached)

        #expect(store.saveEntries(seededEntries(AmiVoiceDictionarySyncPolicy.hardEntryLimit)))
        summary = management.summary(for: key)
        #expect(summary.softCapExceeded)
        #expect(summary.hardCapReached)
        #expect(summary.syncedCount == AmiVoiceDictionarySyncPolicy.hardEntryLimit)
    }

    @Test func emptyAndFilteredListsDriveBothEmptyStates() throws {
        let suite = "KoeBridge.AmiVoiceVocabMgmt." + UUID().uuidString
        let (defaults, store, _, _, _, management) = try makeManagement(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // No entries at all -> the initial empty state (two copy variants).
        #expect(management.rows(for: key, filter: .all, query: "").isEmpty)
        #expect(management.summary(for: key).totalCount == 0)
        #expect(AmiVoiceVocabularyManagementCopy.emptyOnTitle
            != AmiVoiceVocabularyManagementCopy.emptyOffTitle)
        #expect(!AmiVoiceVocabularyManagementCopy.emptyOnTitle.isEmpty)
        #expect(!AmiVoiceVocabularyManagementCopy.emptyOffBody.isEmpty)

        var entry = AmiVoiceDictionaryEntry(written: "KoeBridge")
        entry.updateEngineState(for: key) { $0.state = .autoSynced }
        #expect(store.saveEntries([entry]))

        // Entries exist but nothing matches -> the filtered empty state.
        #expect(management.rows(for: key, filter: .all, query: "存在しない語").isEmpty)
        #expect(!AmiVoiceVocabularyManagementCopy.emptyFilteredTitle.isEmpty)
        #expect(!AmiVoiceVocabularyManagementCopy.emptyFilteredBody.isEmpty)
    }

    @Test func quarantineSurfaceShowsRecordedReason() throws {
        let suite = "KoeBridge.AmiVoiceVocabMgmt." + UUID().uuidString
        let (defaults, store, _, _, _, management) = try makeManagement(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let entryID = UUID()
        let occurrences = [Date(timeIntervalSince1970: 1_000), Date(timeIntervalSince1970: 2_000)]

        var entry = AmiVoiceDictionaryEntry(id: entryID, written: "霧峰システム")
        entry.updateEngineState(for: key) { $0.state = .autoDisabled }
        #expect(store.saveEntries([entry]))
        #expect(store.saveMonitoringRecords([AmiVoiceDictionaryMonitoringRecord(
            entryID: entryID,
            profileKey: key,
            lastAutoTransition: AmiVoiceDictionaryMonitoringTransition(
                entryID: entryID,
                kind: .reverseCorrection,
                toState: .autoDisabled,
                at: Date(timeIntervalSince1970: 2_000),
                occurrenceCount: occurrences.count,
                windowDays: 7,
                occurrenceTimestamps: occurrences
            )
        )]))

        let row = try #require(management.rows(for: key, filter: .autoDisabled, query: "").first)
        let info = try #require(management.quarantineInfo(for: row))
        #expect(info.occurrenceCount == 2)
        #expect(info.windowDays == 7)
        #expect(info.occurrenceTimestamps == occurrences)
    }

    @Test func reviewInfoFallsBackToNeutralReasonWithoutLearnedTerm() throws {
        let suite = "KoeBridge.AmiVoiceVocabMgmt." + UUID().uuidString
        let (defaults, _, _, _, _, management) = try makeManagement(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let entry = AmiVoiceDictionaryEntry(written: "霧峰システム", spoken: "きりみねしすてむ")

        let info = management.reviewInfo(for: entry, for: key, learnedTerms: [])
        #expect(info.reason == nil)
        #expect(info.reasonText == AmiVoiceVocabularyManagementCopy.reviewReasonFallback)
        #expect(info.suggestedReading == "きりみねしすてむ")
    }

    @Test func formValidationBlocksAndWarnsPerCopyCategories() throws {
        let suite = "KoeBridge.AmiVoiceVocabMgmt." + UUID().uuidString
        let (defaults, _, _, _, _, management) = try makeManagement(suite: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let empty = management.validateForm(
            written: "  ", spoken: "", family: .hybrid, excluding: nil
        )
        #expect(empty.contains(.emptyWritten))
        #expect(empty.contains(.missingSpoken))
        #expect(empty.filter(\.isBlocking).count >= 2)

        let forbidden = management.validateForm(
            written: "Bad|Word", spoken: "きりみね", family: .hybrid, excluding: nil
        )
        #expect(forbidden.contains(.forbiddenWrittenCharacter))

        let short = management.validateForm(
            written: "霧峰", spoken: "きり", family: .hybrid, excluding: nil
        )
        #expect(short.contains(.shortReading(mora: 2)))
        #expect(short.allSatisfy { !$0.isBlocking })

        // E2E carries no reading: an empty reading is not an error there.
        let e2e = management.validateForm(
            written: "KoeBridge", spoken: nil, family: .e2e, excluding: nil
        )
        #expect(e2e.isEmpty)
    }

    @Test func snapshotDiffCountsAddedUpdatedAndRemoved() {
        let older = AmiVoiceDictionarySyncSnapshot(
            createdAt: Date(timeIntervalSince1970: 1_000),
            profileKey: key,
            trigger: .normal,
            status: .reflected,
            entries: [
                AmiVoiceDictionarySnapshotEntry(
                    entryID: UUID(), written: "Keep", createdAt: Date(), updatedAt: Date(),
                    stateAtSend: .autoSynced
                ),
                AmiVoiceDictionarySnapshotEntry(
                    entryID: UUID(), written: "Change", spoken: "あ", createdAt: Date(),
                    updatedAt: Date(), stateAtSend: .autoSynced
                ),
                AmiVoiceDictionarySnapshotEntry(
                    entryID: UUID(), written: "Drop", createdAt: Date(), updatedAt: Date(),
                    stateAtSend: .autoSynced
                ),
            ]
        )
        let changedID = older.entries[1].entryID
        let newer = AmiVoiceDictionarySyncSnapshot(
            createdAt: Date(timeIntervalSince1970: 2_000),
            profileKey: key,
            trigger: .normal,
            status: .reflected,
            entries: [
                older.entries[0],
                AmiVoiceDictionarySnapshotEntry(
                    entryID: changedID, written: "Change", spoken: "い", createdAt: Date(),
                    updatedAt: Date(), stateAtSend: .autoSynced
                ),
                AmiVoiceDictionarySnapshotEntry(
                    entryID: UUID(), written: "New", createdAt: Date(), updatedAt: Date(),
                    stateAtSend: .autoSynced
                ),
            ]
        )
        let counts = AmiVoiceVocabularyManagement.snapshotDiff(newer: newer, older: older)
        #expect(counts.added == 1)
        #expect(counts.updated == 1)
        #expect(counts.removed == 1)
    }

    @Test func consentAndPendingCopyKeepVerificationMarkersVerbatim() {
        // The three [要確認] items must survive verbatim so review stays aware.
        #expect(AmiVoiceVocabularyManagementCopy.consentItemDestinationBody
            .contains("[要確認：OQ-07 サーバー側プロファイルの保持期間・削除時挙動に関する確定文言を1行追記]"))
        #expect(AmiVoiceVocabularyManagementCopy.formReadingNote
            .contains("[要確認：OQ-05 文字種統一]"))
        #expect(AmiVoiceVocabularyManagementCopy.deleteAllBody(syncedCount: 3)
            .contains("[要確認：OQ-04/OQ-07 サーバー側即時削除の反映タイミングを追記]"))
        #expect(AmiVoiceVocabularyManagementCopy.deleteAllBody(syncedCount: 3).contains("現在 3 語"))

        // The consent panel's three items and its markdown formatting.
        #expect(AmiVoiceVocabularyManagementCopy.consentTitle == "学習した語彙の AmiVoice 自動同期を有効にしますか？")
        #expect(AmiVoiceVocabularyManagementCopy.consentItemSentTitle == "送信するもの")
        #expect(AmiVoiceVocabularyManagementCopy.consentItemDestinationTitle.contains("送信先"))
        #expect(AmiVoiceVocabularyManagementCopy.consentItemControlTitle == "やめ方と管理方法")
        #expect(AmiVoiceVocabularyManagementCopy.consentItemSentBody.contains("**「表記」**"))
        #expect(AmiVoiceVocabularyManagementCopy.consentItemDestinationBody.contains("`nolog`"))
        #expect(AmiVoiceVocabularyManagementCopy.consentAgreeButton == "同意して有効にする")
    }
}
