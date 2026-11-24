import Foundation

/// Counters returned by a Gemini Live server message. No estimation is performed.
public struct GeminiTokenUsage: Equatable, Sendable {
    public let promptTokens: Int?
    public let responseTokens: Int?
    public let totalTokens: Int

    // Provider counters are nonnegative 32-bit integers.
    public static let counterRange = 0...Int(Int32.max)

    public static func adding(_ value: Int, to total: Int) -> Int {
        let sum = total.addingReportingOverflow(value)
        return sum.overflow ? Int.max : sum.partialValue
    }

    public init(promptTokens: Int?, responseTokens: Int?, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.responseTokens = responseTokens
        self.totalTokens = totalTokens
    }
}

public enum UsageEngine: String, Codable, Sendable, CaseIterable {
    case gemini, apple, amivoice
    public var label: String {
        switch self {
        case .gemini: return "Gemini API"
        case .apple: return "Apple オンデバイス"
        case .amivoice: return "AmiVoice API"
        }
    }
}

public enum UsageOutcome: String, Codable, Sendable {
    case success, failure, cancelled
}

public struct EngineUsageSample: Codable, Equatable, Identifiable, Sendable {
    public enum Purpose: String, Codable, Sendable { case audioRecheck }
    public static let maximumEngineVariantBytes = 64

    public let id: UUID
    public let at: Date
    public let engine: UsageEngine
    /// PCM bytes actually sent/processed divided by 32,000 (16 kHz, 16-bit mono).
    /// This includes silence and is not "speech-only" time.
    public let audioSeconds: Double
    public let outcome: UsageOutcome
    /// Apple only: whether the user chose a cloud engine (Gemini or AmiVoice)
    /// but Apple was used instead.
    public let fallback: Bool
    /// Absent in older records; distinguish optional non-Live rechecks from
    /// primary recognition so a Live-only cost estimate cannot price both.
    public let purpose: Purpose?
    /// Absent in older records; AmiVoice S/E VAD speech-segment duration in seconds.
    public let speechSeconds: Double?
    /// Absent in older records; provider engine variant (e.g. "-a2-ja-general")
    /// for per-engine monthly quota accounting.
    public let engineVariant: String?

    // A single sample cannot cover more audio than the entire retention period,
    // and reported VAD speech cannot exceed audioSeconds + 5 s or retention bounds.
    var hasValidDuration: Bool {
        let maximumSeconds = Double(UsageMonitorArchive.retentionDays * 86_400)
        guard (0...maximumSeconds).contains(audioSeconds) else { return false }
        if let speechSeconds {
            let upperBound = min(maximumSeconds, max(audioSeconds + 5, 0))
            guard (0...upperBound).contains(speechSeconds) else { return false }
        }
        if let engineVariant {
            let bytes = engineVariant.utf8
            guard !bytes.isEmpty, bytes.count <= Self.maximumEngineVariantBytes,
                  bytes.allSatisfy({ byte in
                      (65...90).contains(byte) || (97...122).contains(byte)
                          || (48...57).contains(byte) || byte == 45 || byte == 95 || byte == 46
                  }) else { return false }
        }
        return true
    }

    public init(id: UUID = UUID(), at: Date, engine: UsageEngine,
                audioSeconds: Double, outcome: UsageOutcome, fallback: Bool = false,
                purpose: Purpose? = nil,
                speechSeconds: Double? = nil,
                engineVariant: String? = nil) {
        self.id = id
        self.at = at
        self.engine = engine
        self.audioSeconds = max(0, audioSeconds.isFinite ? audioSeconds : 0)
        self.outcome = outcome
        self.fallback = fallback
        self.purpose = purpose
        self.speechSeconds = speechSeconds
        self.engineVariant = engineVariant
    }
}

