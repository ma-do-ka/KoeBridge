import Foundation
import KoeBridgeCore

final class SelfTestMockAmiVoiceDictionaryTransport: AmiVoiceDictionaryTransport, @unchecked Sendable {
    struct Call {
        var method: String
        var payloads: [AmiVoiceDictionaryWordPayload]
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    var fetchHandler: (@Sendable () async throws -> [AmiVoiceDictionaryWordPayload])?
    var replaceHandler: (@Sendable ([AmiVoiceDictionaryWordPayload]) async throws -> [AmiVoiceDictionaryWordPayload])?

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func resetCalls() {
        lock.lock()
        recordedCalls.removeAll()
        lock.unlock()
    }

    func fetchWords(engine: AmiVoiceEngine, samplingRate: AmiVoiceDictionarySamplingRate,
                    profileID: AmiVoiceProfileID, apiKey: String) async throws -> [AmiVoiceDictionaryWordPayload] {
        append(Call(method: "GET", payloads: []))
        if let fetchHandler { return try await fetchHandler() }
        return []
    }

    func replaceWords(engine: AmiVoiceEngine, samplingRate: AmiVoiceDictionarySamplingRate,
                      profileID: AmiVoiceProfileID, apiKey: String,
                      payloads: [AmiVoiceDictionaryWordPayload]) async throws -> [AmiVoiceDictionaryWordPayload] {
        append(Call(method: "POST", payloads: payloads))
        if let replaceHandler { return try await replaceHandler(payloads) }
        return payloads
    }

    private func append(_ call: Call) {
        lock.lock()
        recordedCalls.append(call)
        lock.unlock()
    }
}

final class SelfTestRecordedDictionaryHTTPRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var all: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}

struct AmiVoiceDictionarySyncTests {
    func payloadShapeFullOverwriteAndEmptyDeletePerEngineFamily() async throws {
        let recorder = SelfTestRecordedDictionaryHTTPRequests()
        let client = AmiVoiceDictionaryAPIClient { request in
            recorder.append(request)
            let response = try require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (request.httpBody ?? Data(), response)
        }
        let profileID = try require(AmiVoiceProfileID("kb_test_profile"))
        _ = try await client.replaceWords(
            engine: .hybridJapaneseConversation,
            samplingRate: .rate16k,
            profileID: profileID,
            apiKey: "fixture-key",
            payloads: [.hybrid(written: "霧峰システム", spoken: "きりみねしすてむ", className: "固有名詞")]
        )
        let hybridRequest = try require(recorder.all.last)
        check(hybridRequest.url?.absoluteString == "https://acp-api.amivoice.com/profilewords/-a-general/kb_test_profile?adf=16k")
        let hybridBody = try require(JSONSerialization.jsonObject(with: try require(hybridRequest.httpBody)) as? [String: Any])
        let hybridRows = try require(hybridBody["profilewords"] as? [[String: Any]])
        check(hybridRows.first?["written"] as? String == "霧峰システム")
        check(hybridRows.first?["spoken"] as? String == "きりみねしすてむ")
        check(hybridRows.first?["classname"] as? String == "固有名詞")
        check(hybridRows.first?["alternativewritten"] == nil)

        _ = try await client.replaceWords(
            engine: .e2eJapaneseGeneral,
            samplingRate: .rate16k,
            profileID: profileID,
            apiKey: "fixture-key",
            payloads: [.e2e(written: "KoeBridge", alternativeWritten: "コエブリッジ", biasing: 0.8)]
        )
        let e2eBody = try require(JSONSerialization.jsonObject(with: try require(recorder.all.last?.httpBody)) as? [String: Any])
        let e2eRows = try require(e2eBody["profilewords"] as? [[String: Any]])
        check(e2eRows.first?["written"] as? String == "KoeBridge")
        check(e2eRows.first?["alternativewritten"] as? String == "コエブリッジ")
        check(e2eRows.first?["spoken"] == nil)
        check(e2eRows.first?["classname"] == nil)

        _ = try await client.replaceWords(
            engine: .e2eJapaneseGeneral,
            samplingRate: .rate16k,
            profileID: profileID,
            apiKey: "fixture-key",
            payloads: []
        )
        let emptyBody = try require(JSONSerialization.jsonObject(with: try require(recorder.all.last?.httpBody)) as? [String: Any])
        check((emptyBody["profilewords"] as? [Any])?.isEmpty == true)
    }

