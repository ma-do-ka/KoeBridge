import Foundation

/// A recovery record. Credentials are never archived; optional audio lives in a separate private store.
public struct TranscriptRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Delivery: String, Codable, Sendable {
        case pending
        case attemptedUnconfirmed
        case verifiedInserted
        case blockedFocus
        case missingPermission
        case insertionUnavailable
        case partiallyDirect
        case automaticPasteDisabled
        case recognitionInterrupted
        case reviewRequired
        case cancelledDelivery
        case interruptedDelivery

        public var label: String {
            switch self {
            case .pending: return "自動入力の処理待ち"
            case .attemptedUnconfirmed: return "自動入力を送信（受理は未確認）"
            case .verifiedInserted: return "自動入力の反映を確認"
            case .blockedFocus: return "安全確認のため未入力（入力先変更・システム中断等）"
            case .missingPermission: return "権限不足のため未入力"
            case .insertionUnavailable: return "直接入力イベントを送れませんでした"
            case .partiallyDirect: return "直接入力が途中で中断（履歴を確認）"
            case .automaticPasteDisabled: return "自動入力OFFのため保存のみ"
            case .recognitionInterrupted: return "認識失敗（途中結果を保存）"
            case .reviewRequired: return "認識内容を要確認（未入力）"
            case .cancelledDelivery: return "入力をキャンセルしました"
            case .interruptedDelivery: return "入力状況を要確認（処理が中断）"
            }
        }
    }

    public struct AudioAsset: Codable, Equatable, Sendable {
        public let relativeFileName: String
        public let pcmByteCount: Int
        public let recordedAt: Date
        public let expiresAt: Date
        public init(relativeFileName: String, pcmByteCount: Int, recordedAt: Date, expiresAt: Date) {
            self.relativeFileName = relativeFileName; self.pcmByteCount = pcmByteCount
            self.recordedAt = recordedAt; self.expiresAt = expiresAt
        }
    }
    public struct Retranscription: Codable, Equatable, Sendable {
        public let engine: String
        public let date: Date
        public let text: String
        public init(engine: String, date: Date = Date(), text: String) {
            self.engine = engine; self.date = date; self.text = text
        }
    }
    public var audioAsset: AudioAsset?
    public var audioUnavailableReason: String?
    public var retranscriptions: [Retranscription]
    public var kind: String?
    public let id: UUID
    public let recordedAt: Date
    public let engine: String
    public let text: String
    public let isPartial: Bool
    public var delivery: Delivery
    public var deliveryDetail: String?
    public let review: TranscriptReview?

    public init(id: UUID = UUID(), recordedAt: Date = Date(), engine: String,
                text: String, isPartial: Bool, delivery: Delivery, review: TranscriptReview? = nil,
                deliveryDetail: String? = nil, kind: String? = nil) {
        self.kind = kind
        self.retranscriptions = []
        self.id = id
        self.recordedAt = recordedAt
        self.engine = engine
        self.text = text
        self.isPartial = isPartial
        self.delivery = delivery
        self.review = review
        self.deliveryDetail = deliveryDetail
    }
    private enum CodingKeys: String, CodingKey {
        case id, recordedAt, engine, text, isPartial, delivery, deliveryDetail, review
        case audioAsset, audioUnavailableReason, retranscriptions, kind
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        engine = try c.decode(String.self, forKey: .engine)
        text = try c.decode(String.self, forKey: .text)
        isPartial = try c.decode(Bool.self, forKey: .isPartial)
        delivery = try c.decode(Delivery.self, forKey: .delivery)
        deliveryDetail = try c.decodeIfPresent(String.self, forKey: .deliveryDetail)
        review = try c.decodeIfPresent(TranscriptReview.self, forKey: .review)
        audioAsset = try c.decodeIfPresent(AudioAsset.self, forKey: .audioAsset)
        audioUnavailableReason = try c.decodeIfPresent(String.self, forKey: .audioUnavailableReason)
        retranscriptions = try c.decodeIfPresent([Retranscription].self, forKey: .retranscriptions) ?? []
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
    }

}

