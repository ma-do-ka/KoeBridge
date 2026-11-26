import Foundation

public enum AmiVoiceDictionarySyncTrigger: String, Sendable {
    case debounced
    case userAction = "user_action"
    case launch
    case retry
    case deleteAll = "delete_all"
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
        var needsUpload = profile.lastSyncedFingerprint != desiredFingerprint || hasDirtyRows
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
            } else if serverFingerprint != desiredFingerprint,
                      !fetched.isEmpty || !desiredPayloads.isEmpty || profile.lastSyncedFingerprint != nil {
                needsUpload = true
            }
        } catch let error as AmiVoiceDictionaryTransportError {
            fetchFailure = error
            if error == .profileMissing {
                needsUpload = !desiredPayloads.isEmpty || profile.lastSyncedFingerprint != nil || hasDirtyRows
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
                scheduleRetryIfNeeded(for: key, profile: updated)
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
            var updated = profile
            updated.lastResult = .noChanges
            updated.lastErrorClass = nil
            updated.consecutiveTemporaryFailures = 0
            updated.backoffUntil = nil
            if serverPayloads != nil, updated.lastSyncedFingerprint == nil {
                updated.lastSyncedFingerprint = desiredFingerprint
            }
            _ = updateProfile(updated)
            notifyStatus(key)
            return AmiVoiceDictionarySyncOutcome(kind: .noChanges, profileKey: key, timestamp: now())
        }
        return await performSync(for: key, trigger: .launch, forceUpload: false)
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
        Task { [weak self] in
            guard let self else { return }
            _ = await self.performSync(for: key, trigger: .retry, forceUpload: false)
        }
    }

    private func performSync(
        for key: AmiVoiceDictionaryProfileKey,
        trigger: AmiVoiceDictionarySyncTrigger,
        forceUpload: Bool
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
        if (trigger == .userAction || trigger == .launch || trigger == .deleteAll) && profile.authenticationBlocked {
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
            let noPriorSync = profile.lastSyncedFingerprint == nil
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
                    quarantinedCount: preparation.locallyQuarantinedCount,
                    archivedCount: preparation.archivedCount,
                    timestamp: now()
                )
            }
            if payloads.isEmpty && noPriorSync && !hasDirtyRows && !forceUpload {
                var updated = profile
                updated.lastResult = preparation.locallyQuarantinedCount > 0 ? .validationFailed : .noChanges
                updated.lastErrorClass = preparation.locallyQuarantinedCount > 0 ? .validation : nil
                _ = updateProfile(updated)
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(
                    kind: updated.lastResult ?? .noChanges,
                    profileKey: key,
                    quarantinedCount: preparation.locallyQuarantinedCount,
                    archivedCount: preparation.archivedCount,
                    timestamp: now()
                )
            }

            let generationByID = Dictionary(uniqueKeysWithValues: preparation.pairs.map { ($0.entry.id, $0.engineState.generation) })
            do {
                _ = try await transport.replaceWords(
                    engine: key.engine,
                    samplingRate: key.samplingRate,
                    profileID: profile.profileID,
                    apiKey: apiKey,
                    payloads: payloads
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
                            engineState.lastSyncedAt = finishedAt
                        }
                    } else if !currentState.state.participatesInSnapshot && currentState.dirty {
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
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(
                    kind: updated.lastResult ?? .success,
                    profileKey: key,
                    uploadedCount: payloads.count,
                    quarantinedCount: preparation.locallyQuarantinedCount + totalServerQuarantined,
                    archivedCount: preparation.archivedCount,
                    timestamp: finishedAt
                )
            } catch AmiVoiceDictionaryTransportError.entryValidation(let rejection) {
                let matchedIDs = entriesMatching(
                    rejection: rejection,
                    pairs: preparation.pairs,
                    family: AmiVoiceDictionaryEngineFamily(engine: key.engine)
                )
                guard !matchedIDs.isEmpty,
                      validationAttempts < AmiVoiceDictionarySyncPolicy.maximumValidationIsolationAttempts else {
                    var updated = profile
                    updated.lastResult = .validationFailed
                    updated.lastErrorClass = .validation
                    _ = updateProfile(updated)
                    notifyStatus(key)
                    return AmiVoiceDictionarySyncOutcome(
                        kind: .validationFailed,
                        profileKey: key,
                        quarantinedCount: preparation.locallyQuarantinedCount + totalServerQuarantined,
                        archivedCount: preparation.archivedCount,
                        timestamp: now()
                    )
                }
                validationAttempts += 1
                totalServerQuarantined += matchedIDs.count
                rows = store.loadEntries()
                for index in rows.indices where matchedIDs.contains(rows[index].id) {
                    rows[index].updateEngineState(for: key) { engineState in
                        engineState.state = .syncFailed
                        engineState.dirty = true
                        engineState.failureCount += 1
                        engineState.lastErrorClass = .validation
                        engineState.generation &+= 1
                    }
                }
                guard store.saveEntries(rows) else {
                    recordStoreFailure(profile: profile, key: key)
                    return AmiVoiceDictionarySyncOutcome(kind: .storeFailure, profileKey: key, timestamp: now())
                }
                notifyStatus(key)
                continue
            } catch AmiVoiceDictionaryTransportError.authentication {
                var updated = profile
                updated.lastResult = .authenticationRejected
                updated.lastErrorClass = .authenticationRejected
                updated.authenticationBlocked = true
                updated.backoffUntil = nil
                _ = updateProfile(updated)
                retryTasks[key]?.cancel()
                retryTasks[key] = nil
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(kind: .authenticationRejected, profileKey: key, timestamp: now())
            } catch AmiVoiceDictionaryTransportError.limitExceeded {
                var updated = profile
                updated.lastResult = .capExceeded
                updated.lastErrorClass = .capExceeded
                _ = updateProfile(updated)
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(kind: .capExceeded, profileKey: key, timestamp: now())
            } catch AmiVoiceDictionaryTransportError.temporary(let temporary) {
                var updated = profile
                recordTemporaryFailure(temporary, profile: &updated)
                _ = updateProfile(updated)
                scheduleRetryIfNeeded(for: key, profile: updated)
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(kind: .temporaryFailure, profileKey: key, timestamp: now())
            } catch AmiVoiceDictionaryTransportError.profileMissing {
                var updated = profile
                recordTemporaryFailure(.serverStatus(404), profile: &updated)
                updated.lastErrorClass = .profileMissing
                _ = updateProfile(updated)
                scheduleRetryIfNeeded(for: key, profile: updated)
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(kind: .temporaryFailure, profileKey: key, timestamp: now())
            } catch AmiVoiceDictionaryTransportError.malformedResponse {
                var updated = profile
                recordTemporaryFailure(.serverStatus(500), profile: &updated)
                _ = updateProfile(updated)
                scheduleRetryIfNeeded(for: key, profile: updated)
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(kind: .temporaryFailure, profileKey: key, timestamp: now())
            } catch AmiVoiceDictionaryTransportError.invalidRequest {
                var updated = profile
                recordTemporaryFailure(.serverStatus(500), profile: &updated)
                _ = updateProfile(updated)
                scheduleRetryIfNeeded(for: key, profile: updated)
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(kind: .temporaryFailure, profileKey: key, timestamp: now())
            } catch {
                var updated = profile
                recordTemporaryFailure(.network, profile: &updated)
                _ = updateProfile(updated)
                scheduleRetryIfNeeded(for: key, profile: updated)
                notifyStatus(key)
                return AmiVoiceDictionarySyncOutcome(kind: .temporaryFailure, profileKey: key, timestamp: now())
            }
        }

        var updated = profile
        updated.lastResult = .validationFailed
        updated.lastErrorClass = .validation
        _ = updateProfile(updated)
        notifyStatus(key)
        return AmiVoiceDictionarySyncOutcome(
            kind: .validationFailed,
            profileKey: key,
            quarantinedCount: (lastPreparation?.locallyQuarantinedCount ?? 0) + totalServerQuarantined,
            archivedCount: lastPreparation?.archivedCount ?? 0,
            timestamp: now()
        )
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
        guard let rejection else { return fallbackSingleDirtyReadyEntry(pairs: pairs) }
        guard let value = rejection.value else { return fallbackSingleDirtyReadyEntry(pairs: pairs) }
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
        return matched.isEmpty ? fallbackSingleDirtyReadyEntry(pairs: pairs) : matched
    }

    private func fallbackSingleDirtyReadyEntry(pairs: [SnapshotPair]) -> Set<UUID> {
        let candidates = pairs.filter { pair in
            pair.engineState.state == .readyToSync && pair.engineState.dirty
        }
        guard candidates.count == 1, let only = candidates.first else { return [] }
        return [only.entry.id]
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
        profile: AmiVoiceDictionaryProfile
    ) {
        retryTasks[key]?.cancel()
        retryTasks[key] = nil
        guard profile.consecutiveTemporaryFailures <= AmiVoiceDictionarySyncPolicy.maximumAutomaticRetryCount,
              let backoffUntil = profile.backoffUntil else { return }
        let delay = max(0, backoffUntil.timeIntervalSince(now()))
        retryTasks[key] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            await self.retryAfterBackoff(for: key)
        }
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