    func serverValidationRejectionQuarantinesOnlyBadEntryAndResyncsRest() async throws {
        let suite = "KoeBridge.AmiVoiceSyncSelfTest." + UUID().uuidString
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AmiVoiceDictionarySyncStore(defaults: defaults)
        let transport = SelfTestMockAmiVoiceDictionaryTransport()
        let engine = AmiVoiceDictionarySyncEngine(store: store, transport: transport, apiKeyProvider: { "fixture-key" })
        let key = AmiVoiceDictionaryProfileKey(engine: .e2eJapaneseGeneral, samplingRate: .rate16k)
        let goodID = UUID()
        let badID = UUID()
        let upsertGood = await engine.upsertEntry(AmiVoiceDictionaryEntry(id: goodID, written: "KoeBridge"), for: key, state: .readyToSync)
        let upsertBad = await engine.upsertEntry(AmiVoiceDictionaryEntry(id: badID, written: "BadWord"), for: key, state: .readyToSync)
        check(upsertGood)
        check(upsertBad)
        await engine.setAutomaticSyncEnabled(true)
        transport.replaceHandler = { payloads in
            if payloads.contains(where: { $0.written == "BadWord" }) {
                throw AmiVoiceDictionaryTransportError.entryValidation(
                    AmiVoiceDictionaryEntryRejection(field: .written, value: "BadWord")
                )
            }
            return payloads
        }
        let outcome = await engine.syncNow(for: key)
        check(outcome.kind == .success)
        let posts = transport.calls.filter { $0.method == "POST" }
        check(posts.count == 2)
        check(posts[1].payloads.map(\.written) == ["KoeBridge"])
        let rows = await engine.entries()
        check(rows.first { $0.id == badID }?.engineState(for: key)?.state == .syncFailed)
        check(rows.first { $0.id == goodID }?.engineState(for: key)?.state == .autoSynced)
    }

    func launchPassRestoresFullSnapshotWhenServerProfileIsEmpty() async throws {
        let suite = "KoeBridge.AmiVoiceSyncSelfTest." + UUID().uuidString
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AmiVoiceDictionarySyncStore(defaults: defaults)
        let transport = SelfTestMockAmiVoiceDictionaryTransport()
        let engine = AmiVoiceDictionarySyncEngine(store: store, transport: transport, apiKeyProvider: { "fixture-key" })
        let key = AmiVoiceDictionaryProfileKey(engine: .hybridJapaneseConversation, samplingRate: .rate16k)
        let upserted = await engine.upsertEntry(
            AmiVoiceDictionaryEntry(written: "霧峰システム", spoken: "きりみねしすてむ"),
            for: key,
            state: .readyToSync
        )
        check(upserted)
        await engine.setAutomaticSyncEnabled(true)
        let syncResult = await engine.syncNow(for: key)
        check(syncResult.kind == .success)
        transport.resetCalls()
        transport.fetchHandler = { [] }
        let outcome = await engine.performLaunchConsistencyPass(for: key)
        check(outcome.kind == .success)
        check(transport.calls.map(\.method) == ["GET", "POST"])
        check(transport.calls.last?.payloads.count == 1)
    }

    func optInOffMakesEveryEntryPointZeroTransportCalls() async throws {
        let suite = "KoeBridge.AmiVoiceSyncSelfTest." + UUID().uuidString
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AmiVoiceDictionarySyncStore(defaults: defaults)
        let transport = SelfTestMockAmiVoiceDictionaryTransport()
        let engine = AmiVoiceDictionarySyncEngine(store: store, transport: transport, apiKeyProvider: { "fixture-key" })
        let key = AmiVoiceDictionaryProfileKey(engine: .e2eJapaneseGeneral, samplingRate: .rate16k)
        let upserted = await engine.upsertEntry(AmiVoiceDictionaryEntry(written: "KoeBridge"), for: key, state: .readyToSync)
        await engine.scheduleDebouncedSync(for: key)
        let syncResult = await engine.syncNow(for: key)
        let passResult = await engine.performLaunchConsistencyPass(for: key)
        let deleteResult = await engine.deleteAllServerWords(for: key)
        check(upserted)
        check(syncResult.kind == .disabled)
        check(passResult.kind == .disabled)
        check(deleteResult.kind == .disabled)
        check(transport.calls.isEmpty)
    }

