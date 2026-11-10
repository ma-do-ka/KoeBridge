#if os(macOS)
import Foundation
import KoeBridgeCore

/// Main-actor owner; commits and consent changes are synchronous, so an old
/// take cannot restore audio after deletion/opt-out. Text survives every error.
@MainActor final class RetainedAudioStore {
    static let maximumBytes = 250_000_000
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    let directory: URL
    private let capacity: Int
    private(set) var bytesUsed = 0
    private(set) var fileCount = 0

    init(directory: URL = RecentTranscriptArchive.defaultFileURL.deletingLastPathComponent()
        .appendingPathComponent("RetainedAudio", isDirectory: true), capacity: Int = 250_000_000) {
        self.directory = directory; self.capacity = capacity
    }

    private func url(for record: TranscriptRecord) -> URL {
        directory.appendingPathComponent(record.id.uuidString + ".wav")
    }

    func write(pcm: Data, record: TranscriptRecord, history: inout TranscriptHistoryStore) {
        guard record.kind != "meeting", history.entries.contains(where: { $0.id == record.id }),
              !pcm.isEmpty, pcm.count <= GeminiRecheckWire.maximumPCMBytes else { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let file = url(for: record)
            try PCM16WAV.encode(pcm).write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            history.updateAudio(record.id, asset: .init(relativeFileName: file.lastPathComponent,
                pcmByteCount: pcm.count, recordedAt: record.recordedAt,
                expiresAt: record.recordedAt.addingTimeInterval(Self.lifetime)))
        } catch {
            try? FileManager.default.removeItem(at: url(for: record))
            DiagnosticLog.record("retained audio write failed")
        }
        sweep(history: &history)
    }

    /// Called at launch, after writes, after archive mutations, and before replay.
    /// Canonical UUID paths only: archive metadata never controls a filesystem path.
    func sweep(history: inout TranscriptHistoryStore, now: Date = Date()) {
        let manager = FileManager.default
        let records = history.entries
        let liveNames = Set(records.filter { $0.audioAsset != nil }.map { $0.id.uuidString + ".wav" })
        for file in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if !liveNames.contains(file.lastPathComponent) { remove(file) }
        }
        var live: [(TranscriptRecord, Int)] = []
        for record in records {
            guard let asset = record.audioAsset else { continue }
            let file = url(for: record)
            let attrs = try? manager.attributesOfItem(atPath: file.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue
            let reason: String?
            if asset.expiresAt <= now || record.recordedAt.addingTimeInterval(Self.lifetime) <= now {
                reason = "保存期間（7日）を過ぎたため音声を削除しました"
            } else if asset.pcmByteCount <= 0 || asset.pcmByteCount > GeminiRecheckWire.maximumPCMBytes
                        || !asset.pcmByteCount.isMultiple(of: 2)
                        || asset.relativeFileName != file.lastPathComponent || size != asset.pcmByteCount + 44
                        || attrs?[.type] as? FileAttributeType != .typeRegular {
                reason = "保存音声が見つからないか破損しています"
            } else { reason = nil }
            if let reason {
                remove(file); history.updateAudio(record.id, asset: nil, reason: reason)
            } else { live.append((record, size!)) }
        }
        var total = live.reduce(0) { $0 + $1.1 }
        for (record, size) in live.sorted(by: { $0.0.recordedAt < $1.0.recordedAt }) where total > capacity {
            remove(url(for: record)); total -= size
            history.updateAudio(record.id, asset: nil, reason: "保存容量（250 MB）の上限により音声を削除しました")
        }
        // Count actual files, including any deletion failure, rather than claiming space was freed.
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        fileCount = files.count
        bytesUsed = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear(history: inout TranscriptHistoryStore) {
        for record in history.entries where record.audioAsset != nil {
            history.updateAudio(record.id, asset: nil, reason: "保存音声を削除しました")
        }
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            remove(file)
        }
        sweep(history: &history)
    }

    func read(_ id: UUID, history: inout TranscriptHistoryStore) throws -> Data {
        sweep(history: &history)
        guard let record = history.entries.first(where: { $0.id == id }), record.audioAsset != nil else {
            throw ReplayError.unavailable
        }
        do {
            let pcm = try PCM16WAV.extractPCM(Data(contentsOf: url(for: record)))
            guard pcm.count == record.audioAsset?.pcmByteCount else { throw ReplayError.unavailable }
            return pcm
        } catch {
            remove(url(for: record))
            history.updateAudio(id, asset: nil, reason: "保存音声が見つからないか破損しています")
            throw error
        }
    }

    private func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { DiagnosticLog.record("retained audio deletion failed") }
    }
    enum ReplayError: Error, LocalizedError {
        case unavailable, localLimit
        var errorDescription: String? {
            switch self {
            case .unavailable: return "保存音声がありません（期限切れ・削除・未保存）"
            case .localLimit: return "Appleの再文字起こしは50秒以内の保存音声に限ります"
            }
        }
    }
}
#endif
