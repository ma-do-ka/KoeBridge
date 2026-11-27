import Foundation

/// Provisional B-3 thresholds (dispatcher U-03 / U-06). Every monitoring and
/// rollback constant lives in this one named place so tuning stays a
/// single-edit change.
public enum AmiVoiceDictionaryMonitoringPolicy {
    /// Re-correction: a new LearnedTerm repeating the entry's
    /// (originalFragment -> term) pair. Reaching the threshold inside the
    /// window after the entry's last successful sync moves it to review.
    public static let reCorrectionThreshold = 3
    public static let reCorrectionWindow: TimeInterval = 14 * 24 * 60 * 60
    /// Reverse-correction: a new LearnedTerm rewriting the synced written form
    /// to a different text. Reaching the threshold inside the window quarantines
    /// the entry; a single occurrence never quarantines.
    public static let reverseCorrectionThreshold = 2
    public static let reverseCorrectionWindow: TimeInterval = 7 * 24 * 60 * 60
    /// A manual edit or re-approval inside this interval suppresses automatic
    /// quarantine (the occurrences are still counted).
    public static let manualEditGuardInterval: TimeInterval = 24 * 60 * 60
    /// Snapshot retention per engine profile (U-03). Oldest beyond the limit
    /// are pruned on append; there is no pinning.
    public static let snapshotRetentionLimit = 30
    /// Observed-correction bookkeeping only needs to outlive the largest
    /// counting window; older rows can never produce a new occurrence.
    public static let observedCorrectionRetention: TimeInterval = reCorrectionWindow
}

/// Trigger provenance recorded on each snapshot. Mapped from
/// `AmiVoiceDictionarySyncTrigger` so history stays append-only and honest.
public enum AmiVoiceDictionarySnapshotTrigger: String, Codable, Sendable {
    /// Debounced or backoff-retry sends.
    case normal
    /// Immediate sends (manual sync, monitored-transition push, delete-all).
    case manualImmediate = "manual_immediate"
    /// The send a rollback issued for its restored set.
    case rollback
    /// Launch consistency pass uploads.
    case launchRestore = "launch_restore"
}

public enum AmiVoiceDictionarySnapshotStatus: String, Codable, Sendable {
    /// The overwrite POST was accepted by the server.
    case reflected
    /// The send was attempted (or required for a pending set) but did not
    /// complete.
    case failed
}

/// One entry of the exact syncable set a sync sent, with enough per-entry
/// state to restore it into the local store on rollback.
public struct AmiVoiceDictionarySnapshotEntry: Codable, Equatable, Sendable {
    public var entryID: UUID
    public var written: String
    public var spoken: String?
    public var className: String?
    public var alternativeWritten: String?
    public var biasing: Double?
    public var isProtected: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var stateAtSend: AmiVoiceDictionaryEntryState

    public init(
        entryID: UUID,
        written: String,
        spoken: String? = nil,
        className: String? = nil,
        alternativeWritten: String? = nil,
        biasing: Double? = nil,
        isProtected: Bool = false,
        createdAt: Date,
        updatedAt: Date,
        stateAtSend: AmiVoiceDictionaryEntryState
    ) {
        self.entryID = entryID
        self.written = written
        self.spoken = spoken
        self.className = className
        self.alternativeWritten = alternativeWritten
        self.biasing = biasing
        self.isProtected = isProtected
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.stateAtSend = stateAtSend
    }
}