public struct GeminiTokenSample: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let at: Date
    public let promptTokens: Int?
    public let responseTokens: Int?
    public let totalTokens: Int

    var hasValidCounters: Bool {
        [totalTokens, promptTokens, responseTokens].compactMap { $0 }.allSatisfy(GeminiTokenUsage.counterRange.contains)
    }

    public init(id: UUID = UUID(), at: Date, usage: GeminiTokenUsage) {
        self.id = id
        self.at = at
        self.promptTokens = usage.promptTokens
        self.responseTokens = usage.responseTokens
        self.totalTokens = usage.totalTokens
    }
}

/// An optional, private, bounded device-local record of engine and API activity.
/// Never stores transcripts, PCM, API keys, or request/response bodies.
public struct UsageMonitorArchive {
    private struct Snapshot: Codable {
        var engineEvents: [EngineUsageSample]
        var tokenEvents: [GeminiTokenSample]
    }

    public static let retentionDays = 30
    public static let maximumEngineEvents = 6_000
    public static let maximumTokenEvents = 20_000
    public static let maximumFileBytes = 8 * 1024 * 1024

    public private(set) var engineEvents: [EngineUsageSample]
    public private(set) var tokenEvents: [GeminiTokenSample]
    private let fileURL: URL

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KoeBridge", isDirectory: true)
            .appendingPathComponent("usage-monitor.json")
    }

    public init(fileURL: URL = UsageMonitorArchive.defaultFileURL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let size = (attributes[.size] as? NSNumber)?.intValue,
               size > Self.maximumFileBytes { throw ArchiveError.tooLarge }
            let decoded = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
            engineEvents = Self.trim(decoded.engineEvents.filter(\.hasValidDuration), date: { $0.at },
                                     maximum: Self.maximumEngineEvents, now: Date())
            tokenEvents = Self.trim(decoded.tokenEvents.filter(\.hasValidCounters), date: { $0.at },
                                    maximum: Self.maximumTokenEvents, now: Date())
            // Retention applies to the on-disk file too, even when the user
            // has not recorded another dictation for more than 30 days.
            if engineEvents.count != decoded.engineEvents.count ||
               tokenEvents.count != decoded.tokenEvents.count {
                try persist(Snapshot(engineEvents: engineEvents, tokenEvents: tokenEvents))
            }
        } else {
            engineEvents = []
            tokenEvents = []
        }
    }

    public mutating func append(engineEvents: [EngineUsageSample],
                                tokenEvents: [GeminiTokenSample],
                                now: Date = Date()) throws {
        let nextEngines = Self.trim(self.engineEvents + engineEvents.filter(\.hasValidDuration), date: { $0.at },
                                    maximum: Self.maximumEngineEvents, now: now)
        let nextTokens = Self.trim(self.tokenEvents + tokenEvents.filter(\.hasValidCounters), date: { $0.at },
                                   maximum: Self.maximumTokenEvents, now: now)
        try persist(Snapshot(engineEvents: nextEngines, tokenEvents: nextTokens))
        self.engineEvents = nextEngines
        self.tokenEvents = nextTokens
    }

    public mutating func deleteAll() throws {
        try persist(Snapshot(engineEvents: [], tokenEvents: []))
        engineEvents = []
        tokenEvents = []
    }

    private static func trim<T>(_ rows: [T], date: (T) -> Date,
                                maximum: Int, now: Date) -> [T] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return Array(rows.filter { date($0) >= cutoff && date($0) <= now.addingTimeInterval(60) }
                         .sorted { date($0) < date($1) }.suffix(maximum))
    }

    private func persist(_ snapshot: Snapshot) throws {
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                             ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maximumFileBytes else { throw ArchiveError.tooLarge }
        try data.write(to: fileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                             ofItemAtPath: fileURL.path)
    }

    public enum ArchiveError: Error, LocalizedError {
        case tooLarge
        public var errorDescription: String? {
            "利用統計ファイルが安全上限を超えています。既存ファイルは保持しました"
        }
    }
}
