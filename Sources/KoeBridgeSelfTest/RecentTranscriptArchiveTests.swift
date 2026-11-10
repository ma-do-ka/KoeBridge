import Foundation

import KoeBridgeCore

struct RecentTranscriptArchiveTests {
    private func temporaryArchiveURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("KoeBridgeTests-\(UUID().uuidString)")
            .appendingPathComponent("recent-transcripts.json")
    }

    func persistsNewestMaximumAcrossRestarts() throws {
        let url = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try RecentTranscriptArchive(fileURL: url)
        for i in 0..<(RecentTranscriptArchive.maximumRecords + 2) {
            try store.insert(TranscriptRecord(engine: "Gemini", text: "文章\(i)",
                                              isPartial: false, delivery: .pending))
        }
        check(store.entries.count == RecentTranscriptArchive.maximumRecords)
        check(store.entries.first?.text == "文章\(RecentTranscriptArchive.maximumRecords + 1)")
        check(store.entries.last?.text == "文章2")
        let restored = try RecentTranscriptArchive(fileURL: url)
        check(restored.entries == store.entries)
    }

    func deliveryStatusPersistsAndPartialIsRecoverable() throws {
        let url = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try RecentTranscriptArchive(fileURL: url)
        let partial = TranscriptRecord(engine: "Apple", text: "一部だけ", isPartial: true,
                                       delivery: .recognitionInterrupted)
        try store.insert(partial)
        try store.updateDelivery(id: partial.id, to: .blockedFocus)
        let restored = try RecentTranscriptArchive(fileURL: url)
        check(restored.entries.first?.text == "一部だけ")
        check(restored.entries.first?.isPartial == true)
        check(restored.entries.first?.delivery == .blockedFocus)
    }

    func deletionOnlyAffectsSelectedRecord() throws {
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
        check(store.entries.map(\.text) == ["後"])
        try store.deleteAll()
        try check(try RecentTranscriptArchive(fileURL: url).entries.isEmpty)
    }

    func emptyRecordIsNotStored() throws {
        let url = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try RecentTranscriptArchive(fileURL: url)
        try store.insert(TranscriptRecord(engine: "Gemini", text: " \n ",
                                          isPartial: true, delivery: .recognitionInterrupted))
        check(store.entries.isEmpty)
    }

    func corruptDataIsNotSilentlyOverwritten() throws {
        let url = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let broken = Data("not-json".utf8)
        try broken.write(to: url)
        checkThrows((any Error).self) { _ = try RecentTranscriptArchive(fileURL: url) }
        try check(try Data(contentsOf: url) == broken)
    }

    func historyIsPrivateAtFilesystemLevel() throws {
        let url = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try RecentTranscriptArchive(fileURL: url)
        try store.insert(TranscriptRecord(engine: "Gemini", text: "機密性テスト", isPartial: false,
                                          delivery: .attemptedUnconfirmed))
        let folder = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        check((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        check((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