/// Stores only the newest textual results, bounded by maximumRecords; an unreadable old file is never overwritten.
/// The directory and JSON file are made private to the current macOS account.
public struct RecentTranscriptArchive {
    public static let maximumRecords = 500
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
        let info: [FileAttributeKey: Any]
        do {
            info = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            entries = []
            return
        }
        if let size = (info[.size] as? NSNumber)?.intValue, size > Self.maximumFileBytes {
            throw ArchiveError.tooLarge
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        entries = Array(try decoder.decode([TranscriptRecord].self, from: data).prefix(Self.maximumRecords))
    }

    public mutating func insert(_ record: TranscriptRecord) throws {
        guard !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var updated = entries.filter { $0.id != record.id }
        updated.insert(record, at: 0)
        // Recognition completes out of order during continuous dictation.
        // History is ordered by recording time, not provider response timing.
        updated.sort { $0.recordedAt > $1.recordedAt }
        try saveUpdate(updated, retaining: record.id)
    }

    /// Fast path for a group of row edits. Near the byte limit, each edited
    /// row has its own eviction priority; let the caller replay individual edits.
    mutating func saveBatch(_ updated: [TranscriptRecord]) throws -> Bool {
        guard try encode(entries).count <= Self.maximumFileBytes else { return false }
        let data = try encode(updated)
        guard data.count <= Self.maximumFileBytes else { return false }
        try write(data)
        entries = updated
        return true
    }

    public mutating func updateDelivery(id: UUID, to delivery: TranscriptRecord.Delivery, detail: String? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        updated[index].delivery = delivery
        updated[index].deliveryDetail = detail
        // Delivery has already happened. A disk error must not leave the
        // running app showing "pending" and invite an accidental second input.
        try saveUpdate(updated, retaining: id)
    }

    public mutating func updateAudio(id: UUID, asset: TranscriptRecord.AudioAsset?, reason: String?) throws {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        updated[i].audioAsset = asset
        updated[i].audioUnavailableReason = reason
        try saveUpdate(updated, retaining: id)
    }

    public mutating func appendRetranscription(id: UUID, result: TranscriptRecord.Retranscription) throws {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries
        updated[i].retranscriptions.append(result)
        try saveUpdate(updated, retaining: id)
    }

    public mutating func delete(id: UUID) throws {
        let updated = entries.filter { $0.id != id }
        try write(encode(updated))
        entries = updated
    }

    public mutating func deleteAll() throws {
        try write(encode([]))
        entries = []
    }

    public enum ArchiveError: Error, LocalizedError {
        case tooLarge
        public var errorDescription: String? { "履歴のサイズが安全上限を超えています。既存ファイルは保持しました" }
    }

    private func encode(_ contents: [TranscriptRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(contents)
    }

    private mutating func saveUpdate(_ proposed: [TranscriptRecord], retaining id: UUID) throws {
        var candidate = Array(proposed.prefix(Self.maximumRecords))
        guard candidate.contains(where: { $0.id == id }) else { throw ArchiveError.tooLarge }
        var data = try encode(candidate)
        if data.count > Self.maximumFileBytes {
            // Preserve the edited row, evicting the oldest other rows first.
            // Measure actual JSON bytes, including escaped strings and formatting.
            guard let index = candidate.firstIndex(where: { $0.id == id }) else { throw ArchiveError.tooLarge }
            let changed = candidate.remove(at: index)
            func keeping(_ others: Int) -> [TranscriptRecord] {
                var result = Array(candidate.prefix(others))
                result.insert(changed, at: min(index, result.count))
                return result
            }
            var low = 0
            var high = candidate.count
            while low < high {
                let mid = (low + high + 1) / 2
                if try encode(keeping(mid)).count <= Self.maximumFileBytes {
                    low = mid
                } else { high = mid - 1 }
            }
            candidate = keeping(low)
            data = try encode(candidate)
            guard data.count <= Self.maximumFileBytes else { throw ArchiveError.tooLarge }
        }
        // Size rejection leaves the old working set intact. Only size-checked
        // changes are eligible for a later retry after a filesystem error.
        entries = candidate
        try write(data)
    }

    private func write(_ data: Data) throws {
        guard data.count <= Self.maximumFileBytes else { throw ArchiveError.tooLarge }
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try manager.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                                  ofItemAtPath: directory.path)
        try data.write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                  ofItemAtPath: fileURL.path)
    }
}
