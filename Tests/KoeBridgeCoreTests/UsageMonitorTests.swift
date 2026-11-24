import Foundation
import Testing
@testable import KoeBridgeCore

struct UsageMonitorTests {
    @Test func recheckPurposeRoundTripsWithoutBreakingLegacyRecords() throws {
        let sample = EngineUsageSample(at: Date(), engine: .gemini, audioSeconds: 1,
                                       outcome: .success, purpose: .audioRecheck)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(sample)
        #expect(try decoder.decode(EngineUsageSample.self, from: data).purpose == .audioRecheck)
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "purpose")
        #expect(try decoder.decode(EngineUsageSample.self, from: JSONSerialization.data(withJSONObject: old)).purpose == nil)
    }

    private func file() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KoeBridgeUsage-\(UUID().uuidString)")
            .appendingPathComponent("usage-monitor.json")
    }

    @Test func storesEngineAttemptsAndActualPCMSeconds() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try UsageMonitorArchive(fileURL: url)
        let now = Date()
        let gemini = EngineUsageSample(at: now, engine: .gemini,
                                       audioSeconds: 12.5, outcome: .failure)
        let apple = EngineUsageSample(at: now, engine: .apple,
                                      audioSeconds: 12.5, outcome: .success, fallback: true)
        try store.append(engineEvents: [gemini, apple], tokenEvents: [
            GeminiTokenSample(at: now, usage: GeminiTokenUsage(
                promptTokens: 100, responseTokens: 10, totalTokens: 110))
        ], now: now)
        let reloaded = try UsageMonitorArchive(fileURL: url)
        #expect(reloaded.engineEvents.count == 2)
        #expect(reloaded.engineEvents[0].audioSeconds == 12.5)
        #expect(reloaded.engineEvents[1].fallback)
        #expect(reloaded.tokenEvents.first?.totalTokens == 110)
        let folder = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func prunesOldAndBoundsHistory() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try UsageMonitorArchive(fileURL: url)
        let now = Date()
        let stale = EngineUsageSample(at: now.addingTimeInterval(-31 * 86_400),
                                      engine: .apple, audioSeconds: 2, outcome: .success)
        let recent = EngineUsageSample(at: now, engine: .gemini,
                                       audioSeconds: 3, outcome: .success)
        try store.append(engineEvents: [stale, recent], tokenEvents: [], now: now)
        #expect(store.engineEvents == [recent])
    }

    @Test func corruptFileIsNeverOverwritten() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let contents = Data("invalid JSON".utf8)
        try contents.write(to: url)
        #expect(throws: (any Error).self) { try UsageMonitorArchive(fileURL: url) }
        #expect(try Data(contentsOf: url) == contents)
    }

    @Test func oversizedUsageCannotOverflowChartsOrSurviveReload() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try UsageMonitorArchive(fileURL: url)
        let sample = GeminiTokenSample(at: Date(), usage: .init(promptTokens: nil, responseTokens: nil, totalTokens: 5))
        try store.append(engineEvents: [], tokenEvents: [sample])
        var archive = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var rows = try #require(archive["tokenEvents"] as? [[String: Any]])
        var invalid = rows[0]
        invalid["totalTokens"] = Int.max
        rows.append(invalid)
        archive["tokenEvents"] = rows
        try JSONSerialization.data(withJSONObject: archive).write(to: url)
        #expect(try UsageMonitorArchive(fileURL: url).tokenEvents == [sample])
        #expect(GeminiTokenUsage.adding(1, to: Int.max) == Int.max)
        #expect(GeminiWire.parseTokenUsage(#"{"usageMetadata":{"totalTokenCount":9223372036854775807}}"#) == nil)
        #expect(GeminiWire.parseTokenUsage(#"{"usageMetadata":{"totalTokenCount":true}}"#) == nil)
    }

    @Test func failedArchiveStillValidatesInMemorySamples() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid archive".utf8).write(to: url)
        var store = UsageMonitorStore(fileURL: url)
        let valid = GeminiTokenSample(at: Date(), usage: .init(promptTokens: nil, responseTokens: nil, totalTokens: 1))
        let invalid = GeminiTokenSample(at: Date(), usage: .init(promptTokens: nil, responseTokens: nil, totalTokens: -1))
        store.append(engineEvents: [.init(at: Date(), engine: .apple, audioSeconds: .greatestFiniteMagnitude,
                                          outcome: .success)], tokenEvents: [valid, invalid])
        #expect(store.tokenEvents == [valid])
        #expect(store.engineEvents.isEmpty)
        #expect(try Data(contentsOf: url) == Data("invalid archive".utf8))
    }

    @Test func clearingUsageDoesNotAffectOtherArchives() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try UsageMonitorArchive(fileURL: url)
        try store.append(engineEvents: [
            EngineUsageSample(at: Date(), engine: .apple, audioSeconds: 1, outcome: .success)
        ], tokenEvents: [])
        try store.deleteAll()
        #expect(try UsageMonitorArchive(fileURL: url).engineEvents.isEmpty)
    }

    @Test func parsesGeminiLiveUsageMetadataOnlyWhenReported() throws {
        let raw = #"{"serverContent":{"turnComplete":true},"usageMetadata":{"promptTokenCount":120,"candidatesTokenCount":30,"totalTokenCount":150}}"#
        let usage = GeminiWire.parseTokenUsage(raw)
        #expect(usage?.promptTokens == 120)
        #expect(usage?.responseTokens == 30)
        #expect(usage?.totalTokens == 150)
        #expect(try GeminiWire.parse(raw) == [.turnComplete])
        #expect(GeminiWire.parseTokenUsage(#"{"serverContent":{"turnComplete":true}}"#) == nil)
        #expect(GeminiWire.parseTokenUsage(#"{"usageMetadata":{"totalTokenCount":-1}}"#) == nil)
        #expect(GeminiWire.parseTokenUsage("bad json") == nil)
    }

    @Test func legacyUsageArchiveWithoutAmiVoiceFieldsDecodesCleanly() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let nowSeconds = Date().timeIntervalSinceReferenceDate.rounded(.down)
        let t0 = nowSeconds - 10
        let t1 = nowSeconds
        let raw = """
        {
          "engineEvents": [
            {"id":"00000000-0000-4000-8000-000000000001","at":\(t0),"engine":"gemini","audioSeconds":18.5,"outcome":"success","fallback":false},
            {"id":"00000000-0000-4000-8000-000000000002","at":\(t1),"engine":"apple","audioSeconds":4.0,"outcome":"failure","fallback":true}
          ],
          "tokenEvents": []
        }
        """
        try Data(raw.utf8).write(to: url)
        let archive = try UsageMonitorArchive(fileURL: url)
        #expect(archive.engineEvents.count == 2)
        #expect(archive.engineEvents[0].engine == .gemini)
        #expect(archive.engineEvents[0].purpose == nil)
        #expect(archive.engineEvents[0].speechSeconds == nil)
        #expect(archive.engineEvents[0].engineVariant == nil)
        #expect(archive.engineEvents[1].engine == .apple)
        #expect(archive.engineEvents[1].fallback)
        #expect(archive.engineEvents[1].speechSeconds == nil)
        #expect(archive.engineEvents[1].engineVariant == nil)
    }

    @Test func amiVoiceUsageSampleRoundTripsSpeechSecondsAndEngineVariant() throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var archive = try UsageMonitorArchive(fileURL: url)
        let now = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
        let measured = EngineUsageSample(
            at: now.addingTimeInterval(-10), engine: .amivoice, audioSeconds: 24.0, outcome: .success,
            speechSeconds: 18.25, engineVariant: AmiVoiceEngine.e2eJapaneseGeneral.rawValue
        )
        let untagged = EngineUsageSample(
            at: now, engine: .amivoice, audioSeconds: 6.0, outcome: .failure
        )
        try archive.append(engineEvents: [measured, untagged], tokenEvents: [], now: now)
        let reloaded = try UsageMonitorArchive(fileURL: url)
        #expect(reloaded.engineEvents == [measured, untagged])
        #expect(reloaded.engineEvents[0].engine == .amivoice)
        #expect(reloaded.engineEvents[0].speechSeconds == 18.25)
        #expect(reloaded.engineEvents[0].engineVariant == "-a2-ja-general")
        #expect(reloaded.engineEvents[1].speechSeconds == nil)
        #expect(reloaded.engineEvents[1].engineVariant == nil)
        #expect(UsageEngine.amivoice.rawValue == "amivoice")
        #expect(UsageEngine.amivoice.label == "AmiVoice API")
        #expect(InputDiagnosticEvent.Token.amivoice.rawValue == "amivoice")
        #expect(InputDiagnosticEvent.Value.reason("amivoice") == .token(.amivoice))
    }

    @Test func validatesSpeechSecondsAndEngineVariantBounds() throws {
        let now = Date()
        let maxRetention = Double(UsageMonitorArchive.retentionDays * 86_400)
        // Valid boundaries
        #expect(EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 10, outcome: .success,
                                  speechSeconds: 0, engineVariant: "-a2-ja-general").hasValidDuration)
        #expect(EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 10, outcome: .success,
                                  speechSeconds: 15, engineVariant: "-a2b-ja-general").hasValidDuration)
        #expect(EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 0, outcome: .success,
                                  speechSeconds: 5, engineVariant: "-a-general-input").hasValidDuration)
        for variant in AmiVoiceEngine.allCases.map(\.rawValue) {
            #expect(EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 1, outcome: .success,
                                      speechSeconds: 1, engineVariant: variant).hasValidDuration)
        }
        // Invalid speechSeconds
        #expect(!EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 10, outcome: .success,
                                   speechSeconds: -0.01).hasValidDuration)
        #expect(!EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 10, outcome: .success,
                                   speechSeconds: 15.01).hasValidDuration)
        #expect(!EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 10, outcome: .success,
                                   speechSeconds: .nan).hasValidDuration)
        #expect(!EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 10, outcome: .success,
                                   speechSeconds: .infinity).hasValidDuration)
        #expect(!EngineUsageSample(at: now, engine: .amivoice, audioSeconds: maxRetention, outcome: .success,
                                   speechSeconds: maxRetention + 1).hasValidDuration)
        // Invalid engineVariant
        #expect(!EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 10, outcome: .success,
                                   engineVariant: "").hasValidDuration)
        #expect(!EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 10, outcome: .success,
                                   engineVariant: "bad variant").hasValidDuration)
        #expect(!EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 10, outcome: .success,
                                   engineVariant: String(repeating: "a", count: 65)).hasValidDuration)

        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var archive = try UsageMonitorArchive(fileURL: url)
        let valid = EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 10, outcome: .success,
                                      speechSeconds: 8, engineVariant: "-a2-ja-general")
        let invalidSpeech = EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 10, outcome: .success,
                                              speechSeconds: 20, engineVariant: "-a2-ja-general")
        let invalidVariant = EngineUsageSample(at: now, engine: .amivoice, audioSeconds: 10, outcome: .success,
                                               speechSeconds: 8, engineVariant: "private transcript")
        try archive.append(engineEvents: [valid, invalidSpeech, invalidVariant], tokenEvents: [], now: now)
        #expect(archive.engineEvents == [valid])
    }
}