/// Per-profile snapshot of the syncable set a completed sync sent. Snapshots
/// are append-only history: rollback adds a new one and never rewrites or
/// deletes existing rows.
public struct AmiVoiceDictionarySyncSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var createdAt: Date
    public var profileKey: AmiVoiceDictionaryProfileKey
    /// Server-side profile identifier used for the send, when one exists.
    public var profileID: String?
    public var trigger: AmiVoiceDictionarySnapshotTrigger
    public var status: AmiVoiceDictionarySnapshotStatus
    public var entries: [AmiVoiceDictionarySnapshotEntry]
    /// Set on rollback snapshots: the snapshot the restored set came from.
    public var rollbackSourceSnapshotID: UUID?

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        profileKey: AmiVoiceDictionaryProfileKey,
        profileID: String? = nil,
        trigger: AmiVoiceDictionarySnapshotTrigger,
        status: AmiVoiceDictionarySnapshotStatus,
        entries: [AmiVoiceDictionarySnapshotEntry],
        rollbackSourceSnapshotID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.profileKey = profileKey
        self.profileID = profileID
        self.trigger = trigger
        self.status = status
        self.entries = entries
        self.rollbackSourceSnapshotID = rollbackSourceSnapshotID
    }
}

/// Evidence recorded when monitoring moves an entry out of the synced set.
public struct AmiVoiceDictionaryMonitoringTransition: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case reCorrection = "re_correction"
        case reverseCorrection = "reverse_correction"
    }

    public var entryID: UUID
    public var kind: Kind
    public var toState: AmiVoiceDictionaryEntryState
    public var at: Date
    public var occurrenceCount: Int
    public var windowDays: Int
    public var occurrenceTimestamps: [Date]

    public init(
        entryID: UUID,
        kind: Kind,
        toState: AmiVoiceDictionaryEntryState,
        at: Date,
        occurrenceCount: Int,
        windowDays: Int,
        occurrenceTimestamps: [Date]
    ) {
        self.entryID = entryID
        self.kind = kind
        self.toState = toState
        self.at = at
        self.occurrenceCount = occurrenceCount
        self.windowDays = windowDays
        self.occurrenceTimestamps = occurrenceTimestamps
    }
}

/// Per (entry, engine profile) monitoring bookkeeping. Rows persist with the
/// sync store; a corrupt monitoring store fails safe by resetting counters
/// while leaving dictionary entries untouched.
public struct AmiVoiceDictionaryMonitoringRecord: Codable, Equatable, Sendable {
    public var entryID: UUID
    public var profileKey: AmiVoiceDictionaryProfileKey
    /// Pre-correction fragment that produced the entry, derived from the
    /// LearnedTerm store. Needed for re-correction pair matching; nil while
    /// no matching source term is known.
    public var originalFragment: String?
    public var reCorrectionTimestamps: [Date]
    public var reverseCorrectionTimestamps: [Date]
    /// Last manual action on the entry (content edit or explicit reset). Drives
    /// the 24-hour quarantine guard.
    public var lastManualEditAt: Date?
    public var lastObservedState: AmiVoiceDictionaryEntryState?
    public var lastObservedUpdatedAt: Date?
    public var lastAutoTransition: AmiVoiceDictionaryMonitoringTransition?

    public init(
        entryID: UUID,
        profileKey: AmiVoiceDictionaryProfileKey,
        originalFragment: String? = nil,
        reCorrectionTimestamps: [Date] = [],
        reverseCorrectionTimestamps: [Date] = [],
        lastManualEditAt: Date? = nil,
        lastObservedState: AmiVoiceDictionaryEntryState? = nil,
        lastObservedUpdatedAt: Date? = nil,
        lastAutoTransition: AmiVoiceDictionaryMonitoringTransition? = nil
    ) {
        self.entryID = entryID
        self.profileKey = profileKey
        self.originalFragment = originalFragment
        self.reCorrectionTimestamps = reCorrectionTimestamps
        self.reverseCorrectionTimestamps = reverseCorrectionTimestamps
        self.lastManualEditAt = lastManualEditAt
        self.lastObservedState = lastObservedState
        self.lastObservedUpdatedAt = lastObservedUpdatedAt
        self.lastAutoTransition = lastAutoTransition
    }
}

