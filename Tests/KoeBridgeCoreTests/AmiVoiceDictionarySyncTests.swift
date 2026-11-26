import Foundation
import Testing
@testable import KoeBridgeCore

final class MockAmiVoiceDictionaryTransport: AmiVoiceDictionaryTransport, @unchecked Sendable {
    struct Call {
        var method: String
        var engine: AmiVoiceEngine
        var samplingRate: AmiVoiceDictionarySamplingRate
        var profileID: AmiVoiceProfileID
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

    func fetchWords(
        engine: AmiVoiceEngine,
        samplingRate: AmiVoiceDictionarySamplingRate,
        profileID: AmiVoiceProfileID,
        apiKey: String
    ) async throws -> [AmiVoiceDictionaryWordPayload] {
        append(Call(method: "GET", engine: engine, samplingRate: samplingRate, profileID: profileID, payloads: []))
        if let fetchHandler { return try await fetchHandler() }
        return []
    }

    func replaceWords(
        engine: AmiVoiceEngine,
        samplingRate: AmiVoiceDictionarySamplingRate,
        profileID: AmiVoiceProfileID,
        apiKey: String,
        payloads: [AmiVoiceDictionaryWordPayload]
    ) async throws -> [AmiVoiceDictionaryWordPayload] {
        append(Call(method: "POST", engine: engine, samplingRate: samplingRate, profileID: profileID, payloads: payloads))
        if let replaceHandler { return try await replaceHandler(payloads) }
        return payloads
    }

    private func append(_ call: Call) {
        lock.lock()
        recordedCalls.append(call)
        lock.unlock()
    }
}

final class RecordedDictionaryHTTPRequests: @unchecked Sendable {
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
    @Test func payloadShapeFullOverwriteAndEmptyDeletePerEngineFamily() async throws {
        let recorder = RecordedDictionaryHTTPRequests()
        let client = AmiVoiceDictionaryAPIClient { request in
            recorder.append(request)
            let body = request.httpBody ?? Data()
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (body, response)
        }
        let profileID = try #require(AmiVoiceProfileID("kb_test_profile"))

        let hybridPayloads = [AmiVoiceDictionaryWordPayload.hybrid(written: "霧峰システム", spoken: "きりみねしすてむ", className: "固有名詞")]
        _ = try await client.replaceWords(
            engine: .hybridJapaneseConversation,
            samplingRate: .rate16k,
            profileID: profileID,
            apiKey: "fixture-key",
            payloads: hybridPayloads
        )
        let hybridRequest = try #require(recorder.all.last)
        #expect(hybridRequest.httpMethod == "POST")
        #expect(hybridRequest.url?.absoluteString == "https://acp-api.amivoice.com/profilewords/-a-general/kb_test_profile?adf=16k")
        #expect(hybridRequest.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        let hybridBodyData = try #require(hybridRequest.httpBody)
        let hybridBody = try #require(JSONSerialization.jsonObject(with: hybridBodyData) as? [String: Any])
        let hybridRows = try #require(hybridBody["profilewords"] as? [[String: Any]])
        #expect(hybridRows.count == 1)
        #expect(hybridRows[0]["written"] as? String == "霧峰システム")
        #expect(hybridRows[0]["spoken"] as? String == "きりみねしすてむ")
        #expect(hybridRows[0]["classname"] as? String == "固有名詞")
        #expect(hybridRows[0]["alternativewritten"] == nil)
        #expect(hybridRows[0]["biasing"] == nil)

        let e2ePayloads = [AmiVoiceDictionaryWordPayload.e2e(written: "KoeBridge", alternativeWritten: "コエブリッジ", biasing: 0.8)]
        _ = try await client.replaceWords(
            engine: .e2eJapaneseGeneral,
            samplingRate: .rate16k,
            profileID: profileID,
            apiKey: "fixture-key",
            payloads: e2ePayloads
        )
        let e2eBodyData = try #require(recorder.all.last?.httpBody)
        let e2eBody = try #require(JSONSerialization.jsonObject(with: e2eBodyData) as? [String: Any])
        let e2eRows = try #require(e2eBody["profilewords"] as? [[String: Any]])
        #expect(e2eRows.count == 1)
        #expect(e2eRows[0]["written"] as? String == "KoeBridge")
        #expect(e2eRows[0]["alternativewritten"] as? String == "コエブリッジ")
        #expect(e2eRows[0]["biasing"] as? Double == 0.8)
        #expect(e2eRows[0]["spoken"] == nil)
        #expect(e2eRows[0]["classname"] == nil)

        _ = try await client.replaceWords(
            engine: .e2eJapaneseGeneral,
            samplingRate: .rate16k,
            profileID: profileID,
            apiKey: "fixture-key",
            payloads: []
        )
        let emptyBodyData = try #require(recorder.all.last?.httpBody)
        let emptyBody = try #require(JSONSerialization.jsonObject(with: emptyBodyData) as? [String: Any])
        #expect((emptyBody["profilewords"] as? [Any])?.isEmpty == true)
    }

