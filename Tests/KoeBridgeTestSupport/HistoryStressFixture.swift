import Foundation
import KoeBridgeCore

public enum HistoryStressFixture {
    public static func run() throws -> (correctCount: Bool, newest: Bool, oldest: Bool, persisted: Bool) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KoeBridgeStress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        var store = try RecentTranscriptArchive(fileURL: url)
        for n in 0..<1000 {
            let record = TranscriptRecord(engine: "test", text: "発話\(n)",
                                          isPartial: false, delivery: .attemptedUnconfirmed)
            try store.insert(record)
        }
        let reopened = try RecentTranscriptArchive(fileURL: url)
        return (store.entries.count == RecentTranscriptArchive.maximumRecords,
                store.entries.first?.text == "発話999",
                store.entries.last?.text == "発話\(1000 - RecentTranscriptArchive.maximumRecords)",
                reopened.entries == store.entries)
    }
}