/// A LearnedTerm the monitor has already seen. `LearnedTermPolicy.saving`
/// rewrites an existing row (same ID, same createdAt) when the corrected term
/// matches a previous record, so a repeated correction may appear as a pair
/// change rather than a new ID. The pair fingerprint detects that rewrite;
/// the corrected text itself is never duplicated into monitoring storage —
/// only a deterministic FNV-1a fingerprint of the normalized pair persists.
public struct AmiVoiceDictionaryObservedCorrection: Codable, Equatable, Sendable {
    public var termID: UUID
    public var createdAt: Date
    public var pairFingerprint: String
    public var lastObservedAt: Date

    public init(termID: UUID, createdAt: Date, pairFingerprint: String, lastObservedAt: Date) {
        self.termID = termID
        self.createdAt = createdAt
        self.pairFingerprint = pairFingerprint
        self.lastObservedAt = lastObservedAt
    }
}

public enum AmiVoiceDictionaryRollbackResultKind: String, Equatable, Sendable {
    /// Local set restored and the overwrite send was reflected.
    case applied
    /// Local set restored but the send did not complete; the pending
    /// reflection retries on the next normal sync trigger or via the explicit
    /// retry entry point (U-04).
    case appliedReflectionPending = "applied_reflection_pending"
    case snapshotNotFound = "snapshot_not_found"
    case storeFailure = "store_failure"
}

public struct AmiVoiceDictionaryRollbackOutcome: Equatable, Sendable {
    public var kind: AmiVoiceDictionaryRollbackResultKind
    public var sourceSnapshotID: UUID
    /// Newly appended rollback snapshot (nil when the restore itself failed).
    public var rollbackSnapshotID: UUID?
    public var syncResult: AmiVoiceDictionarySyncResultKind?
    public var restoredEntryCount: Int
    public var recreatedEntryCount: Int
    public var archivedEntryCount: Int
    public var keptIgnoredCount: Int
    public var timestamp: Date

    public init(
        kind: AmiVoiceDictionaryRollbackResultKind,
        sourceSnapshotID: UUID,
        rollbackSnapshotID: UUID? = nil,
        syncResult: AmiVoiceDictionarySyncResultKind? = nil,
        restoredEntryCount: Int = 0,
        recreatedEntryCount: Int = 0,
        archivedEntryCount: Int = 0,
        keptIgnoredCount: Int = 0,
        timestamp: Date
    ) {
        self.kind = kind
        self.sourceSnapshotID = sourceSnapshotID
        self.rollbackSnapshotID = rollbackSnapshotID
        self.syncResult = syncResult
        self.restoredEntryCount = restoredEntryCount
        self.recreatedEntryCount = recreatedEntryCount
        self.archivedEntryCount = archivedEntryCount
        self.keptIgnoredCount = keptIgnoredCount
        self.timestamp = timestamp
    }
}

public struct AmiVoiceDictionaryMonitoringReport: Equatable, Sendable {
    /// False when the opt-in sync setting is off; the pass then only marks
    /// corrections as observed and performs no counting or transitions.
    public var monitoringActive: Bool
    public var evaluatedEntryCount: Int
    public var countedOccurrenceCount: Int
    public var transitions: [AmiVoiceDictionaryMonitoringTransition]

    public init(
        monitoringActive: Bool,
        evaluatedEntryCount: Int,
        countedOccurrenceCount: Int,
        transitions: [AmiVoiceDictionaryMonitoringTransition]
    ) {
        self.monitoringActive = monitoringActive
        self.evaluatedEntryCount = evaluatedEntryCount
        self.countedOccurrenceCount = countedOccurrenceCount
        self.transitions = transitions
    }
}