    @Test func perEngineProfileSeparationAndIDRuleEnforcement() throws {
        #expect(AmiVoiceProfileID("__reserved") == nil)
        #expect(AmiVoiceProfileID("has space") == nil)
        #expect(AmiVoiceProfileID("日本語") == nil)
        #expect(AmiVoiceProfileID("valid_profile-1")?.recognitionReference == ":valid_profile-1")

        let uuid = UUID()
        let hybrid16 = AmiVoiceDictionaryProfileKey(engine: .hybridJapaneseConversation, samplingRate: .rate16k)
        let hybrid8 = AmiVoiceDictionaryProfileKey(engine: .hybridJapaneseConversation, samplingRate: .rate8k)
        let e2e16 = AmiVoiceDictionaryProfileKey(engine: .e2eJapaneseGeneral, samplingRate: .rate16k)
        #expect(hybrid16 != hybrid8)
        #expect(hybrid16 != e2e16)
        let id16 = try #require(AmiVoiceDictionarySyncEngine.generatedProfileID(engine: hybrid16.engine, samplingRate: hybrid16.samplingRate, uuid: uuid))
        let id8 = try #require(AmiVoiceDictionarySyncEngine.generatedProfileID(engine: hybrid8.engine, samplingRate: hybrid8.samplingRate, uuid: uuid))
        #expect(id16 != id8)
        #expect(AmiVoiceWire.sanitizeProfileId(id16.rawValue) == id16.rawValue)
        #expect(!id16.rawValue.hasPrefix("__"))
    }

    @Test func serverValidationRejectionQuarantinesOnlyBadEntryAndResyncsRest() async throws {
        let suite = "KoeBridge.AmiVoiceSync." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AmiVoiceDictionarySyncStore(defaults: defaults)
        let transport = MockAmiVoiceDictionaryTransport()
        let engine = AmiVoiceDictionarySyncEngine(store: store, transport: transport, apiKeyProvider: { "fixture-key" })
        let key = AmiVoiceDictionaryProfileKey(engine: .e2eJapaneseGeneral, samplingRate: .rate16k)
        let goodID = UUID()
        let badID = UUID()
        #expect(await engine.upsertEntry(AmiVoiceDictionaryEntry(id: goodID, written: "KoeBridge"), for: key, state: .readyToSync))
        #expect(await engine.upsertEntry(AmiVoiceDictionaryEntry(id: badID, written: "BadWord"), for: key, state: .readyToSync))
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
        #expect(outcome.kind == .success)
        #expect(outcome.quarantinedCount == 1)
        let calls = transport.calls.filter { $0.method == "POST" }
        #expect(calls.count == 2)
        #expect(calls[0].payloads.map(\.written).contains("BadWord"))
        #expect(calls[1].payloads.map(\.written) == ["KoeBridge"])
        let rows = await engine.entries()
        #expect(rows.first { $0.id == badID }?.engineState(for: key)?.state == .syncFailed)
        #expect(rows.first { $0.id == goodID }?.engineState(for: key)?.state == .autoSynced)
        let status = await engine.status(for: key)
        #expect(status.quarantinedCount == 1)
        #expect(status.activeProfileID != nil)
    }

