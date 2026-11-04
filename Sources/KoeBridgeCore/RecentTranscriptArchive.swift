import Foundation

/// A recovery record. Audio and API credentials are intentionally never archived.
public struct TranscriptRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Delivery: String, Codable, Sendable {
        case pending
        case attemptedUnconfirmed
        case blockedFocus
        case missingPermission
        case insertionUnavailable
        case partiallyDirect
        case automaticPasteDisabled
        case recognitionInterrupted

        public var label: String {
            switch self {
            case .pending: return "自動入力の処理待ち"
            case .attemptedUnconfirmed: return "自動入力を送信（受理は未確認）"
            case .blockedFocus: return "安全確認のため未入力（入力先変更・システム中断等）"
            case .missingPermission: return "権限不足のため未入力"
            case .insertionUnavailable: return "直接入力イベントを送れませんでした"
            case .partiallyDirect: return "直接入力が途中で中断（履歴を確認）"
            case .automaticPasteDisabled: return "自動入力OFFのため保存のみ"
            case .recognitionInterrupted: return "認識失敗（途中結果を保存）"
            }
        }
    }

    public let id: UUID
    public let recordedAt: Date
    public let engine: String
    public let text: String
    public let isPartial: Bool
    public var delivery: Delivery

    public init(id: UUID = UUID(), recordedAt: Date = Date(), engine: String,
                text: String, isPartial: Bool, delivery: Delivery) {
        self.id = id
        self.recordedAt = recordedAt
        self.engine = engine
        self.text = text
        self.isPartial = isPartial
        self.delivery = delivery
    }
}

/// Stores only the ten newest textual results; an unreadable old file is never overwritten.
/// The directory and JSON file are made private to the current macOS account.
public struct RecentTranscriptArchive {
    public static let maximumRecords = 10
    // Defensive bound for a corrupt or unexpectedly huge history file.
    public static let maximumFileBytes = 12 * 1024 * 1024
    public private(set) var entries: [TranscriptRecord]
    private let fileURL: URL

    public static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("KoeBridge", isDirectory: true)
            .appendingPathComponent("recent-transcripts.json")
    }

    public init(fileURL: URL = RecentTranscriptArchive.defaultFileURL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let info = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let size = (info[.size] as? NSNumber)?.intValue, size > Self.maximumFileBytes {
                throw ArchiveError.tooLarge
            }
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            entries = Array(try decoder.decode([TranscriptRecord].self, from: data).prefix(Self.maximumRecords))
        } else {
            entries = []
        }
    }

    public mutating func insert(_ record: TranscriptRecord) throws {
        guard !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.removeAll { $0.id == record.id }
        entries.insert(record, at: 0)
        if entries.count > Self.maximumRecords { entries.removeLast(entries.count - Self.maximumRecords) }
        try persist(entries)
    }

    public mutating func updateDelivery(id: UUID, to delivery: TranscriptRecord.Delivery) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        updated[index].delivery = delivery
        try persist(updated)
        entries = updated
    }

    public mutating func delete(id: UUID) throws {
        let updated = entries.filter { $0.id != id }
        try persist(updated)
        entries = updated
    }

    public mutating func deleteAll() throws {
        try persist([])
        entries = []
    }

    public enum ArchiveError: Error, LocalizedError {
        case tooLarge
        public var errorDescription: String? { "履歴のサイズが安全上限を超えています。既存ファイルは保持しました" }
    }

    private func persist(_ contents: [TranscriptRecord]) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try manager.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                                  ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(contents)
        guard data.count <= Self.maximumFileBytes else { throw ArchiveError.tooLarge }
        try data.write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                  ofItemAtPath: fileURL.path)
    }
}
