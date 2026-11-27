import Foundation

/// Recorded consent for the AmiVoice dictionary auto-sync opt-in. Persisted
/// with the copy identifier so a later copy change can require re-consent.
public struct AmiVoiceDictionarySyncConsent: Codable, Equatable, Sendable {
    public var copyIdentifier: String
    public var consentedAt: Date

    public init(copyIdentifier: String, consentedAt: Date) {
        self.copyIdentifier = copyIdentifier
        self.consentedAt = consentedAt
    }
}

/// UserDefaults-backed consent record for the auto-sync opt-in (B-4). Only
/// the record's presence matters to the consent gate; a corrupt value fails
/// safe to "no consent", which keeps the feature off until the user re-agrees.
public final class AmiVoiceDictionarySyncConsentStore: @unchecked Sendable {
    public static let consentKey = "amiVoiceDictionarySyncConsent"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var recordedConsent: AmiVoiceDictionarySyncConsent? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.consentKey) else { return nil }
        return try? JSONDecoder().decode(AmiVoiceDictionarySyncConsent.self, from: data)
    }

    @discardableResult
    public func record(copyIdentifier: String, at date: Date) -> AmiVoiceDictionarySyncConsent {
        let consent = AmiVoiceDictionarySyncConsent(copyIdentifier: copyIdentifier, consentedAt: date)
        lock.lock()
        defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(consent) {
            defaults.set(data, forKey: Self.consentKey)
        }
        return consent
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.consentKey)
    }
}

/// Filter tabs for the management list. Raw values match the display order in
/// GD-469 01 §3 (all first, attention filters after).
public enum AmiVoiceVocabularyListFilter: String, CaseIterable, Sendable {
    case all
    case synced
    case pendingReview = "pending_review"
    case readyToSync = "ready_to_sync"
    case autoDisabled = "auto_disabled"
    case syncFailed = "sync_failed"
    case archived
    case ignored

    public var title: String {
        switch self {
        case .all: return AmiVoiceVocabularyManagementCopy.filterTabAll
        case .synced: return AmiVoiceVocabularyManagementCopy.statusLabelSynced
        case .pendingReview: return AmiVoiceVocabularyManagementCopy.statusLabelPendingReview
        case .readyToSync: return AmiVoiceVocabularyManagementCopy.statusLabelReadyToSync
        case .autoDisabled: return AmiVoiceVocabularyManagementCopy.statusLabelAutoDisabled
        case .syncFailed: return AmiVoiceVocabularyManagementCopy.filterTabAttention
        case .archived: return AmiVoiceVocabularyManagementCopy.statusLabelArchived
        case .ignored: return AmiVoiceVocabularyManagementCopy.statusLabelIgnored
        }
    }

    public func matches(_ state: AmiVoiceDictionaryEntryState) -> Bool {
        switch self {
        case .all: return true
        case .synced: return state == .autoSynced
        case .pendingReview: return state == .pendingReview || state == .candidate
        case .readyToSync: return state == .readyToSync
        case .autoDisabled: return state == .autoDisabled
        case .syncFailed: return state == .syncFailed
        case .archived: return state == .archived
        case .ignored: return state == .ignored
        }
    }
}

/// One display row: the stored entry plus the engine state for the profile
/// being viewed and the B-3 monitoring bookkeeping (when it exists).
public struct AmiVoiceVocabularyRow: Identifiable, Equatable, Sendable {
    public var entry: AmiVoiceDictionaryEntry
    public var engineState: AmiVoiceDictionaryEngineState?
    public var monitoringRecord: AmiVoiceDictionaryMonitoringRecord?

    public var id: UUID { entry.id }

    /// Entries without a state for this profile are foreign to the current
    /// engine; they render under the generic review bucket only via `.all`.
    public var state: AmiVoiceDictionaryEntryState? { engineState?.state }
}

