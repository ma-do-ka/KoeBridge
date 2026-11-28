import Foundation

/// B-2 -> B-1 bridge: converts ready pipeline outcomes into
/// `AmiVoiceDictionaryEntry` values for the sync engine.
///
/// The adapter honours both contracts:
/// - B-2: only `.ready` outcomes produce entries; held and excluded outcomes
///   never appear in the output.
/// - B-1: every produced entry is checked with B-1's own
///   `AmiVoiceDictionaryValidator.payload(for:engine:)` and dropped when it
///   would fail snapshot validation. Upload caps, snapshot ordering and
///   payload deduplication stay with B-1's sync engine
///   (`AmiVoiceDictionarySyncPolicy` / `prepareSnapshot`); the adapter adds no
///   second cap or dedupe rule beyond entry-id stability.
public enum VocabularySyncAdapter {
    /// Maps one ready candidate to a dictionary entry. The entry id reuses the
    /// LearnedTerm id so re-running the pipeline over an unchanged store is a
    /// stable upsert rather than a duplicate insert.
    public static func entry(for candidate: VocabularyCandidate) -> AmiVoiceDictionaryEntry {
        AmiVoiceDictionaryEntry(
            id: candidate.learnedTermID,
            written: candidate.written,
            spoken: candidate.reading,
            createdAt: candidate.createdAt
        )
    }

    /// Maps `.ready` outcomes to validated entries, preserving input order.
    public static func entries(
        from outcomes: [VocabularyCandidateOutcome],
        for engine: AmiVoiceEngine
    ) -> [AmiVoiceDictionaryEntry] {
        var seenIDs = Set<UUID>()
        var entries: [AmiVoiceDictionaryEntry] = []
        entries.reserveCapacity(outcomes.count)
        for outcome in outcomes {
            guard case .ready(let candidate) = outcome,
                  seenIDs.insert(candidate.learnedTermID).inserted else { continue }
            let entry = entry(for: candidate)
            guard (try? AmiVoiceDictionaryValidator.payload(for: entry, engine: engine)) != nil else { continue }
            entries.append(entry)
        }
        return entries
    }
}

/// Reconciles the persisted learned-term store with the B-1 dictionary sync
/// store. Owns the B-2 pipeline and its `CandidateSetTracker`; each pass
/// re-seeds the tracker from the learned-term store, so a fresh process keeps
/// duplicate-reading and cap-guard state without a separate candidate store.
public final class VocabularySyncCoordinator: @unchecked Sendable {
    /// The store mutations to apply through `AmiVoiceDictionarySyncEngine`.
    public struct Plan: Equatable, Sendable {
        /// `.readyToSync` upserts for B-2 ready output. Each upsert makes B-1
        /// schedule its debounced upload; an empty list changes nothing.
        public var readyUpserts: [AmiVoiceDictionaryEntry] = []
        /// `.pendingReview` upserts so held terms surface in the hold queue.
        public var pendingUpserts: [AmiVoiceDictionaryEntry] = []
        /// Existing row ids whose term is now pipeline-excluded -> `.ignored`.
        public var ignoredIDs: [UUID] = []
        /// Non-protected rows no longer backed by a learned term -> `.archived`.
        public var archivedIDs: [UUID] = []
        /// Pipeline outcomes in store order, for diagnostics and tests.
        public var outcomes: [VocabularyCandidateOutcome] = []

        public init() {}
    }

    private let lock = NSLock()
    private let tracker = CandidateSetTracker()
    private let pipeline: VocabularyCandidatePipeline

    public init(configuration: VocabularyCandidatePipeline.Configuration = .default) {
        pipeline = VocabularyCandidatePipeline(config: configuration, candidateSetTracker: tracker)
    }

    /// The admitted (ready) candidate set the guards currently see.
    public var trackedCandidates: [VocabularyCandidate] {
        tracker.trackedCandidates
    }