/// Stage 6 monitoring: watches new LearnedTerm corrections against the entries
/// currently synced for one engine profile. Threshold breaches move entries to
/// `pending_review` (re-correction) or `auto_disabled` (reverse-correction)
/// through the sync engine, which owns the store writes and the immediate
/// re-sync trigger. The monitor owns only its own bookkeeping stores.
public actor AmiVoiceDictionarySyncMonitor {
    private let store: AmiVoiceDictionarySyncStore
    private let engine: AmiVoiceDictionarySyncEngine
    private let now: @Sendable () -> Date

    public init(
        store: AmiVoiceDictionarySyncStore,
        engine: AmiVoiceDictionarySyncEngine,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.engine = engine
        self.now = now
    }

    /// Evaluates every currently-synced entry for `key` against LearnedTerms
    /// not seen before. Callers pass the complete learned-terms list: unseen
    /// records are the correction signal, and the full list also supplies each
    /// entry's provenance (the source term whose normalized `term` equals the
    /// entry's `written`). Corrections observed while sync is off are marked
    /// seen but never counted, so enabling sync cannot replay stale signals.
    @discardableResult
    public func observe(
        learnedTerms: [LearnedTerm],
        for key: AmiVoiceDictionaryProfileKey
    ) async -> AmiVoiceDictionaryMonitoringReport {
        let evaluatedAt = now()
        let observed = store.loadObservedCorrections()
        var observedByID = Dictionary(
            observed.map { ($0.termID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // One event per LearnedTerm that is new to the monitor or whose pair
        // changed since the last pass. New rows are dated by their own
        // createdAt; a rewritten row keeps its original createdAt, so its
        // occurrence is dated by this evaluation.
        var events: [(term: LearnedTerm, occurredAt: Date)] = []
        for term in learnedTerms {
            let fingerprint = Self.pairFingerprint(term: term.term, fragment: term.originalFragment)
            if var seen = observedByID[term.id] {
                guard seen.pairFingerprint != fingerprint else { continue }
                seen.pairFingerprint = fingerprint
                seen.lastObservedAt = evaluatedAt
                observedByID[term.id] = seen
                events.append((term, evaluatedAt))
            } else {
                observedByID[term.id] = AmiVoiceDictionaryObservedCorrection(
                    termID: term.id,
                    createdAt: term.createdAt,
                    pairFingerprint: fingerprint,
                    lastObservedAt: evaluatedAt
                )
                events.append((term, term.createdAt))
            }
        }
        events.sort { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
            return lhs.term.id.uuidString < rhs.term.id.uuidString
        }
        if !events.isEmpty {
            let retentionCutoff = evaluatedAt.addingTimeInterval(-AmiVoiceDictionaryMonitoringPolicy.observedCorrectionRetention)
            let updated = observedByID.values.filter { $0.lastObservedAt >= retentionCutoff }
            _ = store.saveObservedCorrections(updated.sorted { $0.createdAt < $1.createdAt })
        }

        guard store.automaticSyncEnabled else {
            return AmiVoiceDictionaryMonitoringReport(
                monitoringActive: false,
                evaluatedEntryCount: 0,
                countedOccurrenceCount: 0,
                transitions: []
            )
        }

        var records = store.loadMonitoringRecords()
        var recordsChanged = false
        let rows = store.loadEntries()
        let liveEntryIDs = Set(rows.map(\.id))
        if records.contains(where: { $0.profileKey == key && !liveEntryIDs.contains($0.entryID) }) {
            records.removeAll { $0.profileKey == key && !liveEntryIDs.contains($0.entryID) }
            recordsChanged = true
        }

        var evaluatedCount = 0
        var countedOccurrences = 0
        var performed: [AmiVoiceDictionaryMonitoringTransition] = []

        for entry in rows {
            guard let engineState = entry.engineState(for: key) else { continue }
            var record = records.first(where: { $0.entryID == entry.id && $0.profileKey == key })
                ?? AmiVoiceDictionaryMonitoringRecord(entryID: entry.id, profileKey: key)

            // A content edit advanced `updatedAt`: reset both counters, re-arm
            // the 24-hour guard, and re-derive provenance for the new written
            // form.
            if let lastUpdated = record.lastObservedUpdatedAt, entry.updatedAt > lastUpdated {
                record.reCorrectionTimestamps = []
                record.reverseCorrectionTimestamps = []
                record.lastManualEditAt = entry.updatedAt
                record.originalFragment = nil
            }
            // Re-entry into the synced set (manual re-approval) resets both
            // counters and counts as a manual action for the guard.
            if let previous = record.lastObservedState,
               !previous.participatesInSnapshot,
               engineState.state.participatesInSnapshot {
                record.reCorrectionTimestamps = []
                record.reverseCorrectionTimestamps = []
                record.lastManualEditAt = evaluatedAt
            }
            record.lastObservedState = engineState.state
            record.lastObservedUpdatedAt = entry.updatedAt

            // Monitoring never transitions entries outside the synced set.
            guard engineState.state.participatesInSnapshot else {
                recordsChanged = upsert(record, into: &records) || recordsChanged
                continue
            }

            if record.originalFragment == nil {
                record.originalFragment = sourceFragment(for: entry, in: learnedTerms)
            }
            evaluatedCount += 1

            // Only occurrences after the entry's last successful sync count.
            guard let lastSyncedAt = engineState.lastSyncedAt else {
                recordsChanged = upsert(record, into: &records) || recordsChanged
                continue
            }
            let writtenNorm = LearnedTermPolicy.normalized(entry.written)
            let originalNorm = record.originalFragment.map { LearnedTermPolicy.normalized($0) }
            for event in events where event.occurredAt > lastSyncedAt {
                let termNorm = LearnedTermPolicy.normalized(event.term.term)
                let fragmentNorm = LearnedTermPolicy.normalized(event.term.originalFragment)
                if let originalNorm, fragmentNorm == originalNorm, termNorm == writtenNorm {
                    record.reCorrectionTimestamps.append(event.occurredAt)
                    countedOccurrences += 1
                } else if fragmentNorm == writtenNorm, termNorm != writtenNorm {
                    record.reverseCorrectionTimestamps.append(event.occurredAt)
                    countedOccurrences += 1
                }
            }
            let reCutoff = evaluatedAt.addingTimeInterval(-AmiVoiceDictionaryMonitoringPolicy.reCorrectionWindow)
            record.reCorrectionTimestamps.removeAll { $0 < reCutoff }
            let reverseCutoff = evaluatedAt.addingTimeInterval(-AmiVoiceDictionaryMonitoringPolicy.reverseCorrectionWindow)
            record.reverseCorrectionTimestamps.removeAll { $0 < reverseCutoff }

            if record.reverseCorrectionTimestamps.count >= AmiVoiceDictionaryMonitoringPolicy.reverseCorrectionThreshold {
                let guardActive = record.lastManualEditAt
                    .map { evaluatedAt.timeIntervalSince($0) < AmiVoiceDictionaryMonitoringPolicy.manualEditGuardInterval }
                    ?? false
                if !guardActive {
                    let transition = AmiVoiceDictionaryMonitoringTransition(
                        entryID: entry.id,
                        kind: .reverseCorrection,
                        toState: .autoDisabled,
                        at: evaluatedAt,
                        occurrenceCount: record.reverseCorrectionTimestamps.count,
                        windowDays: Int(AmiVoiceDictionaryMonitoringPolicy.reverseCorrectionWindow / 86_400),
                        occurrenceTimestamps: record.reverseCorrectionTimestamps
                    )
                    let applied = await engine.transitionMonitoredEntry(
                        id: entry.id,
                        for: key,
                        to: .autoDisabled,
                        errorClass: .unknown,
                        detail: "reverse-correction x\(transition.occurrenceCount) within \(transition.windowDays)d"
                    )
                    if applied {
                        record.lastAutoTransition = transition
                        record.lastObservedState = .autoDisabled
                        performed.append(transition)
                        // U-02: stop the harm now through the existing
                        // immediate trigger — and allow an empty overwrite,
                        // or a lone quarantined entry would stay on the server.
                        _ = await engine.resyncAfterMonitoredQuarantine(for: key)
                    }
                }
            } else if record.reCorrectionTimestamps.count >= AmiVoiceDictionaryMonitoringPolicy.reCorrectionThreshold {
                let transition = AmiVoiceDictionaryMonitoringTransition(
                    entryID: entry.id,
                    kind: .reCorrection,
                    toState: .pendingReview,
                    at: evaluatedAt,
                    occurrenceCount: record.reCorrectionTimestamps.count,
                    windowDays: Int(AmiVoiceDictionaryMonitoringPolicy.reCorrectionWindow / 86_400),
                    occurrenceTimestamps: record.reCorrectionTimestamps
                )
                let applied = await engine.transitionMonitoredEntry(
                    id: entry.id,
                    for: key,
                    to: .pendingReview,
                    errorClass: .unknown,
                    detail: "re-correction x\(transition.occurrenceCount) within \(transition.windowDays)d"
                )
                if applied {
                    record.lastAutoTransition = transition
                    record.lastObservedState = .pendingReview
                    performed.append(transition)
                    // Reviewed entries leave the syncable set (U-01); the next
                    // debounced sync pushes the removal.
                    await engine.scheduleDebouncedSync(for: key)
                }
            }

            recordsChanged = upsert(record, into: &records) || recordsChanged
        }

        if recordsChanged {
            _ = store.saveMonitoringRecords(records)
        }
        return AmiVoiceDictionaryMonitoringReport(
            monitoringActive: true,
            evaluatedEntryCount: evaluatedCount,
            countedOccurrenceCount: countedOccurrences,
            transitions: performed
        )
    }

    /// B-4 hook: call after a manual edit or manual re-approval of an entry.
    /// Resets both counters and re-arms the 24-hour quarantine guard. Creates
    /// the bookkeeping row when the entry has not been monitored yet so the
    /// guard still applies.
    public func resetCorrectionTracking(entryID: UUID, for key: AmiVoiceDictionaryProfileKey) {
        var records = store.loadMonitoringRecords()
        if let index = records.firstIndex(where: { $0.entryID == entryID && $0.profileKey == key }) {
            records[index].reCorrectionTimestamps = []
            records[index].reverseCorrectionTimestamps = []
            records[index].lastManualEditAt = now()
        } else {
            records.append(AmiVoiceDictionaryMonitoringRecord(
                entryID: entryID,
                profileKey: key,
                lastManualEditAt: now()
            ))
        }
        _ = store.saveMonitoringRecords(records)
    }

    /// Bookkeeping surface for B-4: all monitoring records for one profile.
    public func monitoringRecords(for key: AmiVoiceDictionaryProfileKey) -> [AmiVoiceDictionaryMonitoringRecord] {
        store.loadMonitoringRecords().filter { $0.profileKey == key }
    }

    public func monitoringRecord(entryID: UUID, for key: AmiVoiceDictionaryProfileKey) -> AmiVoiceDictionaryMonitoringRecord? {
        store.loadMonitoringRecords().first { $0.entryID == entryID && $0.profileKey == key }
    }

    /// Deterministic 64-bit FNV-1a fingerprint of the normalized
    /// (fragment -> term) pair. Stored instead of the text so monitoring
    /// bookkeeping never duplicates corrected content, and stable across
    /// launches (unlike `hashValue`).
    private static func pairFingerprint(term: String, fragment: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let basis = LearnedTermPolicy.normalized(fragment) + "\u{1F}" + LearnedTermPolicy.normalized(term)
        for byte in basis.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private func sourceFragment(for entry: AmiVoiceDictionaryEntry, in terms: [LearnedTerm]) -> String? {
        let writtenNorm = LearnedTermPolicy.normalized(entry.written)
        return terms
            .filter { $0.createdAt <= entry.updatedAt }
            .filter { LearnedTermPolicy.normalized($0.term) == writtenNorm }
            .max { $0.createdAt < $1.createdAt }?
            .originalFragment
    }

    private func upsert(
        _ record: AmiVoiceDictionaryMonitoringRecord,
        into records: inout [AmiVoiceDictionaryMonitoringRecord]
    ) -> Bool {
        if let index = records.firstIndex(where: { $0.entryID == record.entryID && $0.profileKey == record.profileKey }) {
            guard records[index] != record else { return false }
            records[index] = record
            return true
        }
        records.append(record)
        return true
    }
}