/// Aggregate numbers behind the list banners and the status bar.
public struct AmiVoiceVocabularyListSummary: Equatable, Sendable {
    /// Rows visible to this profile (have an engine state for the key).
    public var totalCount: Int
    /// Rows whose state participates in the snapshot (synced or queued).
    public var activeCount: Int
    /// Rows whose sends were reflected (`autoSynced`) — the count the
    /// delete-all copy reports as "currently synced".
    public var syncedCount: Int
    /// pendingReview + autoDisabled + syncFailed for this profile.
    public var attentionCount: Int
    public var pendingReviewCount: Int
    public var autoDisabledCount: Int
    public var syncFailedCount: Int
    public var softCapExceeded: Bool
    public var hardCapReached: Bool

    public init(
        totalCount: Int,
        activeCount: Int,
        syncedCount: Int,
        attentionCount: Int,
        pendingReviewCount: Int,
        autoDisabledCount: Int,
        syncFailedCount: Int,
        softCapExceeded: Bool,
        hardCapReached: Bool
    ) {
        self.totalCount = totalCount
        self.activeCount = activeCount
        self.syncedCount = syncedCount
        self.attentionCount = attentionCount
        self.pendingReviewCount = pendingReviewCount
        self.autoDisabledCount = autoDisabledCount
        self.syncFailedCount = syncFailedCount
        self.softCapExceeded = softCapExceeded
        self.hardCapReached = hardCapReached
    }
}

/// Form validation issue. Blocking issues prevent saving; warnings allow it.
public enum AmiVoiceVocabularyFormIssue: Equatable, Sendable {
    case emptyWritten
    case forbiddenWrittenCharacter
    case missingSpoken
    case invalidSpoken
    case longReading
    case duplicatePair
    case shortReading(mora: Int)
    case duplicateReading(reading: String, existingSurface: String)
    case writtenSpaceNormalized

    public var isBlocking: Bool {
        switch self {
        case .emptyWritten, .forbiddenWrittenCharacter, .missingSpoken,
             .invalidSpoken, .longReading, .duplicatePair:
            return true
        case .shortReading, .duplicateReading, .writtenSpaceNormalized:
            return false
        }
    }

    public var message: String {
        switch self {
        case .emptyWritten: return AmiVoiceVocabularyManagementCopy.validationEmptyWritten
        case .forbiddenWrittenCharacter: return AmiVoiceVocabularyManagementCopy.validationForbiddenWritten
        case .missingSpoken: return AmiVoiceVocabularyManagementCopy.validationEmptyReading
        case .invalidSpoken: return AmiVoiceVocabularyManagementCopy.validationInvalidReading
        case .longReading: return AmiVoiceVocabularyManagementCopy.validationLongReading
        case .duplicatePair: return AmiVoiceVocabularyManagementCopy.validationDuplicatePair
        case .shortReading(let mora): return AmiVoiceVocabularyManagementCopy.warningShortReading(mora)
        case .duplicateReading(let reading, let surface):
            return AmiVoiceVocabularyManagementCopy.warningDuplicateReading(reading: reading, surface: surface)
        case .writtenSpaceNormalized: return AmiVoiceVocabularyManagementCopy.noticeWrittenSpace
        }
    }
}

/// Review-queue helper: the pipeline hold reason plus the suggested reading
/// the panel offers as a chip. `existingSurface` fills the duplicate-reading
/// copy when the colliding entry can be resolved.
public struct AmiVoiceVocabularyReviewInfo: Equatable, Sendable {
    public var reason: VocabularyHoldReason?
    public var reasonText: String
    public var suggestedReading: String?
    public var sourceFragment: String?

    public init(reason: VocabularyHoldReason?, reasonText: String, suggestedReading: String?, sourceFragment: String?) {
        self.reason = reason
        self.reasonText = reasonText
        self.suggestedReading = suggestedReading
        self.sourceFragment = sourceFragment
    }
}

/// Quarantine evidence surfaced next to auto-disabled rows (B-3 bookkeeping).
public struct AmiVoiceVocabularyQuarantineInfo: Equatable, Sendable {
    public var occurrenceCount: Int
    public var windowDays: Int
    public var occurrenceTimestamps: [Date]
    public var detail: String?

    public init(occurrenceCount: Int, windowDays: Int, occurrenceTimestamps: [Date], detail: String?) {
        self.occurrenceCount = occurrenceCount
        self.windowDays = windowDays
        self.occurrenceTimestamps = occurrenceTimestamps
        self.detail = detail
    }
}

