import Foundation
import KoeBridgeCore

struct PersistenceRecoveryTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KoeBridgeStores-\(UUID().uuidString)")
    }

    private func engine(at: Date) -> EngineUsageSample {
        EngineUsageSample(at: at, engine: .gemini, audioSeconds: 2, outcome: .success)
    }

    private func token(at: Date) -> GeminiTokenSample {
        GeminiTokenSample(at: at, usage: GeminiTokenUsage(promptTokens: 12, responseTokens: 3, totalTokens: 15))
    }

    func usageRetriesAllFailedWritesWithoutLosingOrDuplicatingSamples() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedParent = directory.appendingPathComponent("data")
        let url = blockedParent.appendingPathComponent("usage.json")
        var store = UsageMonitorStore(fileURL: url)
        try Data("blocks directory creation".utf8).write(to: blockedParent)
        let now = Date()
        let engines = (0..<3).map { engine(at: now.addingTimeInterval(Double($0 - 3))) }
        let tokens = (0..<3).map { token(at: now.addingTimeInterval(Double($0 - 3))) }

        store.append(engineEvents: [engines[0]], tokenEvents: [tokens[0]], now: now)
        store.append(engineEvents: [engines[1]], tokenEvents: [tokens[1]], now: now)
        check(store.problem == "利用統計を保存できません。元のファイルは保持しています：利用状況に失敗しました。時間をおいてもう一度お試しください。")
        check(store.engineEvents == Array(engines.prefix(2)))
        check(store.tokenEvents == Array(tokens.prefix(2)))

        try FileManager.default.removeItem(at: blockedParent)
        store.append(engineEvents: [engines[2]], tokenEvents: [tokens[2]], now: now)
        check(store.problem.isEmpty)
        check(store.engineEvents == engines)
        check(store.tokenEvents == tokens)
        let saved = try UsageMonitorArchive(fileURL: url)
        check(saved.engineEvents == engines)
        check(saved.tokenEvents == tokens)
    }

    func clearingUsageAlsoClearsUnwrittenSamples() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedParent = directory.appendingPathComponent("data")
        let url = blockedParent.appendingPathComponent("usage.json")
        var store = UsageMonitorStore(fileURL: url)
        try Data("blocks directory creation".utf8).write(to: blockedParent)
        let now = Date()
        store.append(engineEvents: [engine(at: now)], tokenEvents: [token(at: now)], now: now)
        check(!store.problem.isEmpty)
        try FileManager.default.removeItem(at: blockedParent)
        store.deleteAll()
        check(store.problem.isEmpty)
        check(store.engineEvents.isEmpty)
        check(store.tokenEvents.isEmpty)

        let afterClear = engine(at: now)
        store.append(engineEvents: [afterClear], tokenEvents: [], now: now)
        let saved = try UsageMonitorArchive(fileURL: url)
        check(saved.engineEvents == [afterClear])
        check(saved.tokenEvents.isEmpty)
    }

    func failedUsageDeletionRetainsUnwrittenSamplesForRecovery() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedParent = directory.appendingPathComponent("data")
        let url = blockedParent.appendingPathComponent("usage.json")
        var store = UsageMonitorStore(fileURL: url)
        try Data("blocks directory creation".utf8).write(to: blockedParent)
        let now = Date()
        let before = engine(at: now.addingTimeInterval(-1))
        store.append(engineEvents: [before], tokenEvents: [], now: now)
        store.deleteAll()
        check(store.problem == "利用統計を削除できません：利用状況に失敗しました。時間をおいてもう一度お試しください。")
        check(store.engineEvents == [before])

        try FileManager.default.removeItem(at: blockedParent)
        let after = engine(at: now)
        store.append(engineEvents: [after], tokenEvents: [], now: now)
        try check(try UsageMonitorArchive(fileURL: url).engineEvents == [before, after])
    }

    func corruptUsageIsPreservedAndMemoryOnlySamplesRespectRetention() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("usage.json")
        let damaged = Data("unreadable old usage".utf8)
        try damaged.write(to: url)
        var store = UsageMonitorStore(fileURL: url)
        check(store.problem == "利用統計を読み込めません。元のデータは保持しています：利用状況に失敗しました。時間をおいてもう一度お試しください。")
        let now = Date()
        let valid = engine(at: now)
        let stale = engine(at: now.addingTimeInterval(-31 * 86_400))
        let future = engine(at: now.addingTimeInterval(120))
        store.append(engineEvents: [stale, valid, future], tokenEvents: [], now: now)
        check(store.engineEvents == [valid])
        store.deleteAll()
        check(!store.problem.isEmpty)
        check(store.engineEvents == [valid])
        try check(try Data(contentsOf: url) == damaged)

        try Data(repeating: 0, count: UsageMonitorArchive.maximumFileBytes + 1).write(to: url)
        let oversized = UsageMonitorStore(fileURL: url)
        check(oversized.problem.contains(UsageMonitorArchive.ArchiveError.tooLarge.errorDescription!))
    }

    func pendingHistoryFromPreviousLaunchIsMarkedInterrupted() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        var archive = try RecentTranscriptArchive(fileURL: url)
        let pending = TranscriptRecord(engine: "Gemini", text: "前回の入力", isPartial: false, delivery: .pending)
        let delivered = TranscriptRecord(engine: "Apple", text: "入力済み", isPartial: false, delivery: .verifiedInserted)
        try archive.insert(pending)
        try archive.insert(delivered)
        let store = TranscriptHistoryStore(fileURL: url)
        check(store.problem.isEmpty)
        check(store.entries.first(where: { $0.id == pending.id })?.delivery == .interruptedDelivery)
        check(store.entries.first(where: { $0.id == pending.id })?.deliveryDetail?.isEmpty == false)
        check(store.entries.first(where: { $0.id == delivered.id })?.delivery == .verifiedInserted)
        try check(try RecentTranscriptArchive(fileURL: url).entries == store.entries)
    }

    func historyWriteFailureRetainsTextAndActualDeliveryUntilNextSave() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedParent = directory.appendingPathComponent("data")
        let url = blockedParent.appendingPathComponent("history.json")
        var store = TranscriptHistoryStore(fileURL: url)
        try Data("blocks directory creation".utf8).write(to: blockedParent)
        let now = Date()
        let firstID = try require(store.remember("失われてはいけない文", isPartial: false, delivery: .pending,
                                                 engine: "Gemini", recordedAt: now.addingTimeInterval(-1)))
        store.updateDelivery(firstID, to: .verifiedInserted, detail: "入力を確認")
        store.updateDelivery(UUID(), to: .blockedFocus)
        check(store.problem == "履歴の状態更新に失敗しました：履歴に失敗しました。時間をおいてもう一度お試しください。")
        check(store.entries.first?.text == "失われてはいけない文")
        check(store.entries.first?.delivery == .verifiedInserted)

        try FileManager.default.removeItem(at: blockedParent)
        store.remember("続く文", isPartial: false, delivery: .automaticPasteDisabled,
                       engine: "Apple", recordedAt: now)
        check(store.problem.isEmpty)
        let saved = try RecentTranscriptArchive(fileURL: url)
        check(saved.entries.map(\.text) == ["続く文", "失われてはいけない文"])
        check(saved.entries.last?.delivery == .verifiedInserted)
        check(saved.entries.last?.deliveryDetail == "入力を確認")
    }

    func corruptHistoryAllowsBoundedRecoveryWithoutOverwritingOriginal() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.json")
        let damaged = Data("unreadable old history".utf8)
        try damaged.write(to: url)
        var store = TranscriptHistoryStore(fileURL: url)
        let now = Date()
        let total = RecentTranscriptArchive.maximumRecords + 2
        for index in (0..<total).reversed() {
            store.remember("文章\(index)", isPartial: true, delivery: .recognitionInterrupted,
                           engine: "Apple", recordedAt: now.addingTimeInterval(Double(index - total)))
        }
        check(store.problem == "履歴を読み込めません（元のファイルは保持しています）：履歴に失敗しました。時間をおいてもう一度お試しください。")
        check(store.entries.count == RecentTranscriptArchive.maximumRecords)
        check(store.entries.first?.text == "文章\(RecentTranscriptArchive.maximumRecords + 1)")
        check(store.entries.last?.text == "文章2")
        let id = try require(store.entries.first?.id)
        store.updateDelivery(id, to: .blockedFocus)
        check(store.entries.first?.delivery == .blockedFocus)
        store.delete(id)
        check(store.entries.count == RecentTranscriptArchive.maximumRecords - 1)
        store.deleteAll()
        check(store.entries.isEmpty)
        try check(try Data(contentsOf: url) == damaged)

        try Data(repeating: 0, count: RecentTranscriptArchive.maximumFileBytes + 1).write(to: url)
        let oversized = TranscriptHistoryStore(fileURL: url)
        check(oversized.problem.contains(RecentTranscriptArchive.ArchiveError.tooLarge.errorDescription!))
    }
}
