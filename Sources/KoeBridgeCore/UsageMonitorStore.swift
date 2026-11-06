import Foundation

/// Keeps failed writes available for the next save instead of replacing the
/// visible counters with an older archive after storage becomes writable again.
public struct UsageMonitorStore {
    public private(set) var engineEvents: [EngineUsageSample] = []
    public private(set) var tokenEvents: [GeminiTokenSample] = []
    public private(set) var problem = ""
    private var archive: UsageMonitorArchive?
    private var unsavedEngines: [EngineUsageSample] = []
    private var unsavedTokens: [GeminiTokenSample] = []

    public init(fileURL: URL = UsageMonitorArchive.defaultFileURL) {
        do {
            let stored = try UsageMonitorArchive(fileURL: fileURL)
            archive = stored
            engineEvents = stored.engineEvents
            tokenEvents = stored.tokenEvents
        } catch {
            problem = "利用統計を読み込めません。元のデータは保持しています：\(error.localizedDescription)"
        }
    }

    public mutating func append(engineEvents: [EngineUsageSample], tokenEvents: [GeminiTokenSample],
                                now: Date = Date()) {
        guard !engineEvents.isEmpty || !tokenEvents.isEmpty else { return }
        guard var store = archive else {
            // Do not replace an unreadable archive with a fresh file.
            self.engineEvents = Self.retained(self.engineEvents + engineEvents, at: { $0.at },
                                             maximum: UsageMonitorArchive.maximumEngineEvents, now: now)
            self.tokenEvents = Self.retained(self.tokenEvents + tokenEvents, at: { $0.at },
                                            maximum: UsageMonitorArchive.maximumTokenEvents, now: now)
            return
        }
        unsavedEngines = Self.retained(unsavedEngines + engineEvents, at: { $0.at },
                                      maximum: UsageMonitorArchive.maximumEngineEvents, now: now)
        unsavedTokens = Self.retained(unsavedTokens + tokenEvents, at: { $0.at },
                                     maximum: UsageMonitorArchive.maximumTokenEvents, now: now)
        do {
            try store.append(engineEvents: unsavedEngines, tokenEvents: unsavedTokens, now: now)
            archive = store
            self.engineEvents = store.engineEvents
            self.tokenEvents = store.tokenEvents
            unsavedEngines = []
            unsavedTokens = []
            problem = ""
        } catch {
            problem = "利用統計を保存できません。元のファイルは保持しています：\(error.localizedDescription)"
            self.engineEvents = Self.retained(store.engineEvents + unsavedEngines, at: { $0.at },
                                             maximum: UsageMonitorArchive.maximumEngineEvents, now: now)
            self.tokenEvents = Self.retained(store.tokenEvents + unsavedTokens, at: { $0.at },
                                            maximum: UsageMonitorArchive.maximumTokenEvents, now: now)
        }
    }

    public mutating func deleteAll() {
        guard var store = archive else {
            problem = "統計ファイルを読み込めないため、既存ファイルを安全に削除できません"
            return
        }
        do {
            try store.deleteAll()
            archive = store
            engineEvents = []
            tokenEvents = []
            unsavedEngines = []
            unsavedTokens = []
            problem = ""
        } catch {
            problem = "利用統計を削除できません：\(error.localizedDescription)"
        }
    }

    private static func retained<T>(_ samples: [T], at: (T) -> Date,
                                     maximum: Int, now: Date) -> [T] {
        let cutoff = now.addingTimeInterval(-Double(UsageMonitorArchive.retentionDays) * 86_400)
        return Array(samples.filter { at($0) >= cutoff && at($0) <= now.addingTimeInterval(60) }
            .sorted { at($0) < at($1) }.suffix(maximum))
    }
}