public enum AmiVoiceVocabularyDeleteAllScope: String, Sendable {
    case serverOnly
    case localAndServer
}

public enum AmiVoiceVocabularySaveMode: String, Sendable {
    case sync
    case excluded
}

/// What a save attempt produced. `saved` is only true when no blocking issue
/// prevented the upsert from reaching the store.
public struct AmiVoiceVocabularySaveOutcome: Equatable, Sendable {
    public var saved: Bool
    public var entryID: UUID?
    public var issues: [AmiVoiceVocabularyFormIssue]
    public var syncOutcome: AmiVoiceDictionarySyncOutcome?

    public init(saved: Bool, entryID: UUID?, issues: [AmiVoiceVocabularyFormIssue], syncOutcome: AmiVoiceDictionarySyncOutcome?) {
        self.saved = saved
        self.entryID = entryID
        self.issues = issues
        self.syncOutcome = syncOutcome
    }
}

/// B-4 wiring layer: every user action on the vocabulary management surface
/// funnels through the public B-1/B-3 operations. The layer adds only
/// presentation aggregation (filters, summary, review/quarantine derivation),
/// consent persistence and form validation — no state-machine logic of its
/// own beyond the documented delete row-removal fallback (see `deleteEntry`).
public final class AmiVoiceVocabularyManagement: @unchecked Sendable {
    private let store: AmiVoiceDictionarySyncStore
    private let engine: AmiVoiceDictionarySyncEngine
    private let monitor: AmiVoiceDictionarySyncMonitor
    public let consentStore: AmiVoiceDictionarySyncConsentStore
    private let now: @Sendable () -> Date

    public init(
        store: AmiVoiceDictionarySyncStore,
        engine: AmiVoiceDictionarySyncEngine,
        monitor: AmiVoiceDictionarySyncMonitor,
        consentStore: AmiVoiceDictionarySyncConsentStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.engine = engine
        self.monitor = monitor
        self.consentStore = consentStore
        self.now = now
    }

    // MARK: - Consent

    /// The consent gate: a recorded consent is required before auto-sync may
    /// be turned on. The absence of a record always blocks enabling.
    public var hasRecordedSyncConsent: Bool {
        consentStore.recordedConsent != nil
    }

    /// Called from the consent panel's agree button. Persists the record with
    /// the copy version that was shown, so a later copy revision can require
    /// re-consent by comparing `copyIdentifier`.
    @discardableResult
    public func recordSyncConsent() -> AmiVoiceDictionarySyncConsent {
        consentStore.record(copyIdentifier: AmiVoiceVocabularyManagementCopy.consentCopyIdentifier, at: now())
    }

    // MARK: - Display surfaces

