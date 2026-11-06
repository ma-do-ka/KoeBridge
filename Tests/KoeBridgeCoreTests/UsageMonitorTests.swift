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
}