    @Test func launchPassRestoresFullSnapshotWhenServerProfileIsEmpty() async throws {
        let suite = "KoeBridge.AmiVoiceSync." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AmiVoiceDictionarySyncStore(defaults: defaults)
        let transport = MockAmiVoiceDictionaryTransport()
        let engine = AmiVoiceDictionarySyncEngine(store: store, transport: transport, apiKeyProvider: { "fixture-key" })
        let key = AmiVoiceDictionaryProfileKey(engine: .hybridJapaneseConversation, samplingRate: .rate16k)
        #expect(await engine.upsertEntry(
            AmiVoiceDictionaryEntry(written: "霧峰システム", spoken: "きりみねしすてむ"),
            for: key,
            state: .readyToSync
        ))
        await engine.setAutomaticSyncEnabled(true)
        let initial = await engine.syncNow(for: key)
        #expect(initial.kind == .success)
        transport.resetCalls()
        transport.fetchHandler = { [] }

        let outcome = await engine.performLaunchConsistencyPass(for: key)
        #expect(outcome.kind == .success)
        #expect(outcome.uploadedCount == 1)
        let methods = transport.calls.map(\.method)
        #expect(methods == ["GET", "POST"])
        #expect(transport.calls.last?.payloads.count == 1)
        #expect(transport.calls.last?.payloads.first?.written == "霧峰システム")
    }

    @Test func optInOffMakesEveryEntryPointZeroTransportCalls() async throws {
        let suite = "KoeBridge.AmiVoiceSync." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AmiVoiceDictionarySyncStore(defaults: defaults)
        let transport = MockAmiVoiceDictionaryTransport()
        let engine = AmiVoiceDictionarySyncEngine(store: store, transport: transport, apiKeyProvider: { "fixture-key" })
        let key = AmiVoiceDictionaryProfileKey(engine: .e2eJapaneseGeneral, samplingRate: .rate16k)
        #expect(!store.automaticSyncEnabled)
        #expect(await engine.upsertEntry(AmiVoiceDictionaryEntry(written: "KoeBridge"), for: key, state: .readyToSync))
        await engine.scheduleDebouncedSync(for: key)
        let manual = await engine.syncNow(for: key)
        let launch = await engine.performLaunchConsistencyPass(for: key)
        let delete = await engine.deleteAllServerWords(for: key)
        #expect(manual.kind == .disabled)
        #expect(launch.kind == .disabled)
        #expect(delete.kind == .disabled)
        #expect(transport.calls.isEmpty)
    }

    @Test func recognitionProfileReferenceIsConditionalAndOffPathByteIdentical() throws {
        let key = AmiVoiceDictionaryProfileKey(engine: .e2eJapaneseGeneral, samplingRate: .rate16k)
        let profileID = try #require(AmiVoiceProfileID("kb_test_profile"))
        var entry = AmiVoiceDictionaryEntry(written: "KoeBridge")
        entry.updateEngineState(for: key) { state in
            state.state = .autoSynced
            state.dirty = false
        }
        let profile = AmiVoiceDictionaryProfile(key: key, profileID: profileID)

        #expect(AmiVoiceDictionarySyncPolicy.recognitionProfileID(
            automaticSyncEnabled: false,
            entries: [entry],
            profile: profile,
            key: key
        ) == nil)
        #expect(AmiVoiceDictionarySyncPolicy.recognitionProfileID(
            automaticSyncEnabled: true,
            entries: [entry],
            profile: nil,
            key: key
        ) == nil)
        #expect(AmiVoiceDictionarySyncPolicy.recognitionProfileID(
            automaticSyncEnabled: true,
            entries: [entry],
            profile: profile,
            key: key
        ) == profileID.rawValue)

        let offCommand = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneral,
            profileWords: ["KoeBridge"],
            profileId: nil
        )
        #expect(offCommand == #"s LSB16K -a2-ja-general resultUpdatedInterval=300 profileWords="KoeBridge""#)
        let onCommand = AmiVoiceWire.startCommand(
            engine: .e2eJapaneseGeneral,
            profileWords: ["KoeBridge"],
            profileId: profileID.rawValue
        )
        #expect(onCommand == "s LSB16K -a2-ja-general resultUpdatedInterval=300 profileId=:kb_test_profile")
    }
}