    func recognitionProfileReferenceIsConditionalAndOffPathByteIdentical() throws {
        let key = AmiVoiceDictionaryProfileKey(engine: .e2eJapaneseGeneral, samplingRate: .rate16k)
        let profileID = try require(AmiVoiceProfileID("kb_test_profile"))
        var entry = AmiVoiceDictionaryEntry(written: "KoeBridge")
        entry.updateEngineState(for: key) { state in
            state.state = .autoSynced
        }
        let profile = AmiVoiceDictionaryProfile(key: key, profileID: profileID)
        check(AmiVoiceDictionarySyncPolicy.recognitionProfileID(
            automaticSyncEnabled: false, entries: [entry], profile: profile, key: key) == nil)
        check(AmiVoiceDictionarySyncPolicy.recognitionProfileID(
            automaticSyncEnabled: true, entries: [entry], profile: nil, key: key) == nil)
        check(AmiVoiceDictionarySyncPolicy.recognitionProfileID(
            automaticSyncEnabled: true, entries: [entry], profile: profile, key: key) == profileID.rawValue)
        let offCommand = AmiVoiceWire.startCommand(engine: .e2eJapaneseGeneral, profileWords: ["KoeBridge"], profileId: nil)
        check(offCommand == #"s LSB16K -a2-ja-general resultUpdatedInterval=300 profileWords="KoeBridge""#)
        let onCommand = AmiVoiceWire.startCommand(engine: .e2eJapaneseGeneral, profileWords: ["KoeBridge"], profileId: profileID.rawValue)
        check(onCommand == "s LSB16K -a2-ja-general resultUpdatedInterval=300 profileId=:kb_test_profile")
    }

    func unattributedServerRejectionIsolatesOneEntryAndResyncsRest() async throws {
        let suite = "KoeBridge.AmiVoiceSyncSelfTest." + UUID().uuidString
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AmiVoiceDictionarySyncStore(defaults: defaults)
        let transport = SelfTestMockAmiVoiceDictionaryTransport()
        let engine = AmiVoiceDictionarySyncEngine(store: store, transport: transport, apiKeyProvider: { "fixture-key" })
        let key = AmiVoiceDictionaryProfileKey(engine: .e2eJapaneseGeneral, samplingRate: .rate16k)
        let badID = UUID()
        let goodID = UUID()
        let upsertBad = await engine.upsertEntry(
            AmiVoiceDictionaryEntry(id: badID, written: "BadWord", createdAt: Date(timeIntervalSince1970: 1_000)),
            for: key,
            state: .readyToSync
        )
        let upsertGood = await engine.upsertEntry(
            AmiVoiceDictionaryEntry(id: goodID, written: "KoeBridge", createdAt: Date(timeIntervalSince1970: 2_000)),
            for: key,
            state: .readyToSync
        )
        check(upsertBad)
        check(upsertGood)
        await engine.setAutomaticSyncEnabled(true)
        transport.replaceHandler = { payloads in
            if payloads.contains(where: { $0.written == "BadWord" }) {
                throw AmiVoiceDictionaryTransportError.entryValidation(nil)
            }
            return payloads
        }
        let outcome = await engine.syncNow(for: key)
        check(outcome.kind == .success)
        check(outcome.quarantinedCount == 1)
        let posts = transport.calls.filter { $0.method == "POST" }
        check(posts.count == 2)
        check(Set(posts[0].payloads.map(\.written)) == ["BadWord", "KoeBridge"])
        check(posts[1].payloads.map(\.written) == ["KoeBridge"])
        let rows = await engine.entries()
        check(rows.first { $0.id == badID }?.engineState(for: key)?.state == .syncFailed)
        check(rows.first { $0.id == badID }?.engineState(for: key)?.lastErrorDetail
            == "unattributed validation rejection (isolation)")
        check(rows.first { $0.id == goodID }?.engineState(for: key)?.state == .autoSynced)
        let status = await engine.status(for: key)
        check(status.quarantinedCount == 1)
        check(status.pendingReviewCount == 0)
    }

    func unattributableRejectionNeverPostsIdenticalFailingSetTwice() async throws {
        let suite = "KoeBridge.AmiVoiceSyncSelfTest." + UUID().uuidString
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AmiVoiceDictionarySyncStore(defaults: defaults)
        let transport = SelfTestMockAmiVoiceDictionaryTransport()
        let engine = AmiVoiceDictionarySyncEngine(store: store, transport: transport, apiKeyProvider: { "fixture-key" })
        let key = AmiVoiceDictionaryProfileKey(engine: .e2eJapaneseGeneral, samplingRate: .rate16k)
        let firstInsert = await engine.upsertEntry(
            AmiVoiceDictionaryEntry(written: "AlphaWord", createdAt: Date(timeIntervalSince1970: 1_000)),
            for: key,
            state: .readyToSync
        )
        let secondInsert = await engine.upsertEntry(
            AmiVoiceDictionaryEntry(written: "BetaWord", createdAt: Date(timeIntervalSince1970: 2_000)),
            for: key,
            state: .readyToSync
        )
        check(firstInsert)
        check(secondInsert)
        await engine.setAutomaticSyncEnabled(true)
        transport.replaceHandler = { _ in throw AmiVoiceDictionaryTransportError.entryValidation(nil) }
        let first = await engine.syncNow(for: key)
        let second = await engine.syncNow(for: key)
        let third = await engine.syncNow(for: key, trigger: .retry)
        check(first.kind == .validationFailed)
        check(second.kind == .validationFailed)
        check(third.kind == .validationFailed)
        let signatures = transport.calls
            .filter { $0.method == "POST" }
            .map { $0.payloads.map(\.written).sorted().joined(separator: ",") }
        check(signatures == ["AlphaWord,BetaWord", "BetaWord"])
        let rows = await engine.entries()
        check(rows.allSatisfy { $0.engineState(for: key)?.state == .syncFailed })
        let status = await engine.status(for: key)
        check(status.quarantinedCount == 2)
    }

    func isolationPrefersUnprotectedEntriesOverProtectedOnes() async throws {
        let suite = "KoeBridge.AmiVoiceSyncSelfTest." + UUID().uuidString
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AmiVoiceDictionarySyncStore(defaults: defaults)
        let transport = SelfTestMockAmiVoiceDictionaryTransport()
        let engine = AmiVoiceDictionarySyncEngine(store: store, transport: transport, apiKeyProvider: { "fixture-key" })
        let key = AmiVoiceDictionaryProfileKey(engine: .e2eJapaneseGeneral, samplingRate: .rate16k)
        let protectedInsert = await engine.upsertEntry(
            AmiVoiceDictionaryEntry(
                written: "ProtectedWord",
                isProtected: true,
                createdAt: Date(timeIntervalSince1970: 1_000)
            ),
            for: key,
            state: .readyToSync
        )
        let plainInsert = await engine.upsertEntry(
            AmiVoiceDictionaryEntry(written: "PlainWord", createdAt: Date(timeIntervalSince1970: 2_000)),
            for: key,
            state: .readyToSync
        )
        check(protectedInsert)
        check(plainInsert)
        await engine.setAutomaticSyncEnabled(true)
        transport.replaceHandler = { payloads in
            if payloads.contains(where: { $0.written == "ProtectedWord" }) {
                throw AmiVoiceDictionaryTransportError.entryValidation(nil)
            }
            return payloads
        }
        let outcome = await engine.syncNow(for: key)
        check(outcome.kind == .validationFailed)
        let posts = transport.calls.filter { $0.method == "POST" }
        check(posts.allSatisfy { $0.payloads.contains { payload in payload.written == "ProtectedWord" } })
        check(posts.last?.payloads.map(\.written) == ["ProtectedWord"])
        let rows = await engine.entries()
        check(rows.allSatisfy { $0.engineState(for: key)?.state == .syncFailed })
    }

    func hybridSpokenMustBeKanaAndPendingReviewIsCountedSeparately() async throws {
        checkThrows(AmiVoiceDictionaryValidationFailure.self) {
            _ = try AmiVoiceDictionaryValidator.payload(
                for: AmiVoiceDictionaryEntry(written: "KoeBridge", spoken: "KoeBridge"),
                engine: .hybridJapaneseConversation
            )
        }
        checkThrows(AmiVoiceDictionaryValidationFailure.self) {
            _ = try AmiVoiceDictionaryValidator.payload(
                for: AmiVoiceDictionaryEntry(written: "KoeBridge", spoken: "こえぶりっじ2"),
                engine: .hybridJapaneseConversation
            )
        }
        let kana = try AmiVoiceDictionaryValidator.payload(
            for: AmiVoiceDictionaryEntry(written: "霧峰システム", spoken: "きりみねしすてむ"),
            engine: .hybridJapaneseConversation
        )
        check(kana.spoken == "きりみねしすてむ")
        let katakana = try AmiVoiceDictionaryValidator.payload(
            for: AmiVoiceDictionaryEntry(written: "コエブリッジ", spoken: "コーエブリッジ"),
            engine: .hybridJapaneseConversation
        )
        check(katakana.spoken == "コーエブリッジ")
        let e2e = try AmiVoiceDictionaryValidator.payload(
            for: AmiVoiceDictionaryEntry(written: "KoeBridge", spoken: "KoeBridge"),
            engine: .e2eJapaneseGeneral
        )
        check(e2e.spoken == nil)

        let suite = "KoeBridge.AmiVoiceSyncSelfTest." + UUID().uuidString
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AmiVoiceDictionarySyncStore(defaults: defaults)
        let transport = SelfTestMockAmiVoiceDictionaryTransport()
        let engine = AmiVoiceDictionarySyncEngine(store: store, transport: transport, apiKeyProvider: { "fixture-key" })
        let key = AmiVoiceDictionaryProfileKey(engine: .hybridJapaneseConversation, samplingRate: .rate16k)
        let entryID = UUID()
        let inserted = await engine.upsertEntry(
            AmiVoiceDictionaryEntry(id: entryID, written: "BadEntry", spoken: "BadEntry"),
            for: key,
            state: .readyToSync
        )
        check(inserted)
        await engine.setAutomaticSyncEnabled(true)
        let outcome = await engine.syncNow(for: key)
        check(outcome.kind == .validationFailed)
        check(transport.calls.isEmpty)
        let rows = await engine.entries()
        check(rows.first { $0.id == entryID }?.engineState(for: key)?.state == .pendingReview)
        let status = await engine.status(for: key)
        check(status.pendingReviewCount == 1)
        check(status.quarantinedCount == 0)
    }

    func corruptPersistedStoreRecoversOnNextSyncInsteadOfStoreFailure() async throws {
        let suite = "KoeBridge.AmiVoiceSyncSelfTest." + UUID().uuidString
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: AmiVoiceDictionarySyncStore.entriesKey)
        defaults.set(corrupt, forKey: AmiVoiceDictionarySyncStore.profilesKey)
        let store = AmiVoiceDictionarySyncStore(defaults: defaults)
        let transport = SelfTestMockAmiVoiceDictionaryTransport()
        let engine = AmiVoiceDictionarySyncEngine(store: store, transport: transport, apiKeyProvider: { "fixture-key" })
        let key = AmiVoiceDictionaryProfileKey(engine: .e2eJapaneseGeneral, samplingRate: .rate16k)
        await engine.setAutomaticSyncEnabled(true)
        check(store.loadEntries().isEmpty)
        check(store.loadProfiles().isEmpty)
        let inserted = await engine.upsertEntry(AmiVoiceDictionaryEntry(written: "KoeBridge"), for: key, state: .readyToSync)
        check(inserted)
        let outcome = await engine.syncNow(for: key)
        check(outcome.kind == .success)
        check(outcome.uploadedCount == 1)
        let rows = await engine.entries()
        check(rows.count == 1)
    }
}
