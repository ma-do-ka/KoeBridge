import Foundation
import Testing
@testable import KoeBridgeCore

struct RecentTranscriptArchiveTests {
    @Test func outOfOrderRecognitionStillShowsNewestRecordingFirst() throws {
        let url = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try RecentTranscriptArchive(fileURL: url)
        let earlier = TranscriptRecord(recordedAt: Date(timeIntervalSince1970: 10), engine: "Gemini",
                                       text: "A", isPartial: false, delivery: .pending)
        let later = TranscriptRecord(recordedAt: Date(timeIntervalSince1970: 20), engine: "Gemini",
                                     text: "B", isPartial: false, delivery: .pending)
        try store.insert(later)
        try store.insert(earlier)
        #expect(store.entries.map(\.text) == ["B", "A"])
        #expect(try RecentTranscriptArchive(fileURL: url).entries.map(\.text) == ["B", "A"])
    }

    @Test func failedDiskUpdateRetainsActualDeliveryInMemory() throws {
        let url = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try RecentTranscriptArchive(fileURL: url)
        let record = TranscriptRecord(engine: "Gemini", text: "入力済み", isPartial: false, delivery: .pending)
        try store.insert(record)
        // Replacing the destination with a directory deterministically makes
        // the next atomic file write fail even when tests run as an administrator.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try store.updateDelivery(id: record.id, to: .verifiedInserted, detail: "反映を確認")
        }
        #expect(store.entries.first?.delivery == .verifiedInserted)
        #expect(store.entries.first?.deliveryDetail == "反映を確認")
    }

    private func temporaryArchiveURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KoeBridgeTests-\(UUID().uuidString)")
            .appendingPathComponent("recent-transcripts.json")
    }

    @Test func persistsNewestTenAcrossRestarts() throws {
        let url = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try RecentTranscriptArchive(fileURL: url)
        for i in 0..<12 {
            try store.insert(TranscriptRecord(engine: "Gemini", text: "文章\(i)",
                                              isPartial: false, delivery: .pending))
        }
        #expect(store.entries.count == 10)
        #expect(store.entries.first?.text == "文章11")
        #expect(store.entries.last?.text == "文章2")
        let restored = try RecentTranscriptArchive(fileURL: url)
        #expect(restored.entries == store.entries)
    }

    @Test func deliveryStatusPersistsAndPartialIsRecoverable() throws {
        let url = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try RecentTranscriptArchive(fileURL: url)
        let partial = TranscriptRecord(engine: "Apple", text: "一部だけ", isPartial: true,
                                       delivery: .recognitionInterrupted)
        try store.insert(partial)
        try store.updateDelivery(id: partial.id, to: .blockedFocus)
        let restored = try RecentTranscriptArchive(fileURL: url)
        #expect(restored.entries.first?.text == "一部だけ")
        #expect(restored.entries.first?.isPartial == true)
        #expect(restored.entries.first?.delivery == .blockedFocus)
    }

    @Test func deletionOnlyAffectsSelectedRecord() throws {
        let url = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try RecentTranscriptArchive(fileURL: url)
        let first = TranscriptRecord(engine: "Gemini", text: "先", isPartial: false,
                                     delivery: .attemptedUnconfirmed)
        let second = TranscriptRecord(engine: "Gemini", text: "後", isPartial: false,
                                      delivery: .attemptedUnconfirmed)
        try store.insert(first)
        try store.insert(second)
        try store.delete(id: first.id)
        #expect(store.entries.map(\.text) == ["後"])
        try store.deleteAll()
        #expect(try RecentTranscriptArchive(fileURL: url).entries.isEmpty)
    }

    @Test func emptyRecordIsNotStored() throws {
        let url = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try RecentTranscriptArchive(fileURL: url)
        try store.insert(TranscriptRecord(engine: "Gemini", text: " \n ",
                                          isPartial: true, delivery: .recognitionInterrupted))
        #expect(store.entries.isEmpty)
    }

    @Test func corruptDataIsNotSilentlyOverwritten() throws {
        let url = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let broken = Data("not-json".utf8)
        try broken.write(to: url)
        #expect(throws: (any Error).self) { try RecentTranscriptArchive(fileURL: url) }
        #expect(try Data(contentsOf: url) == broken)
    }

    @Test func historyIsPrivateAtFilesystemLevel() throws {
        let url = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try RecentTranscriptArchive(fileURL: url)
        try store.insert(TranscriptRecord(engine: "Gemini", text: "機密性テスト", isPartial: false,
                                          delivery: .attemptedUnconfirmed))
        let folder = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