    /// Processes every term in store order and returns the reconcile plan.
    ///
    /// Tracked candidates whose learned term is no longer in `terms` are
    /// evicted first, so a deleted term's old written form stops colliding and
    /// counting toward the caps. Before a term is evaluated its own previous
    /// seed is removed, so a term never collides with its earlier written form
    /// and the tracked set always equals the current ready set. Ingesting the
    /// same store twice therefore yields identical tracker state and an
    /// equivalent plan.
    @discardableResult
    public func ingest(
        terms: [LearnedTerm],
        existingEntries: [AmiVoiceDictionaryEntry],
        for key: AmiVoiceDictionaryProfileKey
    ) -> Plan {
        lock.lock()
        defer { lock.unlock() }
        var plan = Plan()
        let termIDs = Set(terms.map(\.id))
        for candidate in tracker.trackedCandidates where !termIDs.contains(candidate.learnedTermID) {
            tracker.removeCandidate(learnedTermID: candidate.learnedTermID)
        }
        for term in terms {
            tracker.removeCandidate(learnedTermID: term.id)
            let outcome = pipeline.process(term)
            plan.outcomes.append(outcome)
            if case .ready(let candidate) = outcome {
                tracker.seedCandidate(candidate)
            }
        }

        let rowsByID = Dictionary(
            existingEntries.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (term, outcome) in zip(terms, plan.outcomes) {
            switch outcome {
            case .ready(let candidate):
                let entry = VocabularySyncAdapter.entry(for: candidate)
                // B-1's own validator is the single gate here.
                guard (try? AmiVoiceDictionaryValidator.payload(for: entry, engine: key.engine)) != nil else {
                    continue
                }
                if let existing = rowsByID[entry.id] {
                    // `isProtected` marks user-approved and manually edited
                    // rows (TS-03): reconcile never overwrites, re-reads, or
                    // demotes them — pipeline outcomes apply only to
                    // unprotected rows and genuinely new terms.
                    if existing.isProtected { continue }
                    if let state = existing.engineState(for: key)?.state {
                        // `.archived` and `.ignored` are terminal states the sync
                        // side owns (delete-all archive, manual ignore); reconcile
                        // never resurrects them into an upload.
                        if state == .archived || state == .ignored {
                            continue
                        }
                        // Do not churn rows whose recorded engine state is already
                        // deliberate for identical content: synced/queued rows stay,
                        // and quarantined/held rows are not silently re-admitted.
                        if state != .candidate, Self.dictionaryContentMatches(existing, entry) {
                            continue
                        }
                    }
                }
                plan.readyUpserts.append(entry)
            case .pendingReview(_, let candidate):
                let entry = AmiVoiceDictionaryEntry(
                    id: candidate.learnedTermID,
                    written: candidate.written,
                    spoken: candidate.reading.isEmpty ? nil : candidate.reading,
                    createdAt: candidate.createdAt
                )
                if let existing = rowsByID[entry.id] {
                    // Same `isProtected` invariant as the `.ready` branch.
                    if existing.isProtected { continue }
                    if let state = existing.engineState(for: key)?.state {
                        // Parked and quarantined rows must not be re-emitted by a
                        // held term either.
                        if state == .archived || state == .ignored || state == .autoDisabled {
                            continue
                        }
                        if state == .pendingReview, Self.dictionaryContentMatches(existing, entry) {
                            continue
                        }
                    }
                }
                plan.pendingUpserts.append(entry)
            case .excluded:
                // `.ignored` marks the row without creating store entries for
                // terms that were never admitted; rows already ignored for this
                // key are not re-emitted. Protected rows keep the same
                // invariant: a pipeline exclusion never demotes a user's row.
                if let row = rowsByID[term.id],
                   !row.isProtected,
                   row.engineState(for: key)?.state != .ignored {
                    plan.ignoredIDs.append(term.id)
                }
            }
        }
        for row in existingEntries {
            guard !termIDs.contains(row.id),
                  !row.isProtected,
                  let state = row.engineState(for: key)?.state,
                  state != .archived else { continue }
            plan.archivedIDs.append(row.id)
        }
        return plan
    }

    /// Mirrors the content comparison `upsertEntry` uses to detect changes.
    private static func dictionaryContentMatches(
        _ lhs: AmiVoiceDictionaryEntry,
        _ rhs: AmiVoiceDictionaryEntry
    ) -> Bool {
        lhs.written == rhs.written
            && lhs.spoken == rhs.spoken
            && lhs.className == rhs.className
            && lhs.alternativeWritten == rhs.alternativeWritten
            && lhs.biasing == rhs.biasing
            && lhs.isProtected == rhs.isProtected
    }
}
