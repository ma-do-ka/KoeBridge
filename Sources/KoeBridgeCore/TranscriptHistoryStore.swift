import Foundation

/// Owns the running app's recovery history, including disk-error recovery.
/// A corrupt archive is never overwritten; new results remain usable in memory.
public struct TranscriptHistoryStore {
    public private(set) var entries: [TranscriptRecord] = []
    public private(set) var problem = ""
    private var archive: RecentTranscriptArchive?

    public init(fileURL: URL = RecentTranscriptArchive.defaultFileURL) {
        do {
            archive = try RecentTranscriptArchive(fileURL: fileURL)
            entries = archive?.entries ?? []
            for record in entries where record.delivery == .pending {
                updateDelivery(record.id, to: .interruptedDelivery,
                               detail: "前回の入力処理が完了する前に終了しました。再送の前に入力先を確認してください。")
            }
        } catch {
            problem = "履歴を読み込めません（元のファイルは保持しています）：\(Self.errorMessage(for: error))"
        }
    }

    @discardableResult public mutating func remember(
        _ text: String, isPartial: Bool, delivery: TranscriptRecord.Delivery,
        engine: String, review: TranscriptReview? = nil, recordedAt: Date = Date(), kind: String? = nil
    ) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let record = TranscriptRecord(recordedAt: recordedAt, engine: engine,
                                      text: trimmed, isPartial: isPartial,
                                      delivery: delivery, review: review, kind: kind)
        guard archive != nil else {
            entries.insert(record, at: 0)
            entries.sort { $0.recordedAt > $1.recordedAt }
            entries = Array(entries.prefix(RecentTranscriptArchive.maximumRecords))
            return record.id
        }
        changeArchive(failure: "履歴をディスクへ保存できません（起動中のみ保持）") {
            try $0.insert(record)
        }
        return record.id
    }

    public mutating func updateDelivery(_ id: UUID, to delivery: TranscriptRecord.Delivery,
                                        detail: String? = nil) {
        guard entries.contains(where: { $0.id == id }) else { return }
        guard archive != nil else {
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].delivery = delivery
                entries[index].deliveryDetail = detail
            }
            return
        }
        changeArchive(failure: "履歴の状態更新に失敗しました") {
            try $0.updateDelivery(id: id, to: delivery, detail: detail)
        }
    }

    public mutating func updateAudio(_ id: UUID, asset: TranscriptRecord.AudioAsset?, reason: String? = nil) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if archive == nil {
            entries[i].audioAsset = asset; entries[i].audioUnavailableReason = reason
        } else {
            changeArchive(failure: "保存音声の参照更新に失敗しました") {
                try $0.updateAudio(id: id, asset: asset, reason: reason)
            }
        }
    }

    public mutating func appendRetranscription(_ id: UUID, result: TranscriptRecord.Retranscription) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if archive == nil { entries[i].retranscriptions.append(result) }
        else {
            changeArchive(failure: "再文字起こし結果の保存に失敗しました") {
                try $0.appendRetranscription(id: id, result: result)
            }
        }
    }

    public mutating func delete(_ id: UUID) {
        guard archive != nil else { entries.removeAll { $0.id == id }; return }
        changeArchive(failure: "履歴の削除に失敗しました") { try $0.delete(id: id) }
    }

    public mutating func deleteAll() {
        guard archive != nil else { entries = []; return }
        changeArchive(failure: "履歴の全削除に失敗しました") { try $0.deleteAll() }
    }

    private static func errorMessage(for error: Error) -> String {
        (error as? RecentTranscriptArchive.ArchiveError)?.errorDescription
            ?? UserFacingErrorMessage.message(for: error, operation: "履歴")
    }

    private mutating func changeArchive(
        failure: String, _ operation: (inout RecentTranscriptArchive) throws -> Void
    ) {
        guard var store = archive else { return }
        do {
            try operation(&store)
            problem = ""
        } catch {
            problem = "\(failure)：\(Self.errorMessage(for: error))"
        }
        // Inserts and delivery outcomes survive failed writes in the archive's
        // working copy. A later successful write persists those same records.
        archive = store
        entries = store.entries
    }
}