    /// Entries with their per-profile engine state and B-3 record. Rows that
    /// have no state for `key` are kept for `.all` so foreign-profile entries
    /// are still visible; the filters never match them.
    public func rows(
        for key: AmiVoiceDictionaryProfileKey,
        filter: AmiVoiceVocabularyListFilter,
        query: String
    ) -> [AmiVoiceVocabularyRow] {
        let entries = store.loadEntries()
        let monitoring = store.loadMonitoringRecords()
        let monitoringByID = Dictionary(
            monitoring.filter { $0.profileKey == key }.map { ($0.entryID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [AmiVoiceVocabularyRow] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            let engineState = entry.engineState(for: key)
            if let state = engineState?.state {
                guard filter.matches(state) else { continue }
            } else if filter != .all {
                continue
            }
            if !trimmedQuery.isEmpty {
                let haystacks = [entry.written, entry.spoken, entry.alternativeWritten]
                    .compactMap { $0 }
                guard haystacks.contains(where: { $0.localizedStandardContains(trimmedQuery) }) else {
                    continue
                }
            }
            rows.append(AmiVoiceVocabularyRow(
                entry: entry,
                engineState: engineState,
                monitoringRecord: monitoringByID[entry.id]
            ))
        }
        // OQ-06 simplification: manual/protected first, then createdAt newest.
        rows.sort { lhs, rhs in
            if lhs.entry.isProtected != rhs.entry.isProtected {
                return lhs.entry.isProtected && !rhs.entry.isProtected
            }
            if lhs.entry.createdAt != rhs.entry.createdAt {
                return lhs.entry.createdAt > rhs.entry.createdAt
            }
            return lhs.entry.id.uuidString < rhs.entry.id.uuidString
        }
        return rows
    }

    public func summary(for key: AmiVoiceDictionaryProfileKey) -> AmiVoiceVocabularyListSummary {
        var total = 0
        var active = 0
        var synced = 0
        var pending = 0
        var disabled = 0
        var failed = 0
        for entry in store.loadEntries() {
            guard let state = entry.engineState(for: key)?.state else { continue }
            total += 1
            if state.participatesInSnapshot { active += 1 }
            switch state {
            case .pendingReview, .candidate: pending += 1
            case .autoDisabled: disabled += 1
            case .syncFailed: failed += 1
            case .autoSynced: synced += 1
            case .readyToSync, .archived, .ignored: break
            }
        }
        return AmiVoiceVocabularyListSummary(
            totalCount: total,
            activeCount: active,
            syncedCount: synced,
            attentionCount: pending + disabled + failed,
            pendingReviewCount: pending,
            autoDisabledCount: disabled,
            syncFailedCount: failed,
            softCapExceeded: active >= AmiVoiceDictionarySyncPolicy.softEntryLimit,
            hardCapReached: active >= AmiVoiceDictionarySyncPolicy.hardEntryLimit
        )
    }

    /// Re-derives the hold reason and the suggested reading for a pending
    /// entry by re-running the B-2 pipeline on its source LearnedTerm. The
    /// entry row itself does not store the reason; the pipeline is
    /// deterministic, so re-running reproduces it.
    public func reviewInfo(
        for entry: AmiVoiceDictionaryEntry,
        for key: AmiVoiceDictionaryProfileKey,
        learnedTerms: [LearnedTerm],
        allEntries: [AmiVoiceDictionaryEntry]? = nil
    ) -> AmiVoiceVocabularyReviewInfo {
        guard let term = learnedTerms.first(where: { $0.id == entry.id }) else {
            return AmiVoiceVocabularyReviewInfo(
                reason: nil,
                reasonText: AmiVoiceVocabularyManagementCopy.reviewReasonText(
                    for: nil, reading: entry.spoken, existingSurface: nil, moraCount: 0
                ),
                suggestedReading: entry.spoken,
                sourceFragment: nil
            )
        }
        // Seed the duplicate-reading guard with the profile's current syncable
        // entries so the re-run can reproduce `.duplicateReadingCollision`,
        // the same way B-2's coordinator sees the registered set.
        let registered = (allEntries ?? store.loadEntries()).compactMap {
            other -> (written: String, reading: String)? in
            guard other.id != entry.id,
                  other.engineState(for: key)?.state.participatesInSnapshot == true,
                  let spoken = other.spoken else { return nil }
            return (other.written, spoken)
        }
        let pipeline = VocabularyCandidatePipeline(registeredEntries: registered)
        let outcome = pipeline.process(term)
        var holdReason: VocabularyHoldReason?
        var suggested: String? = entry.spoken
        if case .pendingReview(let reason, let candidate) = outcome {
            holdReason = reason
            suggested = candidate.reading.isEmpty ? entry.spoken : candidate.reading
        } else if case .ready(let candidate) = outcome {
            suggested = candidate.reading.isEmpty ? entry.spoken : candidate.reading
        }
        var existingSurface: String?
        if holdReason == .duplicateReadingCollision, let reading = suggested {
            let canonical = VocabularyReadingGeneration.canonicalHiragana(reading)
            existingSurface = (allEntries ?? store.loadEntries()).first { other in
                other.id != entry.id
                    && LearnedTermPolicy.normalized(other.written) != LearnedTermPolicy.normalized(entry.written)
                    && other.spoken.map { VocabularyReadingGeneration.canonicalHiragana($0) == canonical } == true
            }?.written
        }
        let mora = suggested.map { VocabularyReadingGeneration.moraCount(of: $0) } ?? 0
        return AmiVoiceVocabularyReviewInfo(
            reason: holdReason,
            reasonText: AmiVoiceVocabularyManagementCopy.reviewReasonText(
                for: holdReason, reading: suggested, existingSurface: existingSurface, moraCount: mora
            ),
            suggestedReading: suggested,
            sourceFragment: term.originalFragment
        )
    }

    /// B-3 quarantine evidence for an auto-disabled row: the recorded
    /// reverse-correction count, window and timestamps that caused it. The
    /// row carries the monitoring record joined during `rows(for:filter:query:)`.
    public func quarantineInfo(for row: AmiVoiceVocabularyRow) -> AmiVoiceVocabularyQuarantineInfo? {
        if let transition = row.monitoringRecord?.lastAutoTransition {
            return AmiVoiceVocabularyQuarantineInfo(
                occurrenceCount: transition.occurrenceCount,
                windowDays: transition.windowDays,
                occurrenceTimestamps: transition.occurrenceTimestamps,
                detail: row.engineState?.lastErrorDetail
            )
        }
        guard let detail = row.engineState?.lastErrorDetail else { return nil }
        return AmiVoiceVocabularyQuarantineInfo(
            occurrenceCount: 0,
            windowDays: 0,
            occurrenceTimestamps: [],
            detail: detail
        )
    }

    /// LearnedTerm backing an entry, if this entry came from the correction
    /// pipeline (entry ids reuse the LearnedTerm id). Used by the edit form's
    /// read-only provenance field.
    public func learningSource(
        for entry: AmiVoiceDictionaryEntry,
        learnedTerms: [LearnedTerm]
    ) -> LearnedTerm? {
        learnedTerms.first { $0.id == entry.id }
    }

    /// Snapshot history for `key`, newest first (B-3's append-only record).
    /// The sync store read is identical to the engine's `syncSnapshots`
    /// surface; the synchronous variant exists so views render without hops.
    public func snapshotHistory(for key: AmiVoiceDictionaryProfileKey) -> [AmiVoiceDictionarySyncSnapshot] {
        store.snapshots(for: key)
    }

    /// The newest snapshot for `key` that did not reflect — drives the
    /// failed-reflection warning and the retry affordance.
    public func unreflectedSnapshot(for key: AmiVoiceDictionaryProfileKey) -> AmiVoiceDictionarySyncSnapshot? {
        store.snapshots(for: key).first { $0.status == .failed }
    }

    // MARK: - Form validation

    /// Normalizes the written form the way the form promises: half-width
    /// spaces become underscores. `|` and `:` stay untouched and are reported
    /// as blocking issues instead of being silently rewritten.
    public static func normalizedWrittenForm(_ written: String) -> String {
        written.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
    }

    /// GD-469 03 §3 validation. Blocking issues prevent the save; warnings are
    /// returned for display but allow it.
    public func validateForm(
        written: String,
        spoken: String?,
        family: AmiVoiceDictionaryEngineFamily,
        excluding entryID: UUID?,
        existingEntries: [AmiVoiceDictionaryEntry]? = nil
    ) -> [AmiVoiceVocabularyFormIssue] {
        var issues: [AmiVoiceVocabularyFormIssue] = []
        let normalizedWritten = Self.normalizedWrittenForm(written)
        let trimmedSpoken = spoken?.trimmingCharacters(in: .whitespacesAndNewlines)

        if written.contains(" ") {
            issues.append(.writtenSpaceNormalized)
        }
        if normalizedWritten.isEmpty {
            issues.append(.emptyWritten)
        } else if normalizedWritten.contains("|") || normalizedWritten.contains(":") {
            issues.append(.forbiddenWrittenCharacter)
        }

        let entries = existingEntries ?? store.loadEntries()
        let normalizedWrittenKey = LearnedTermPolicy.normalized(normalizedWritten)
        let normalizedSpoken = trimmedSpoken.map { LearnedTermPolicy.normalized($0) }
        let canonicalSpoken = trimmedSpoken.map { VocabularyReadingGeneration.canonicalHiragana($0) }

        if family == .hybrid {
            guard let trimmedSpoken, !trimmedSpoken.isEmpty else {
                issues.append(.missingSpoken)
                return dedupe(issues)
            }
            if !VocabularyReadingGeneration.isValidHybridReading(trimmedSpoken) {
                issues.append(.invalidSpoken)
            }
            let mora = VocabularyReadingGeneration.moraCount(of: trimmedSpoken)
            if mora > 20 {
                issues.append(.longReading)
            } else if mora <= 2 {
                issues.append(.shortReading(mora: mora))
            }
        }

        for other in entries where other.id != entryID {
            let sameWritten = LearnedTermPolicy.normalized(other.written) == normalizedWrittenKey
            if sameWritten,
               normalizedSpoken != nil,
               other.spoken.map({ LearnedTermPolicy.normalized($0) == normalizedSpoken! }) == true {
                issues.append(.duplicatePair)
                break
            }
        }
        if family == .hybrid, let canonicalSpoken, !canonicalSpoken.isEmpty {
            if let colliding = entries.first(where: { other in
                other.id != entryID
                    && LearnedTermPolicy.normalized(other.written) != normalizedWrittenKey
                    && other.spoken.map { VocabularyReadingGeneration.canonicalHiragana($0) == canonicalSpoken } == true
            }) {
                issues.append(.duplicateReading(reading: trimmedSpoken ?? "", existingSurface: colliding.written))
            }
        }
        return dedupe(issues)
    }

    private func dedupe(_ issues: [AmiVoiceVocabularyFormIssue]) -> [AmiVoiceVocabularyFormIssue] {
        var seen = Set<String>()
        return issues.filter { seen.insert(String(describing: $0)).inserted }
    }

    // MARK: - Actions (all funnel through B-1/B-3 public operations)

    /// Manual add/edit. The saved entry is always `isProtected` (manual and
    /// approved rows are the protected pool), the monitor's counters are reset
    /// through its B-3 hook, and B-1's user-action sync fires immediately.
    /// `alternativeSpoken` is GD-469 02's 「別の読みを追加」: a non-empty value
    /// stores one extra sibling entry (same 表記, the other reading) through
    /// the same upsert path, so both land in the single immediate sync.
    public func saveManualEntry(
        id: UUID?,
        written: String,
        spoken: String?,
        className: String?,
        mode: AmiVoiceVocabularySaveMode,
        alternativeSpoken: String? = nil,
        for key: AmiVoiceDictionaryProfileKey
    ) async -> AmiVoiceVocabularySaveOutcome {
        let family = AmiVoiceDictionaryEngineFamily(engine: key.engine)
        let trimmedSpoken = spoken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlt = alternativeSpoken?.trimmingCharacters(in: .whitespacesAndNewlines)
        // An alternative reading identical to the primary collapses to the
        // primary entry only; it never makes a sibling.
        let wantsAlternative = family == .hybrid
            && trimmedAlt?.isEmpty == false
            && LearnedTermPolicy.normalized(trimmedAlt ?? "") != LearnedTermPolicy.normalized(trimmedSpoken ?? "")
        var issues = validateForm(
            written: written,
            spoken: spoken,
            family: family,
            excluding: id
        )
        if wantsAlternative {
            issues = dedupe(issues + validateForm(
                written: written,
                spoken: trimmedAlt,
                family: family,
                excluding: id
            ))
        }
        guard !issues.contains(where: \.isBlocking) else {
            return AmiVoiceVocabularySaveOutcome(saved: false, entryID: nil, issues: issues, syncOutcome: nil)
        }
        let trimmedClass = className?.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = store.loadEntries()
        let existing = id.flatMap { target in rows.first(where: { $0.id == target }) }
        var entry = AmiVoiceDictionaryEntry(
            id: existing?.id ?? UUID(),
            written: Self.normalizedWrittenForm(written),
            spoken: trimmedSpoken?.isEmpty == true ? nil : trimmedSpoken,
            className: trimmedClass?.isEmpty == true ? nil : trimmedClass,
            alternativeWritten: existing?.alternativeWritten,
            biasing: existing?.biasing,
            isProtected: true,
            createdAt: existing?.createdAt ?? now()
        )
        entry.engineStates = existing?.engineStates ?? []
        let state: AmiVoiceDictionaryEntryState = mode == .sync ? .readyToSync : .ignored
        guard await engine.upsertEntry(entry, for: key, state: state) else {
            return AmiVoiceVocabularySaveOutcome(saved: false, entryID: entry.id, issues: issues, syncOutcome: nil)
        }
        await monitor.resetCorrectionTracking(entryID: entry.id, for: key)
        if wantsAlternative, let trimmedAlt {
            var sibling = AmiVoiceDictionaryEntry(
                written: entry.written,
                spoken: trimmedAlt,
                className: entry.className,
                isProtected: true,
                createdAt: now()
            )
            sibling.engineStates = []
            if await engine.upsertEntry(sibling, for: key, state: state) {
                await monitor.resetCorrectionTracking(entryID: sibling.id, for: key)
            }
        }
        let outcome = await engine.syncNow(for: key, trigger: .userAction)
        return AmiVoiceVocabularySaveOutcome(saved: true, entryID: entry.id, issues: issues, syncOutcome: outcome)
    }

    /// Approve a pending-review entry with an optional reading correction:
    /// the entry returns to the syncable set as protected, counters reset, and
    /// an immediate sync fires.
    @discardableResult
    public func approveReviewEntry(
        id: UUID,
        reading: String?,
        for key: AmiVoiceDictionaryProfileKey
    ) async -> Bool {
        guard var entry = store.loadEntries().first(where: { $0.id == id }) else { return false }
        if let reading {
            let trimmed = reading.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.spoken = trimmed.isEmpty ? nil : trimmed
        }
        entry.isProtected = true
        guard await engine.upsertEntry(entry, for: key, state: .readyToSync) else { return false }
        await monitor.resetCorrectionTracking(entryID: id, for: key)
        _ = await engine.syncNow(for: key, trigger: .userAction)
        return true
    }

    /// Reject a review entry: `.ignored` is the terminal non-syncing state —
    /// B-1/B-2 guarantee it never auto-revives.
    @discardableResult
    public func rejectReviewEntry(id: UUID, for key: AmiVoiceDictionaryProfileKey) async -> Bool {
        await engine.transitionEntry(id: id, for: key, to: .ignored)
    }

    /// Exclude （無視） a synced entry: removes it from the server set through
    /// B-1's dirty+immediate-sync path and blocks auto re-registration.
    @discardableResult
    public func excludeEntry(id: UUID, for key: AmiVoiceDictionaryProfileKey) async -> Bool {
        await engine.transitionEntry(id: id, for: key, to: .ignored)
    }

    /// Undo an exclusion or restore an auto-disabled entry: back to the
    /// syncable set, counter reset via the B-3 hook, immediate sync.
    @discardableResult
    public func restoreEntry(id: UUID, for key: AmiVoiceDictionaryProfileKey) async -> Bool {
        guard await engine.transitionEntry(id: id, for: key, to: .readyToSync) else { return false }
        await monitor.resetCorrectionTracking(entryID: id, for: key)
        _ = await engine.syncNow(for: key, trigger: .userAction)
        return true
    }

    /// Per-entry delete. B-1 exposes no dedicated row-removal op, so the
    /// closest exposed path is used: the learned term is removed first (so the
    /// B-2 reconcile cannot recreate the row), the row is dropped through the
    /// store's public `saveEntries`, and the removal is pushed via B-1's
    /// immediate user-action sync — or the empty-allowed send when this was
    /// the last participating word (`resyncAfterMonitoredQuarantine` is the
    /// exposed "clear the server set now" path).
    public func deleteEntry(
        id: UUID,
        for key: AmiVoiceDictionaryProfileKey,
        removeLearnedTerms: @MainActor @Sendable (Set<UUID>) -> Void = { _ in }
    ) async -> AmiVoiceDictionarySyncOutcome {
        await removeLearnedTerms([id])
        var rows = store.loadEntries()
        rows.removeAll { $0.id == id }
        _ = store.saveEntries(rows)
        let remainingParticipates = rows.contains {
            $0.engineState(for: key)?.state.participatesInSnapshot == true
        }
        if remainingParticipates {
            return await engine.syncNow(for: key, trigger: .userAction)
        }
        return await engine.resyncAfterMonitoredQuarantine(for: key)
    }

    /// Delete-all: for each configured profile (stored profiles plus the
    /// current one), B-1's `deleteAllServerWords` sends the empty-array
    /// overwrite. Per the copy, automatic sync is turned OFF afterwards.
    /// `.localAndServer` additionally clears the local entry rows. With sync
    /// OFF the engine returns `.disabled` for every profile — the operation is
    /// local-only by construction.
    @discardableResult
    public func deleteAll(
        scope: AmiVoiceVocabularyDeleteAllScope,
        currentKey: AmiVoiceDictionaryProfileKey
    ) async -> [AmiVoiceDictionaryProfileKey: AmiVoiceDictionarySyncOutcome] {
        if scope == .localAndServer {
            _ = store.saveEntries([])
        }
        var keys = Set(store.loadProfiles().map(\.key))
        keys.insert(currentKey)
        var outcomes: [AmiVoiceDictionaryProfileKey: AmiVoiceDictionarySyncOutcome] = [:]
        for key in keys {
            outcomes[key] = await engine.deleteAllServerWords(for: key)
        }
        await engine.setAutomaticSyncEnabled(false)
        return outcomes
    }

    // MARK: - Sync triggers and rollback

    public func syncNow(for key: AmiVoiceDictionaryProfileKey) async -> AmiVoiceDictionarySyncOutcome {
        await engine.syncNow(for: key, trigger: .userAction)
    }

    public func syncSnapshots(for key: AmiVoiceDictionaryProfileKey) async -> [AmiVoiceDictionarySyncSnapshot] {
        await engine.syncSnapshots(for: key)
    }

    public func rollback(for key: AmiVoiceDictionaryProfileKey, toSnapshotID: UUID) async -> AmiVoiceDictionaryRollbackOutcome {
        await engine.rollbackProfile(for: key, toSnapshotID: toSnapshotID)
    }

    public func retryPendingReflection(for key: AmiVoiceDictionaryProfileKey) async -> AmiVoiceDictionarySyncOutcome {
        await engine.retryPendingRollbackReflection(for: key)
    }

    public func status(for key: AmiVoiceDictionaryProfileKey) async -> AmiVoiceDictionarySyncStatus {
        await engine.status(for: key)
    }

    public func configuredProfileKeys(currentKey: AmiVoiceDictionaryProfileKey) -> [AmiVoiceDictionaryProfileKey] {
        var keys = Set(store.loadProfiles().map(\.key))
        keys.insert(currentKey)
        return keys.sorted { $0.storageKey < $1.storageKey }
    }

    // MARK: - Diff helpers for the rollback dialog

    /// Derives the added/updated/removed counts the rollback confirm copy
    /// asks for, by diffing two snapshots' sent sets.
    public static func snapshotDiff(
        newer: AmiVoiceDictionarySyncSnapshot,
        older: AmiVoiceDictionarySyncSnapshot
    ) -> (added: Int, updated: Int, removed: Int) {
        let olderByID = Dictionary(uniqueKeysWithValues: older.entries.map { ($0.entryID, $0) })
        let newerByID = Dictionary(uniqueKeysWithValues: newer.entries.map { ($0.entryID, $0) })
        var added = 0
        var updated = 0
        var removed = 0
        for entry in newer.entries {
            if let previous = olderByID[entry.entryID] {
                if previous.written != entry.written
                    || previous.spoken != entry.spoken
                    || previous.className != entry.className
                    || previous.alternativeWritten != entry.alternativeWritten
                    || previous.biasing != entry.biasing {
                    updated += 1
                }
            } else {
                added += 1
            }
        }
        for entry in older.entries where newerByID[entry.entryID] == nil {
            removed += 1
        }
        return (added, updated, removed)
    }
}
