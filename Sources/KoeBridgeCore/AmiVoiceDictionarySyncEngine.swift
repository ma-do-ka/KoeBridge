import Foundation

public enum AmiVoiceDictionarySyncTrigger: String, Sendable {
    case debounced
    case userAction = "user_action"
    case launch
    case retry
    case deleteAll = "delete_all"
    case rollback
}

public struct AmiVoiceDictionarySyncOutcome: Equatable, Sendable {
    public var kind: AmiVoiceDictionarySyncResultKind
    public var profileKey: AmiVoiceDictionaryProfileKey
    public var uploadedCount: Int
    public var quarantinedCount: Int
    public var archivedCount: Int
    public var timestamp: Date

    public init(
        kind: AmiVoiceDictionarySyncResultKind,
        profileKey: AmiVoiceDictionaryProfileKey,
        uploadedCount: Int = 0,
        quarantinedCount: Int = 0,
        archivedCount: Int = 0,
        timestamp: Date
    ) {
        self.kind = kind
        self.profileKey = profileKey
        self.uploadedCount = uploadedCount
        self.quarantinedCount = quarantinedCount
        self.archivedCount = archivedCount
        self.timestamp = timestamp
    }
}

/// Coordinates the local source-of-truth rows with AmiVoice's full-overwrite
/// profileword API. All network work is asynchronous and actor-isolated away
/// from the dictation path.
public actor AmiVoiceDictionarySyncEngine {
    public typealias APIKeyProvider = @Sendable () async -> String?
    public typealias StatusObserver = @Sendable (AmiVoiceDictionaryProfileKey) -> Void

    private struct SnapshotPair {
        var entry: AmiVoiceDictionaryEntry
        var engineState: AmiVoiceDictionaryEngineState
        var payload: AmiVoiceDictionaryWordPayload
    }

    private struct SnapshotPreparation {
        var rows: [AmiVoiceDictionaryEntry]
        var pairs: [SnapshotPair]
        var rowsChanged: Bool
        var locallyQuarantinedCount: Int
        var archivedCount: Int
        var capOverflow: Bool
    }

    private let store: AmiVoiceDictionarySyncStore
    private let transport: any AmiVoiceDictionaryTransport
    private let apiKeyProvider: APIKeyProvider
    private let now: @Sendable () -> Date
    private let debounceInterval: TimeInterval
    private var inFlight: Set<AmiVoiceDictionaryProfileKey> = []
    private var debounceTasks: [AmiVoiceDictionaryProfileKey: Task<Void, Never>] = [:]
    private var retryTasks: [AmiVoiceDictionaryProfileKey: Task<Void, Never>] = [:]
    private var retryRequiresLaunchConsistency: Set<AmiVoiceDictionaryProfileKey> = []
    private var retryForcesUpload: Set<AmiVoiceDictionaryProfileKey> = []
    private var statusObserver: StatusObserver?

    public init(
        store: AmiVoiceDictionarySyncStore,
        transport: any AmiVoiceDictionaryTransport,
        apiKeyProvider: @escaping APIKeyProvider,
        debounceInterval: TimeInterval = AmiVoiceDictionarySyncPolicy.defaultDebounceInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.transport = transport
        self.apiKeyProvider = apiKeyProvider
        self.debounceInterval = debounceInterval
        self.now = now
    }

    public func setStatusObserver(_ observer: StatusObserver?) {
        statusObserver = observer
    }

    public func automaticSyncEnabled() -> Bool {
        store.automaticSyncEnabled
    }

    public func setAutomaticSyncEnabled(_ enabled: Bool) {
        store.automaticSyncEnabled = enabled
        if enabled {
            var profiles = store.loadProfiles()
            var changed = false
            for index in profiles.indices where profiles[index].authenticationBlocked {
                profiles[index].authenticationBlocked = false
                changed = true
            }
            if changed { _ = store.saveProfiles(profiles) }
        }
    }

    public func entries() -> [AmiVoiceDictionaryEntry] {
        store.loadEntries()
    }

    /// True while a sync for `key` is inside its single-flight section.
    /// Exposed for B-4 status surfaces and for tests that must observe a
    /// spawned immediate sync fully drained.
    public func isSyncInFlight(for key: AmiVoiceDictionaryProfileKey) -> Bool {
        inFlight.contains(key)
    }

    public func status(for key: AmiVoiceDictionaryProfileKey) -> AmiVoiceDictionarySyncStatus {
        AmiVoiceDictionarySyncStatus.make(
            automaticSyncEnabled: store.automaticSyncEnabled,
            entries: store.loadEntries(),
            profile: store.profile(for: key),
            key: key
        )
    }

    /// Adds or replaces one logical entry and attaches the requested per-engine
    /// sync state. B-2 owns candidate creation; ready entries automatically get
    /// a debounced sync here.
    @discardableResult public func upsertEntry(
        _ entry: AmiVoiceDictionaryEntry,
        for key: AmiVoiceDictionaryProfileKey,
        state requestedState: AmiVoiceDictionaryEntryState = .candidate
    ) -> Bool {
        var rows = store.loadEntries()
        let timestamp = now()
        if let index = rows.firstIndex(where: { $0.id == entry.id }) {
            var merged = rows[index]
            let contentChanged = merged.written != entry.written
                || merged.spoken != entry.spoken
                || merged.className != entry.className
                || merged.alternativeWritten != entry.alternativeWritten
                || merged.biasing != entry.biasing
                || merged.isProtected != entry.isProtected
            if contentChanged {
                merged.written = entry.written
                merged.spoken = entry.spoken
                merged.className = entry.className
                merged.alternativeWritten = entry.alternativeWritten
                merged.biasing = entry.biasing
                merged.isProtected = entry.isProtected
                merged.updatedAt = timestamp
                for stateIndex in merged.engineStates.indices {
                    merged.engineStates[stateIndex].generation &+= 1
                    if merged.engineStates[stateIndex].state.participatesInSnapshot {
                        merged.engineStates[stateIndex].dirty = true
                        if merged.engineStates[stateIndex].state == .autoSynced {
                            merged.engineStates[stateIndex].state = .readyToSync
                        }
                    }
                }
            }
            merged.updateEngineState(for: key) { engineState in
                if engineState.state != requestedState {
                    let wasParticipating = engineState.state.participatesInSnapshot
                    engineState.state = requestedState
                    engineState.generation &+= 1
                    if wasParticipating || requestedState.participatesInSnapshot {
                        engineState.dirty = true
                    }
                } else if contentChanged && requestedState.participatesInSnapshot {
                    engineState.dirty = true
                }
                if requestedState == .readyToSync {
                    engineState.lastErrorClass = nil
                    engineState.lastErrorDetail = nil
                }
            }
            rows[index] = merged
        } else {
            var inserted = entry
            inserted.updateEngineState(for: key) { engineState in
                engineState.state = requestedState
                engineState.dirty = requestedState.participatesInSnapshot
                engineState.generation &+= 1
            }
            rows.append(inserted)
        }
        guard store.saveEntries(rows) else { return false }
        notifyStatus(key)
        if requestedState == .readyToSync {
            scheduleDebouncedSync(for: key)
        }
        return true
    }

    /// Performs a lifecycle transition owned by the sync side. `autoSynced` is
    /// deliberately not accepted here; only a confirmed overwrite can set it.
    @discardableResult public func transitionEntry(
        id: UUID,
        for key: AmiVoiceDictionaryProfileKey,
        to requestedState: AmiVoiceDictionaryEntryState
    ) -> Bool {
        guard requestedState != .autoSynced else { return false }
        var rows = store.loadEntries()
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        var changed = false
        var triggersSnapshotSync = false
        rows[index].updateEngineState(for: key) { engineState in
            guard engineState.state != requestedState else { return }
            let wasParticipating = engineState.state.participatesInSnapshot
            engineState.state = requestedState
            engineState.generation &+= 1
            if wasParticipating || requestedState.participatesInSnapshot {
                engineState.dirty = true
                triggersSnapshotSync = true
            }
            if requestedState == .readyToSync {
                engineState.lastErrorClass = nil
                engineState.lastErrorDetail = nil
            }
            changed = true
        }
        guard changed else { return true }
        guard store.saveEntries(rows) else { return false }
        notifyStatus(key)
        if requestedState == .readyToSync {
            scheduleDebouncedSync(for: key)
        } else if triggersSnapshotSync {
            spawnImmediateSync(for: key)
        }
        return true
    }

    /// B-3 monitoring hook: transitions an entry out of the synced set with
    /// evidence attached. The guard on the current state makes it impossible
    /// for monitoring to move entries that are not currently synced, even if
    /// the entry's state changed between evaluation and this call. The sync
    /// trigger itself is left to the caller (immediate for quarantine, debounce
    /// for review).
    @discardableResult public func transitionMonitoredEntry(
        id: UUID,
        for key: AmiVoiceDictionaryProfileKey,
        to requestedState: AmiVoiceDictionaryEntryState,
        errorClass: AmiVoiceDictionarySyncErrorClass?,
        detail: String?
    ) -> Bool {
        guard requestedState != .autoSynced else { return false }
        var rows = store.loadEntries()
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        var applied = false
        rows[index].updateEngineState(for: key) { engineState in
            guard engineState.state.participatesInSnapshot else { return }
            engineState.state = requestedState
            engineState.dirty = true
            engineState.generation &+= 1
            engineState.lastErrorClass = errorClass
            engineState.lastErrorDetail = detail
            applied = true
        }
        guard applied else { return false }
        guard store.saveEntries(rows) else { return false }
        notifyStatus(key)
        return true
    }

    public func scheduleDebouncedSync(for key: AmiVoiceDictionaryProfileKey) {
        guard store.automaticSyncEnabled else { return }
        debounceTasks[key]?.cancel()
        let interval = min(max(0, debounceInterval), 3_600)
        debounceTasks[key] = Task { [weak self] in
            if interval > 0 {
                try? await Task.sleep(for: .seconds(interval))
            }
            guard !Task.isCancelled, let self else { return }
            await self.runDebouncedSync(for: key)
        }
    }

    public func syncNow(
        for key: AmiVoiceDictionaryProfileKey,
        trigger: AmiVoiceDictionarySyncTrigger = .userAction
    ) async -> AmiVoiceDictionarySyncOutcome {
        await performSync(for: key, trigger: trigger, forceUpload: trigger == .userAction)
    }

    /// U-02 path for the correction monitor: an immediate send that is allowed
    /// to overwrite with an EMPTY set. B-1's empty-send guard protects against
    /// repeating a failing set; a monitored quarantine instead needs the empty
    /// overwrite to clear the word from the server now (the same operation
    /// `deleteAll` already performs).
    public func resyncAfterMonitoredQuarantine(for key: AmiVoiceDictionaryProfileKey) async -> AmiVoiceDictionarySyncOutcome {
        await performSync(for: key, trigger: .userAction, forceUpload: true, allowEmptyOverwrite: true)
    }

    /// Explicit delete-all control for B-4. Active local entries are archived
    /// first so the normal launch-consistency pass cannot resurrect them.
    public func deleteAllServerWords(for key: AmiVoiceDictionaryProfileKey) async -> AmiVoiceDictionarySyncOutcome {
        guard store.automaticSyncEnabled else {
            return AmiVoiceDictionarySyncOutcome(kind: .disabled, profileKey: key, timestamp: now())
        }
        var rows = store.loadEntries()
        var changed = false
        for index in rows.indices {
            rows[index].updateEngineState(for: key) { engineState in
                guard engineState.state.participatesInSnapshot else { return }
                engineState.state = .archived
                engineState.dirty = true
                engineState.generation &+= 1
                changed = true
            }
        }
        if changed {
            guard store.saveEntries(rows) else {
                return AmiVoiceDictionarySyncOutcome(kind: .storeFailure, profileKey: key, timestamp: now())
            }
            notifyStatus(key)
        }
        return await performSync(for: key, trigger: .deleteAll, forceUpload: true)
    }

    /// Snapshot history for one profile, newest first. B-4 renders this list;
    /// the `rollbackSourceSnapshotID` field links rollback snapshots to the
    /// snapshot they restored.
    public func syncSnapshots(for key: AmiVoiceDictionaryProfileKey) -> [AmiVoiceDictionarySyncSnapshot] {
        store.snapshots(for: key)
    }

    /// The most recent snapshot whose send was reflected on the server.
    public func latestReflectedSyncSnapshot(for key: AmiVoiceDictionaryProfileKey) -> AmiVoiceDictionarySyncSnapshot? {
        store.latestReflectedSnapshot(for: key)
    }

    /// U-04 manual retry: resends the currently dirty set through the normal
    /// immediate path. After a rollback whose send failed, this is the
    /// exposed retry entry point; automatic retry falls out of the dirty rows
    /// on the next normal trigger.
    public func retryPendingRollbackReflection(for key: AmiVoiceDictionaryProfileKey) async -> AmiVoiceDictionarySyncOutcome {
        await performSync(for: key, trigger: .userAction, forceUpload: true)
    }

    /// Per-profile rollback (U-05): restores the syncable set of `key` to the
    /// snapshot's set, then fires an immediate full-overwrite sync of the
    /// restored set and appends a new rollback snapshot. Hard invariant: an
    /// entry currently `ignored` is never revived, even when it is a snapshot
    /// member. Entries sent in the snapshot are restored with their snapshot
    /// content (and recreated if the row vanished); participating entries
    /// absent from the snapshot are archived so the overwrite drops them.
    ///
    /// The restored rows get fresh generations and stay dirty until a send is
    /// reflected, so a stale in-flight sync that completes afterwards cannot
    /// mark them reflected (generation check), a failed send leaves the
    /// restore standing, and the pending reflection is retried by the next
    /// normal trigger or `retryPendingRollbackReflection` (U-04).
    @discardableResult
    public func rollbackProfile(
        for key: AmiVoiceDictionaryProfileKey,
        toSnapshotID sourceSnapshotID: UUID
    ) async -> AmiVoiceDictionaryRollbackOutcome {
        guard let source = store.loadSnapshots().first(where: { $0.id == sourceSnapshotID && $0.profileKey == key }) else {
            return AmiVoiceDictionaryRollbackOutcome(
                kind: .snapshotNotFound,
                sourceSnapshotID: sourceSnapshotID,
                timestamp: now()
            )
        }

        var rows = store.loadEntries()
        let snapshotMembers = Dictionary(uniqueKeysWithValues: source.entries.map { ($0.entryID, $0) })
        var restoredCount = 0
        var recreatedCount = 0
        var archivedCount = 0
        var keptIgnoredCount = 0
        for index in rows.indices {
            let entryID = rows[index].id
            if let snapshotEntry = snapshotMembers[entryID] {
                if rows[index].engineState(for: key)?.state == .ignored {
                    keptIgnoredCount += 1
                    continue
                }
                // Restore the sent content so the overwrite reflects the
                // snapshot's set exactly. `updatedAt` is deliberately left
                // alone: bumping it would look like a manual edit to the
                // correction monitor.
                rows[index].written = snapshotEntry.written
                rows[index].spoken = snapshotEntry.spoken
                rows[index].className = snapshotEntry.className
                rows[index].alternativeWritten = snapshotEntry.alternativeWritten
                rows[index].biasing = snapshotEntry.biasing
                rows[index].isProtected = snapshotEntry.isProtected
                rows[index].updateEngineState(for: key) { engineState in
                    engineState.state = .readyToSync
                    engineState.dirty = true
                    engineState.failureCount = 0
                    engineState.lastErrorClass = nil
                    engineState.lastErrorDetail = nil
                    engineState.generation &+= 1
                }
                restoredCount += 1
            } else if rows[index].engineState(for: key)?.state.participatesInSnapshot == true {
                rows[index].updateEngineState(for: key) { engineState in
                    engineState.state = .archived
                    engineState.dirty = true
                    engineState.lastErrorDetail = "rollback to snapshot \(sourceSnapshotID.uuidString)"
                    engineState.generation &+= 1
                }
                archivedCount += 1
            }
        }
        for snapshotEntry in source.entries where !rows.contains(where: { $0.id == snapshotEntry.entryID }) {
            var recreated = AmiVoiceDictionaryEntry(
                id: snapshotEntry.entryID,
                written: snapshotEntry.written,
                spoken: snapshotEntry.spoken,
                className: snapshotEntry.className,
                alternativeWritten: snapshotEntry.alternativeWritten,
                biasing: snapshotEntry.biasing,
                isProtected: snapshotEntry.isProtected,
                createdAt: snapshotEntry.createdAt,
                updatedAt: snapshotEntry.updatedAt
            )
            recreated.updateEngineState(for: key) { engineState in
                engineState.state = .readyToSync
                engineState.dirty = true
                engineState.generation &+= 1
            }
            rows.append(recreated)
            recreatedCount += 1
        }
        guard store.saveEntries(rows) else {
            return AmiVoiceDictionaryRollbackOutcome(
                kind: .storeFailure,
                sourceSnapshotID: sourceSnapshotID,
                timestamp: now()
            )
        }
        notifyStatus(key)

        let snapshotIDsBefore = Set(store.loadSnapshots().map(\.id))
        let outcome = await performSync(
            for: key,
            trigger: .rollback,
            forceUpload: true,
            rollbackSourceSnapshotID: sourceSnapshotID,
            allowEmptyOverwrite: true
        )
        var rollbackSnapshotID = store.snapshots(for: key)
            .first { $0.trigger == .rollback && !snapshotIDsBefore.contains($0.id) }?
            .id
        if rollbackSnapshotID == nil {
            // The send never ran (sync disabled, already in flight, auth
            // missing). The local restore stands; record the pending
            // reflection as a failed rollback snapshot so history stays
            // append-only and retry has a concrete target.
            let pendingEntries = store.loadEntries().compactMap { entry -> AmiVoiceDictionarySnapshotEntry? in
                guard let engineState = entry.engineState(for: key),
                      engineState.state.participatesInSnapshot else { return nil }
                return AmiVoiceDictionarySnapshotEntry(
                    entryID: entry.id,
                    written: entry.written,
                    spoken: entry.spoken,
                    className: entry.className,
                    alternativeWritten: entry.alternativeWritten,
                    biasing: entry.biasing,
                    isProtected: entry.isProtected,
                    createdAt: entry.createdAt,
                    updatedAt: entry.updatedAt,
                    stateAtSend: engineState.state
                )
            }
            rollbackSnapshotID = appendSyncSnapshot(
                for: key,
                profileID: store.profile(for: key)?.profileID,
                trigger: .rollback,
                status: .failed,
                entries: pendingEntries,
                rollbackSourceSnapshotID: sourceSnapshotID
            )
        }
        return AmiVoiceDictionaryRollbackOutcome(
            kind: outcome.kind == .success ? .applied : .appliedReflectionPending,
            sourceSnapshotID: sourceSnapshotID,
            rollbackSnapshotID: rollbackSnapshotID,
            syncResult: outcome.kind,
            restoredEntryCount: restoredCount,
            recreatedEntryCount: recreatedCount,
            archivedEntryCount: archivedCount,
            keptIgnoredCount: keptIgnoredCount,
            timestamp: now()
        )
    }

    /// Launch-time consistency pass. It performs zero transport calls while the
    /// opt-in setting is off. When enabled it compares the server snapshot with
    /// the local source of truth and re-uploads the full snapshot if either side
    /// is missing or diverged.
    public func performLaunchConsistencyPass(for key: AmiVoiceDictionaryProfileKey) async -> AmiVoiceDictionarySyncOutcome {
        guard store.automaticSyncEnabled else {
            return AmiVoiceDictionarySyncOutcome(kind: .disabled, profileKey: key, timestamp: now())
        }
        guard var profile = ensureProfile(for: key) else {
            return AmiVoiceDictionarySyncOutcome(kind: .storeFailure, profileKey: key, timestamp: now())
        }
        if profile.authenticationBlocked {
            profile.authenticationBlocked = false
            _ = updateProfile(profile)
        }
        guard let apiKey = await usableAPIKey() else {
            var updated = profile
            updated.lastResult = .authenticationRequired
            updated.lastErrorClass = .authenticationMissing
            updated.authenticationBlocked = true
            _ = updateProfile(updated)
            notifyStatus(key)
            return AmiVoiceDictionarySyncOutcome(kind: .authenticationRequired, profileKey: key, timestamp: now())
        }

        var rows = store.loadEntries()
        let preparation = prepareSnapshot(rows, for: key)
        rows = preparation.rows
        if preparation.rowsChanged {
            guard store.saveEntries(rows) else {
                return AmiVoiceDictionarySyncOutcome(kind: .storeFailure, profileKey: key, timestamp: now())
            }
            notifyStatus(key)
        }
        let family = AmiVoiceDictionaryEngineFamily(engine: key.engine)
        let desiredPayloads = preparation.pairs.map(\.payload)
        let desiredFingerprint = AmiVoiceDictionaryWordPayload.fingerprint(payloads: desiredPayloads, family: family)
        let hasDirtyRows = rows.contains { $0.engineState(for: key)?.dirty == true }
        let hasUnsyncedLocalChanges = hasDirtyRows
            || (profile.lastSyncedFingerprint != desiredFingerprint
                && !(profile.lastSyncedFingerprint == nil && desiredPayloads.isEmpty))
        var needsUpload = hasUnsyncedLocalChanges
        var forceUpload = false
        var serverConfirmedMismatch = false
        var fetchFailure: AmiVoiceDictionaryTransportError?
        var serverPayloads: [AmiVoiceDictionaryWordPayload]?

        do {
            let fetched = try await transport.fetchWords(
                engine: key.engine,
                samplingRate: key.samplingRate,
                profileID: profile.profileID,
                apiKey: apiKey
            )
            serverPayloads = fetched
            let serverFingerprint = AmiVoiceDictionaryWordPayload.fingerprint(payloads: fetched, family: family)
            if fetched.isEmpty && !desiredPayloads.isEmpty {
                needsUpload = true
                forceUpload = true
                serverConfirmedMismatch = true
            } else if serverFingerprint != desiredFingerprint {
                needsUpload = true
                forceUpload = true
                serverConfirmedMismatch = true
            } else {
                needsUpload = hasDirtyRows
                forceUpload = false
            }
        } catch let error as AmiVoiceDictionaryTransportError {
            fetchFailure = error
            if error == .profileMissing {
                needsUpload = !desiredPayloads.isEmpty || hasDirtyRows
                forceUpload = !desiredPayloads.isEmpty
                if !desiredPayloads.isEmpty {
                    serverConfirmedMismatch = true
                }
            }
        } catch {
            fetchFailure = .temporary(.network)
        }

        if let fetchFailure {
            switch fetchFailure {
            case .profileMissing:
                break
            case .authentication:
                var updated = profile
                updated.lastResult = .authenticationRejected
                updated.lastErrorClass = .authenticationRejected
                updated.authenticationBlocked = true
                _ = updateProfile(updated)
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(kind: .authenticationRejected, profileKey: key, timestamp: now())
            case .temporary(let temporary):
                guard !needsUpload else { break }
                var updated = profile
                recordTemporaryFailure(temporary, profile: &updated)
                _ = updateProfile(updated)
                scheduleRetryIfNeeded(for: key, profile: updated, verifyConsistency: true)
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(kind: .temporaryFailure, profileKey: key, timestamp: now())
            case .invalidRequest, .entryValidation(_), .limitExceeded, .malformedResponse:
                guard !needsUpload else { break }
                var updated = profile
                updated.lastResult = .temporaryFailure
                updated.lastErrorClass = .server
                _ = updateProfile(updated)
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(kind: .temporaryFailure, profileKey: key, timestamp: now())
            }
        }

        guard needsUpload else {
            cancelScheduledRetry(for: key)
            var updated = profile
            updated.lastResult = .noChanges
            updated.lastErrorClass = nil
            updated.consecutiveTemporaryFailures = 0
            updated.backoffUntil = nil
            if serverPayloads != nil, updated.lastSyncedFingerprint != desiredFingerprint {
                updated.lastSyncedFingerprint = desiredFingerprint
            }
            _ = updateProfile(updated)
            notifyStatus(key)
            return AmiVoiceDictionarySyncOutcome(kind: .noChanges, profileKey: key, timestamp: now())
        }
        if serverConfirmedMismatch && profile.lastSyncedFingerprint != nil {
            // Invalidate the cached fingerprint once GET observes profile loss or
            // divergence so a subsequent retry cannot treat stale state as current.
            profile.lastSyncedFingerprint = nil
            _ = updateProfile(profile)
        }
        return await performSync(for: key, trigger: .launch, forceUpload: forceUpload)
    }

    public static func generatedProfileID(
        engine: AmiVoiceEngine,
        samplingRate: AmiVoiceDictionarySamplingRate,
        uuid: UUID = UUID()
    ) -> AmiVoiceProfileID? {
        var enginePart = ""
        for scalar in engine.rawValue.unicodeScalars {
            let value = scalar.value
            let isDigit = value >= 0x30 && value <= 0x39
            let isUpper = value >= 0x41 && value <= 0x5A
            let isLower = value >= 0x61 && value <= 0x7A
            if isDigit || isUpper || isLower {
                enginePart.unicodeScalars.append(scalar)
            } else {
                enginePart.append("_")
            }
        }
        while enginePart.hasPrefix("_") { enginePart.removeFirst() }
        if enginePart.isEmpty { enginePart = "engine" }
        let suffix = String(uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
        return AmiVoiceProfileID("kb_\(enginePart.lowercased())_\(samplingRate.rawValue)_\(suffix)")
    }

    private func runDebouncedSync(for key: AmiVoiceDictionaryProfileKey) {
        debounceTasks[key] = nil
        Task { [weak self] in
            guard let self else { return }
            _ = await self.performSync(for: key, trigger: .debounced, forceUpload: false)
        }
    }

    private func spawnImmediateSync(for key: AmiVoiceDictionaryProfileKey) {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.performSync(for: key, trigger: .userAction, forceUpload: false)
        }
    }

    private func retryAfterBackoff(for key: AmiVoiceDictionaryProfileKey) {
        retryTasks[key] = nil
        let shouldVerifyConsistency = retryRequiresLaunchConsistency.remove(key) != nil
        let shouldForceUpload = retryForcesUpload.remove(key) != nil
        Task { [weak self] in
            guard let self else { return }
            if shouldVerifyConsistency {
                _ = await self.performLaunchConsistencyPass(for: key)
            } else {
                _ = await self.performSync(for: key, trigger: .retry, forceUpload: shouldForceUpload)
            }
        }
    }

    private func performSync(
        for key: AmiVoiceDictionaryProfileKey,
        trigger: AmiVoiceDictionarySyncTrigger,
        forceUpload: Bool,
        rollbackSourceSnapshotID: UUID? = nil,
        allowEmptyOverwrite: Bool = false
    ) async -> AmiVoiceDictionarySyncOutcome {
        guard store.automaticSyncEnabled else {
            return AmiVoiceDictionarySyncOutcome(kind: .disabled, profileKey: key, timestamp: now())
        }
        guard !inFlight.contains(key) else {
            return AmiVoiceDictionarySyncOutcome(kind: .alreadyInFlight, profileKey: key, timestamp: now())
        }
        guard var profile = ensureProfile(for: key) else {
            return AmiVoiceDictionarySyncOutcome(kind: .storeFailure, profileKey: key, timestamp: now())
        }
        if (trigger == .userAction || trigger == .launch || trigger == .deleteAll || trigger == .rollback) && profile.authenticationBlocked {
            profile.authenticationBlocked = false
            _ = updateProfile(profile)
        }
        if profile.authenticationBlocked {
            return AmiVoiceDictionarySyncOutcome(kind: .authenticationRequired, profileKey: key, timestamp: now())
        }
        guard let apiKey = await usableAPIKey() else {
            var updated = profile
            updated.lastResult = .authenticationRequired
            updated.lastErrorClass = .authenticationMissing
            updated.authenticationBlocked = true
            _ = updateProfile(updated)
            notifyStatus(key)
            return AmiVoiceDictionarySyncOutcome(kind: .authenticationRequired, profileKey: key, timestamp: now())
        }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        var validationAttempts = 0
        var totalServerQuarantined = 0
        var lastPreparation: SnapshotPreparation?
        // B-3: the pair set most recently handed to the transport this sync.
        // One snapshot is appended per completed send (reflected or failed);
        // paths that return before any send produce no snapshot.
        var lastAttemptedPairs: [SnapshotPair]?
        while validationAttempts <= AmiVoiceDictionarySyncPolicy.maximumValidationIsolationAttempts {
            let initialRows = store.loadEntries()
            let preparation = prepareSnapshot(initialRows, for: key)
            lastPreparation = preparation
            var rows = preparation.rows
            if preparation.rowsChanged {
                guard store.saveEntries(rows) else {
                    recordStoreFailure(profile: profile, key: key)
                    return AmiVoiceDictionarySyncOutcome(kind: .storeFailure, profileKey: key, timestamp: now())
                }
                notifyStatus(key)
            }

            let family = AmiVoiceDictionaryEngineFamily(engine: key.engine)
            let payloads = preparation.pairs.map(\.payload)
            let fingerprint = AmiVoiceDictionaryWordPayload.fingerprint(payloads: payloads, family: family)
            let hasDirtyRows = rows.contains { $0.engineState(for: key)?.dirty == true }
            let quarantinedCount = preparation.locallyQuarantinedCount + totalServerQuarantined
            let alreadyCurrent = profile.lastSyncedFingerprint == fingerprint && !hasDirtyRows
            if alreadyCurrent && !forceUpload {
                var updated = profile
                updated.lastResult = .noChanges
                updated.lastErrorClass = preparation.capOverflow ? .capExceeded : nil
                _ = updateProfile(updated)
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(
                    kind: .noChanges,
                    profileKey: key,
                    quarantinedCount: quarantinedCount,
                    archivedCount: preparation.archivedCount,
                    timestamp: now()
                )
            }
            if payloads.isEmpty && trigger != .deleteAll && !allowEmptyOverwrite {
                let quarantinedRows = quarantinedRowCount(rows, key: key)
                if quarantinedCount > 0 || quarantinedRows > 0 {
                    // The candidate set is empty because everything left is
                    // quarantined. Never send an empty full-overwrite here: it would
                    // delete every word on the server and would repeat a failing set
                    // on the next sync.
                    recordFailedSyncSnapshotIfAttempted(for: key, trigger: trigger, attemptedPairs: lastAttemptedPairs, rollbackSourceSnapshotID: rollbackSourceSnapshotID)
                    return validationFailureOutcome(
                        profile: profile,
                        key: key,
                        quarantinedCount: max(quarantinedCount, quarantinedRows),
                        archivedCount: preparation.archivedCount
                    )
                }
                var updated = profile
                updated.lastResult = .noChanges
                updated.lastErrorClass = nil
                _ = updateProfile(updated)
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(
                    kind: .noChanges,
                    profileKey: key,
                    quarantinedCount: quarantinedCount,
                    archivedCount: preparation.archivedCount,
                    timestamp: now()
                )
            }

            let generationByID = Dictionary(uniqueKeysWithValues: preparation.pairs.map { ($0.entry.id, $0.engineState.generation) })
            let nonParticipatingGenerationByID = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (UUID, UInt64)? in
                guard let engineState = row.engineState(for: key),
                      !engineState.state.participatesInSnapshot else { return nil }
                return (row.id, engineState.generation)
            })
            lastAttemptedPairs = preparation.pairs
            do {
                _ = try await transport.replaceWords(
                    engine: key.engine,
                    samplingRate: key.samplingRate,
                    profileID: profile.profileID,
                    apiKey: apiKey,
                    payloads: payloads
                )
                // The server accepted this overwrite; record the reflected
                // snapshot before local bookkeeping so a later store failure
                // cannot misreport the send.
                recordSyncSnapshot(
                    for: key,
                    profileID: profile.profileID,
                    trigger: trigger,
                    pairs: preparation.pairs,
                    status: .reflected,
                    rollbackSourceSnapshotID: rollbackSourceSnapshotID
                )
                rows = store.loadEntries()
                let finishedAt = now()
                for index in rows.indices {
                    guard let currentState = rows[index].engineState(for: key) else { continue }
                    if let generation = generationByID[rows[index].id],
                       currentState.generation == generation,
                       currentState.state.participatesInSnapshot {
                        rows[index].updateEngineState(for: key) { engineState in
                            engineState.state = .autoSynced
                            engineState.dirty = false
                            engineState.failureCount = 0
                            engineState.lastErrorClass = nil
                            engineState.lastErrorDetail = nil
                            engineState.lastSyncedAt = finishedAt
                        }
                    } else if !currentState.state.participatesInSnapshot && currentState.dirty,
                              let preparedGeneration = nonParticipatingGenerationByID[rows[index].id],
                              preparedGeneration == currentState.generation {
                        rows[index].updateEngineState(for: key) { engineState in
                            engineState.dirty = false
                        }
                    }
                }
                guard store.saveEntries(rows) else {
                    recordStoreFailure(profile: profile, key: key)
                    return AmiVoiceDictionarySyncOutcome(kind: .storeFailure, profileKey: key, timestamp: now())
                }
                var updated = profile
                updated.lastSyncedFingerprint = fingerprint
                updated.lastSyncAt = finishedAt
                updated.lastResult = preparation.capOverflow ? .capExceeded : .success
                updated.lastErrorClass = preparation.capOverflow ? .capExceeded : nil
                updated.consecutiveTemporaryFailures = 0
                updated.backoffUntil = nil
                updated.authenticationBlocked = false
                guard updateProfile(updated) else {
                    recordStoreFailure(profile: updated, key: key)
                    return AmiVoiceDictionarySyncOutcome(kind: .storeFailure, profileKey: key, timestamp: now())
                }
                cancelScheduledRetry(for: key)
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(
                    kind: updated.lastResult ?? .success,
                    profileKey: key,
                    uploadedCount: payloads.count,
                    quarantinedCount: quarantinedCount,
                    archivedCount: preparation.archivedCount,
                    timestamp: finishedAt
                )
            } catch AmiVoiceDictionaryTransportError.entryValidation(let rejection) {
                let attributedIDs = entriesMatching(
                    rejection: rejection,
                    pairs: preparation.pairs,
                    family: AmiVoiceDictionaryEngineFamily(engine: key.engine)
                )
                let attemptsRemain = validationAttempts < AmiVoiceDictionarySyncPolicy.maximumValidationIsolationAttempts
                let unattributedCandidate = attributedIDs.isEmpty
                    ? isolationCandidate(pairs: preparation.pairs)
                    : nil
                // Attribution fails when the server's error body names no entry in
                // this snapshot. Guarantee progress (§8.3): isolate exactly one
                // deterministic candidate and retry with the strictly smaller set,
                // so one bad entry cannot block every later sync forever.
                let isolationIDs: Set<UUID>
                let isolationDetail: String?
                if !attributedIDs.isEmpty {
                    isolationIDs = attributedIDs
                    isolationDetail = nil
                } else if let unattributedCandidate {
                    isolationIDs = [unattributedCandidate]
                    isolationDetail = Self.unattributedIsolationDetail
                } else {
                    isolationIDs = []
                    isolationDetail = nil
                }
                if attemptsRemain, !isolationIDs.isEmpty {
                    validationAttempts += 1
                    totalServerQuarantined += isolationIDs.count
                    guard quarantineEntries(isolationIDs, detail: isolationDetail, key: key) else {
                        recordStoreFailure(profile: profile, key: key)
                        return AmiVoiceDictionarySyncOutcome(kind: .storeFailure, profileKey: key, timestamp: now())
                    }
                    notifyStatus(key)
                    continue
                }
                // The attempt budget is spent with the set still failing. For an
                // unattributed rejection, quarantine one more candidate (bookkeeping
                // only, no retry) so the next sync posts a strictly smaller set than
                // any set that has already failed.
                if !attemptsRemain, let unattributedCandidate {
                    totalServerQuarantined += 1
                    _ = quarantineEntries([unattributedCandidate], detail: Self.unattributedIsolationDetail, key: key)
                    notifyStatus(key)
                }
                recordFailedSyncSnapshotIfAttempted(for: key, trigger: trigger, attemptedPairs: lastAttemptedPairs, rollbackSourceSnapshotID: rollbackSourceSnapshotID)
                return validationFailureOutcome(
                    profile: profile,
                    key: key,
                    quarantinedCount: preparation.locallyQuarantinedCount + totalServerQuarantined,
                    archivedCount: preparation.archivedCount
                )
            } catch AmiVoiceDictionaryTransportError.authentication {
                var updated = profile
                updated.lastResult = .authenticationRejected
                updated.lastErrorClass = .authenticationRejected
                updated.authenticationBlocked = true
                updated.backoffUntil = nil
                _ = updateProfile(updated)
                cancelScheduledRetry(for: key)
                notifyStatus(key)
                recordFailedSyncSnapshotIfAttempted(for: key, trigger: trigger, attemptedPairs: lastAttemptedPairs, rollbackSourceSnapshotID: rollbackSourceSnapshotID)
                return AmiVoiceDictionarySyncOutcome(kind: .authenticationRejected, profileKey: key, timestamp: now())
            } catch AmiVoiceDictionaryTransportError.limitExceeded {
                var updated = profile
                updated.lastResult = .capExceeded
                updated.lastErrorClass = .capExceeded
                _ = updateProfile(updated)
                notifyStatus(key)
                recordFailedSyncSnapshotIfAttempted(for: key, trigger: trigger, attemptedPairs: lastAttemptedPairs, rollbackSourceSnapshotID: rollbackSourceSnapshotID)
                return AmiVoiceDictionarySyncOutcome(kind: .capExceeded, profileKey: key, timestamp: now())
            } catch AmiVoiceDictionaryTransportError.temporary(let temporary) {
                var updated = profile
                recordTemporaryFailure(temporary, profile: &updated)
                _ = updateProfile(updated)
                scheduleRetryIfNeeded(for: key, profile: updated, verifyConsistency: trigger == .launch, forceUpload: forceUpload)
                notifyStatus(key)
                recordFailedSyncSnapshotIfAttempted(for: key, trigger: trigger, attemptedPairs: lastAttemptedPairs, rollbackSourceSnapshotID: rollbackSourceSnapshotID)
                return AmiVoiceDictionarySyncOutcome(kind: .temporaryFailure, profileKey: key, timestamp: now())
            } catch AmiVoiceDictionaryTransportError.profileMissing {
                var updated = profile
                recordTemporaryFailure(.serverStatus(404), profile: &updated)
                updated.lastErrorClass = .profileMissing
                _ = updateProfile(updated)
                scheduleRetryIfNeeded(for: key, profile: updated, verifyConsistency: trigger == .launch, forceUpload: forceUpload)
                notifyStatus(key)
                recordFailedSyncSnapshotIfAttempted(for: key, trigger: trigger, attemptedPairs: lastAttemptedPairs, rollbackSourceSnapshotID: rollbackSourceSnapshotID)
                return AmiVoiceDictionarySyncOutcome(kind: .temporaryFailure, profileKey: key, timestamp: now())
            } catch AmiVoiceDictionaryTransportError.malformedResponse {
                var updated = profile
                recordTemporaryFailure(.serverStatus(500), profile: &updated)
                _ = updateProfile(updated)
                scheduleRetryIfNeeded(for: key, profile: updated, verifyConsistency: trigger == .launch, forceUpload: forceUpload)
                notifyStatus(key)
                recordFailedSyncSnapshotIfAttempted(for: key, trigger: trigger, attemptedPairs: lastAttemptedPairs, rollbackSourceSnapshotID: rollbackSourceSnapshotID)
                return AmiVoiceDictionarySyncOutcome(kind: .temporaryFailure, profileKey: key, timestamp: now())
            } catch AmiVoiceDictionaryTransportError.invalidRequest {
                var updated = profile
                recordTemporaryFailure(.serverStatus(500), profile: &updated)
                _ = updateProfile(updated)
                scheduleRetryIfNeeded(for: key, profile: updated, verifyConsistency: trigger == .launch, forceUpload: forceUpload)
                notifyStatus(key)
                recordFailedSyncSnapshotIfAttempted(for: key, trigger: trigger, attemptedPairs: lastAttemptedPairs, rollbackSourceSnapshotID: rollbackSourceSnapshotID)
                return AmiVoiceDictionarySyncOutcome(kind: .temporaryFailure, profileKey: key, timestamp: now())
            } catch {
                var updated = profile
                recordTemporaryFailure(.network, profile: &updated)
                _ = updateProfile(updated)
                scheduleRetryIfNeeded(for: key, profile: updated, verifyConsistency: trigger == .launch, forceUpload: forceUpload)
                notifyStatus(key)
                recordFailedSyncSnapshotIfAttempted(for: key, trigger: trigger, attemptedPairs: lastAttemptedPairs, rollbackSourceSnapshotID: rollbackSourceSnapshotID)
                return AmiVoiceDictionarySyncOutcome(kind: .temporaryFailure, profileKey: key, timestamp: now())
            }
        }

        // Defensive fallback: every isolation path above returns, so this is only
        // reachable if the loop bound changes.
        recordFailedSyncSnapshotIfAttempted(for: key, trigger: trigger, attemptedPairs: lastAttemptedPairs, rollbackSourceSnapshotID: rollbackSourceSnapshotID)
        return validationFailureOutcome(
            profile: profile,
            key: key,
            quarantinedCount: (lastPreparation?.locallyQuarantinedCount ?? 0) + totalServerQuarantined,
            archivedCount: lastPreparation?.archivedCount ?? 0
        )
    }

    private static let unattributedIsolationDetail = "unattributed validation rejection (isolation)"

    private func validationFailureOutcome(
        profile: AmiVoiceDictionaryProfile,
        key: AmiVoiceDictionaryProfileKey,
        quarantinedCount: Int,
        archivedCount: Int
    ) -> AmiVoiceDictionarySyncOutcome {
        var updated = profile
        updated.lastResult = .validationFailed
        updated.lastErrorClass = .validation
        _ = updateProfile(updated)
        notifyStatus(key)
        return AmiVoiceDictionarySyncOutcome(
            kind: .validationFailed,
            profileKey: key,
            quarantinedCount: quarantinedCount,
            archivedCount: archivedCount,
            timestamp: now()
        )
    }

    private static func snapshotTrigger(
        for trigger: AmiVoiceDictionarySyncTrigger
    ) -> AmiVoiceDictionarySnapshotTrigger {
        switch trigger {
        case .debounced, .retry:
            return .normal
        case .userAction, .deleteAll:
            return .manualImmediate
        case .launch:
            return .launchRestore
        case .rollback:
            return .rollback
        }
    }

    /// Appends one snapshot to the per-profile history (store enforces the
    /// U-03 retention limit). Returns the new snapshot's ID.
    @discardableResult
    private func appendSyncSnapshot(
        for key: AmiVoiceDictionaryProfileKey,
        profileID: AmiVoiceProfileID?,
        trigger: AmiVoiceDictionarySyncTrigger,
        status: AmiVoiceDictionarySnapshotStatus,
        entries: [AmiVoiceDictionarySnapshotEntry],
        rollbackSourceSnapshotID: UUID?
    ) -> UUID {
        let snapshot = AmiVoiceDictionarySyncSnapshot(
            createdAt: now(),
            profileKey: key,
            profileID: profileID?.rawValue,
            trigger: Self.snapshotTrigger(for: trigger),
            status: status,
            entries: entries,
            rollbackSourceSnapshotID: rollbackSourceSnapshotID
        )
        _ = store.appendSnapshot(snapshot)
        return snapshot.id
    }

    private func recordSyncSnapshot(
        for key: AmiVoiceDictionaryProfileKey,
        profileID: AmiVoiceProfileID?,
        trigger: AmiVoiceDictionarySyncTrigger,
        pairs: [SnapshotPair],
        status: AmiVoiceDictionarySnapshotStatus,
        rollbackSourceSnapshotID: UUID?
    ) {
        appendSyncSnapshot(
            for: key,
            profileID: profileID,
            trigger: trigger,
            status: status,
            entries: pairs.map { pair in
                AmiVoiceDictionarySnapshotEntry(
                    entryID: pair.entry.id,
                    written: pair.payload.written,
                    spoken: pair.payload.spoken,
                    className: pair.payload.className,
                    alternativeWritten: pair.payload.alternativeWritten,
                    biasing: pair.payload.biasing,
                    isProtected: pair.entry.isProtected,
                    createdAt: pair.entry.createdAt,
                    updatedAt: pair.entry.updatedAt,
                    stateAtSend: pair.engineState.state
                )
            },
            rollbackSourceSnapshotID: rollbackSourceSnapshotID
        )
    }

    /// Records a failed snapshot only when this sync actually attempted a
    /// send; pre-send exits (disabled, already in flight, auth required, no
    /// changes) append nothing.
    private func recordFailedSyncSnapshotIfAttempted(
        for key: AmiVoiceDictionaryProfileKey,
        trigger: AmiVoiceDictionarySyncTrigger,
        attemptedPairs: [SnapshotPair]?,
        rollbackSourceSnapshotID: UUID?
    ) {
        guard let attemptedPairs else { return }
        recordSyncSnapshot(
            for: key,
            profileID: store.profile(for: key)?.profileID,
            trigger: trigger,
            pairs: attemptedPairs,
            status: .failed,
            rollbackSourceSnapshotID: rollbackSourceSnapshotID
        )
    }

    @discardableResult
    private func quarantineEntries(
        _ ids: Set<UUID>,
        detail: String?,
        key: AmiVoiceDictionaryProfileKey
    ) -> Bool {
        guard !ids.isEmpty else { return true }
        var rows = store.loadEntries()
        for index in rows.indices where ids.contains(rows[index].id) {
            rows[index].updateEngineState(for: key) { engineState in
                engineState.state = .syncFailed
                engineState.dirty = true
                engineState.failureCount += 1
                engineState.lastErrorClass = .validation
                engineState.lastErrorDetail = detail
                engineState.generation &+= 1
            }
        }
        return store.saveEntries(rows)
    }

    private func quarantinedRowCount(
        _ rows: [AmiVoiceDictionaryEntry],
        key: AmiVoiceDictionaryProfileKey
    ) -> Int {
        rows.filter { row in
            guard let state = row.engineState(for: key)?.state else { return false }
            return state == .pendingReview || state == .syncFailed
        }.count
    }

    private func prepareSnapshot(
        _ inputRows: [AmiVoiceDictionaryEntry],
        for key: AmiVoiceDictionaryProfileKey
    ) -> SnapshotPreparation {
        var rows = inputRows
        var rowsChanged = false
        var locallyQuarantined = 0
        var pairs: [SnapshotPair] = []
        for index in rows.indices {
            guard let engineState = rows[index].engineState(for: key),
                  engineState.state.participatesInSnapshot else { continue }
            do {
                let payload = try AmiVoiceDictionaryValidator.payload(for: rows[index], engine: key.engine)
                pairs.append(SnapshotPair(entry: rows[index], engineState: engineState, payload: payload))
            } catch {
                rows[index].updateEngineState(for: key) { mutableState in
                    mutableState.state = .pendingReview
                    mutableState.dirty = true
                    mutableState.failureCount += 1
                    mutableState.lastErrorClass = .validation
                    mutableState.generation &+= 1
                }
                rowsChanged = true
                locallyQuarantined += 1
            }
        }

        pairs.sort { lhs, rhs in
            if lhs.entry.isProtected != rhs.entry.isProtected {
                return lhs.entry.isProtected && !rhs.entry.isProtected
            }
            if lhs.entry.createdAt != rhs.entry.createdAt {
                return lhs.entry.createdAt > rhs.entry.createdAt
            }
            return lhs.entry.id.uuidString < rhs.entry.id.uuidString
        }

        var archivedCount = 0
        if pairs.count > AmiVoiceDictionarySyncPolicy.hardEntryLimit {
            var activeCount = pairs.count
            var archiveIDs = Set<UUID>()
            for pair in pairs.reversed() where activeCount > AmiVoiceDictionarySyncPolicy.hardEntryLimit {
                guard pair.engineState.state == .autoSynced, !pair.entry.isProtected else { continue }
                archiveIDs.insert(pair.entry.id)
                activeCount -= 1
            }
            if !archiveIDs.isEmpty {
                for index in rows.indices where archiveIDs.contains(rows[index].id) {
                    rows[index].updateEngineState(for: key) { engineState in
                        engineState.state = .archived
                        engineState.dirty = true
                        engineState.generation &+= 1
                    }
                }
                rowsChanged = true
                archivedCount = archiveIDs.count
                pairs.removeAll { archiveIDs.contains($0.entry.id) }
            }
        }

        var capOverflow = false
        if pairs.count > AmiVoiceDictionarySyncPolicy.hardEntryLimit {
            capOverflow = true
            pairs = Array(pairs.prefix(AmiVoiceDictionarySyncPolicy.hardEntryLimit))
        }

        let family = AmiVoiceDictionaryEngineFamily(engine: key.engine)
        var seenPayloads = Set<String>()
        pairs = pairs.filter { pair in
            let dedupeKey = payloadDedupeKey(pair.payload, family: family)
            return seenPayloads.insert(dedupeKey).inserted
        }

        return SnapshotPreparation(
            rows: rows,
            pairs: pairs,
            rowsChanged: rowsChanged,
            locallyQuarantinedCount: locallyQuarantined,
            archivedCount: archivedCount,
            capOverflow: capOverflow
        )
    }

    private func payloadDedupeKey(
        _ payload: AmiVoiceDictionaryWordPayload,
        family: AmiVoiceDictionaryEngineFamily
    ) -> String {
        switch family {
        case .hybrid:
            return [payload.written, payload.spoken ?? "", payload.className ?? ""].joined(separator: "\u{1F}")
        case .e2e:
            return [payload.written, payload.alternativeWritten ?? ""].joined(separator: "\u{1F}")
        }
    }

    private func entriesMatching(
        rejection: AmiVoiceDictionaryEntryRejection?,
        pairs: [SnapshotPair],
        family: AmiVoiceDictionaryEngineFamily
    ) -> Set<UUID> {
        // An empty result means "cannot attribute"; the caller then isolates one
        // deterministic candidate instead of giving up.
        guard let rejection, let value = rejection.value else { return [] }
        var matched = Set<UUID>()
        for pair in pairs {
            let candidate: String?
            switch (rejection.field, family) {
            case (.written, _):
                candidate = pair.payload.written
            case (.spoken, .hybrid):
                candidate = pair.payload.spoken
            case (.className, .hybrid):
                candidate = pair.payload.className
            case (.alternativeWritten, .e2e):
                candidate = pair.payload.alternativeWritten
            case (.spoken, .e2e), (.className, .e2e), (.alternativeWritten, .hybrid), (.unknown, _):
                candidate = nil
            }
            if candidate == value {
                matched.insert(pair.entry.id)
            }
        }
        return matched
    }

    /// Deterministic isolation choice for an unattributable rejection: the oldest
    /// dirty ready-to-sync entry, never a protected one while an unprotected entry
    /// is still a candidate. B-1 has no separate "manual" provenance flag, so
    /// `isProtected` is the only user-protection signal available here.
    private func isolationCandidate(pairs: [SnapshotPair]) -> UUID? {
        let candidates = pairs.filter { pair in
            pair.engineState.state == .readyToSync && pair.engineState.dirty
        }
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.entry.isProtected != rhs.entry.isProtected {
                return !lhs.entry.isProtected
            }
            if lhs.entry.createdAt != rhs.entry.createdAt {
                return lhs.entry.createdAt < rhs.entry.createdAt
            }
            return lhs.entry.id.uuidString < rhs.entry.id.uuidString
        }
        return ordered.first?.entry.id
    }

    private func usableAPIKey() async -> String? {
        guard let rawKey = await apiKeyProvider() else { return nil }
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func ensureProfile(for key: AmiVoiceDictionaryProfileKey) -> AmiVoiceDictionaryProfile? {
        if let existing = store.profile(for: key) { return existing }
        guard let profileID = Self.generatedProfileID(engine: key.engine, samplingRate: key.samplingRate) else { return nil }
        let created = AmiVoiceDictionaryProfile(key: key, profileID: profileID)
        var profiles = store.loadProfiles()
        profiles.append(created)
        guard store.saveProfiles(profiles) else { return nil }
        return created
    }

    @discardableResult private func updateProfile(_ updated: AmiVoiceDictionaryProfile) -> Bool {
        var profiles = store.loadProfiles()
        if let index = profiles.firstIndex(where: { $0.key == updated.key }) {
            profiles[index] = updated
        } else {
            profiles.append(updated)
        }
        return store.saveProfiles(profiles)
    }

    private func recordTemporaryFailure(
        _ failure: AmiVoiceDictionaryTemporaryFailure,
        profile: inout AmiVoiceDictionaryProfile
    ) {
        profile.consecutiveTemporaryFailures += 1
        profile.lastResult = .temporaryFailure
        switch failure {
        case .network, .cancelled:
            profile.lastErrorClass = .network
        case .timeout:
            profile.lastErrorClass = .timeout
        case .serverStatus(_), .unexpectedStatus(_):
            profile.lastErrorClass = .server
        }
        if profile.consecutiveTemporaryFailures <= AmiVoiceDictionarySyncPolicy.maximumAutomaticRetryCount {
            let delay = AmiVoiceDictionarySyncPolicy.temporaryBackoff(failureCount: profile.consecutiveTemporaryFailures)
            profile.backoffUntil = now().addingTimeInterval(delay)
        } else {
            profile.backoffUntil = nil
        }
    }

    private func scheduleRetryIfNeeded(
        for key: AmiVoiceDictionaryProfileKey,
        profile: AmiVoiceDictionaryProfile,
        verifyConsistency: Bool = false,
        forceUpload: Bool = false
    ) {
        cancelScheduledRetry(for: key)
        guard profile.consecutiveTemporaryFailures <= AmiVoiceDictionarySyncPolicy.maximumAutomaticRetryCount,
              let backoffUntil = profile.backoffUntil else { return }
        if verifyConsistency {
            retryRequiresLaunchConsistency.insert(key)
        }
        if forceUpload {
            retryForcesUpload.insert(key)
        }
        let delay = max(0, backoffUntil.timeIntervalSince(now()))
        retryTasks[key] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            await self.retryAfterBackoff(for: key)
        }
    }

    private func cancelScheduledRetry(for key: AmiVoiceDictionaryProfileKey) {
        retryTasks[key]?.cancel()
        retryTasks[key] = nil
        retryRequiresLaunchConsistency.remove(key)
        retryForcesUpload.remove(key)
    }

    private func recordStoreFailure(
        profile: AmiVoiceDictionaryProfile,
        key: AmiVoiceDictionaryProfileKey
    ) {
        var updated = profile
        updated.lastResult = .storeFailure
        updated.lastErrorClass = .store
        _ = updateProfile(updated)
        notifyStatus(key)
    }

    private func notifyStatus(_ key: AmiVoiceDictionaryProfileKey) {
        statusObserver?(key)
    }
}
