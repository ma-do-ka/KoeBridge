import Foundation

/// Owns the running app's recovery history, including disk-error recovery.
/// A corrupt archive is never overwritten; new results remain usable in memory.
public struct TranscriptHistoryStore {
    public enum LoadOutcome { case loaded, empty, failed }
    public let loadOutcome: LoadOutcome
    public private(set) var entries: [TranscriptRecord] = []
    public private(set) var problem = ""
    /// Latest size-rejected result is copyable for this session, outside the archive budget.
    public private(set) var rejectedResult: (recordID: UUID, text: String)?
    public private(set) var unsavedIDs: Set<UUID> = []
    private var persisted: [TranscriptRecord] = []
    public func isSaved(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return !unsavedIDs.contains(id) && entries.contains { $0.id == id }
    }

    private var archive: RecentTranscriptArchive?

    public init(fileURL: URL = RecentTranscriptArchive.defaultFileURL) {
        do {
            archive = try RecentTranscriptArchive(fileURL: fileURL)
            entries = archive?.entries ?? []
            persisted = entries
            loadOutcome = entries.isEmpty ? .empty : .loaded
            for record in entries where record.delivery == .pending {
                updateDelivery(record.id, to: .interruptedDelivery,
                               detail: "前回の入力処理が完了する前に終了しました。再送の前に入力先を確認してください。")
            }
        } catch {
            loadOutcome = .failed
            problem = "履歴を読み込めません（元のファイルは保持しています）：\(Self.errorMessage(for: error))"
        }
    }

    @discardableResult public mutating func remember(
        _ text: String, isPartial: Bool, delivery: TranscriptRecord.Delivery,
        engine: String, review: TranscriptReview? = nil, recordedAt: Date = Date(), kind: String? = nil,
        deliveryDetail: String? = nil, preserveWhitespace: Bool = false
    ) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let record = TranscriptRecord(recordedAt: recordedAt, engine: engine,
                                      text: preserveWhitespace ? text : trimmed, isPartial: isPartial,
                                      delivery: delivery, review: review, deliveryDetail: deliveryDetail, kind: kind)
        guard archive != nil else {
            entries.insert(record, at: 0)
            entries.sort { $0.recordedAt > $1.recordedAt }
            entries = Array(entries.prefix(RecentTranscriptArchive.maximumRecords))
            unsavedIDs = Set(entries.map(\.id))
            return record.id
        }
        changeArchive(failure: "履歴をディスクへ保存できません（起動中のみ保持）") {
            try $0.insert(record)
        }
        if !entries.contains(where: { $0.id == record.id }) {
            rejectedResult = (record.id, record.text)
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

    @discardableResult public mutating func appendRetranscription(
        _ id: UUID, result: TranscriptRecord.Retranscription
    ) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return false }
        if archive == nil { entries[i].retranscriptions.append(result); return false }
        let saved = changeArchive(failure: "再文字起こし結果の保存に失敗しました") {
            try $0.appendRetranscription(id: id, result: result)
        }
        if !saved && entries.first(where: { $0.id == id })?.retranscriptions.last != result {
            rejectedResult = (id, result.text)
        }
        return saved
    }

    public mutating func delete(_ id: UUID) {
        if rejectedResult?.recordID == id { rejectedResult = nil }
        unsavedIDs.remove(id)
        guard archive != nil else { entries.removeAll { $0.id == id }; return }
        changeArchive(failure: "履歴の削除に失敗しました") { try $0.delete(id: id) }
    }

    public mutating func deleteAll() {
        rejectedResult = nil
        guard archive != nil else { entries = []; unsavedIDs = []; return }
        changeArchive(failure: "履歴の全削除に失敗しました") { try $0.deleteAll() }
    }

    private static func errorMessage(for error: Error) -> String {
        (error as? RecentTranscriptArchive.ArchiveError)?.errorDescription
            ?? UserFacingErrorMessage.message(for: error, operation: "履歴")
    }

    @discardableResult private mutating func changeArchive(
        failure: String, _ operation: (inout RecentTranscriptArchive) throws -> Void
    ) -> Bool {
        guard var store = archive else { return false }
        do {
            try operation(&store)
            persisted = store.entries
            unsavedIDs.removeAll()
            problem = ""
        } catch {
            let saved = Dictionary(persisted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            unsavedIDs = Set(store.entries.filter { saved[$0.id] != $0 }.map(\.id))
            problem = "\(failure)：\(Self.errorMessage(for: error))"
        }
        // Inserts and delivery outcomes survive failed writes in the archive's
        // working copy. A later successful write persists those same records.
        archive = store
        entries = store.entries
        return problem.isEmpty
    }
}
