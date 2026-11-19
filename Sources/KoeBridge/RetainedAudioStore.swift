#if os(macOS)
import Foundation
import KoeBridgeCore

/// Main-actor owner; commits and consent changes are synchronous, so an old
/// take cannot restore audio after deletion/opt-out. Text survives every error.
@MainActor final class RetainedAudioStore {
    static let maximumBytes = 250_000_000
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    let directory: URL
    private let attributes: (URL) throws -> [FileAttributeKey: Any]
    private let readData: (URL) throws -> Data
    private let capacity: Int
    // Valid only for the caller's current synchronous reconciliation. Keep the
    // original retry path for holds, repairs, unknown stats and capacity evictions.
    private var validatedIDs = Set<UUID>()
    private var validUntil = Date.distantPast
    var sweepIsReusable: Bool { Date() < validUntil }

    private(set) var bytesUsed = 0
    private(set) var fileCount = 0

    init(directory: URL = RecentTranscriptArchive.defaultFileURL.deletingLastPathComponent()
        .appendingPathComponent("RetainedAudio", isDirectory: true), capacity: Int = 250_000_000,
        attributes: @escaping (URL) throws -> [FileAttributeKey: Any] = { try FileManager.default.attributesOfItem(atPath: $0.path) },
        readData: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.attributes = attributes
        self.readData = readData
        self.directory = directory; self.capacity = capacity
    }

    private func url(for record: TranscriptRecord) -> URL {
        directory.appendingPathComponent(record.id.uuidString + ".wav")
    }

    @discardableResult
    func write(pcm: Data, record: TranscriptRecord, history: inout TranscriptHistoryStore,
               followingSweep: Bool = false) -> Bool {
        guard history.isSaved(record.id), record.kind != "meeting",
              !pcm.isEmpty, pcm.count <= GeminiRecheckWire.maximumPCMBytes else { return followingSweep && sweepIsReusable }
        var observedAttributes: Result<[FileAttributeKey: Any], Error>?
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
            let expiry = record.recordedAt.addingTimeInterval(Self.lifetime)
            if followingSweep, sweepIsReusable, history.isSaved(record.id),
               !validatedIDs.contains(record.id), expiry > Date(),
               history.referencedAudioIDs == validatedIDs.union([record.id]),
               pcm.count + 44 <= capacity - bytesUsed {
                let observed = Result { try attributes(file) }
                observedAttributes = observed
                if case let .success(attrs) = observed,
                   attrs[.type] as? FileAttributeType == .typeRegular,
                   let size = (attrs[.size] as? NSNumber)?.intValue, size == pcm.count + 44 {
                    validatedIDs.insert(record.id)
                    fileCount += 1
                    bytesUsed += size
                    validUntil = min(validUntil, expiry)
                    return true
                }
            }
        } catch {
            remove(url(for: record))
            DiagnosticLog.record("retained audio write failed")
        }
        sweep(history: &history, observedID: record.id, observedAttributes: observedAttributes)
        return sweepIsReusable
    }

    func reconcileAtLaunch(history: inout TranscriptHistoryStore, retentionEnabled: Bool) {
        guard canSweep(history) else { return }
        if retentionEnabled { sweep(history: &history) } else { clear(history: &history) }
    }

    private func canSweep(_ history: TranscriptHistoryStore) -> Bool {
        guard history.loadOutcome != .failed else {
            DiagnosticLog.record("retained_audio_sweep_held reason=history_load_failed")
            return false
        }
        return true
    }

    private func wavFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "wav" }
    }

    /// Called at launch, after writes, after archive mutations, and before replay.
    /// Canonical UUID paths only: archive metadata never controls a filesystem path.
    @discardableResult
    func sweep(history: inout TranscriptHistoryStore, now: Date = Date(), observedID: UUID? = nil,
               observedAttributes: Result<[FileAttributeKey: Any], Error>? = nil) -> Set<UUID> {
        validUntil = .distantPast
        guard canSweep(history) else { return [] }
        var retryable: Set<UUID> = []
        let records = history.entries
        let liveNames = Set(history.referencedAudioIDs.map { $0.uuidString + ".wav" })
        let files = wavFiles()
        for file in files {
            if !liveNames.contains(file.lastPathComponent) { remove(file) }
        }
        var live: [(TranscriptRecord, Int)] = []
        for record in records {
            guard let asset = record.audioAsset else { continue }
            let file = url(for: record)
            let attrs: [FileAttributeKey: Any]
            do {
                if record.id == observedID, let observedAttributes { attrs = try observedAttributes.get() }
                else { attrs = try attributes(file) }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                history.updateAudio(record.id, asset: nil, reason: "保存音声が見つかりません")
                continue
            } catch {
                retryable.insert(record.id)
                DiagnosticLog.record("retained_audio_stat_retryable")
                continue
            }
            guard let size = (attrs[.size] as? NSNumber)?.intValue, let type = attrs[.type] as? FileAttributeType else {
                retryable.insert(record.id)
                continue
            }
            let reason: String?
            if asset.expiresAt <= now || record.recordedAt.addingTimeInterval(Self.lifetime) <= now {
                reason = "保存期間（7日）を過ぎたため音声を削除しました"
            } else if asset.pcmByteCount <= 0 || asset.pcmByteCount > GeminiRecheckWire.maximumPCMBytes
                        || !asset.pcmByteCount.isMultiple(of: 2)
                        || asset.relativeFileName != file.lastPathComponent || size != asset.pcmByteCount + 44
                        || type != .typeRegular {
                reason = "保存音声が見つからないか破損しています"
            } else { reason = nil }
            if let reason {
                remove(file); history.updateAudio(record.id, asset: nil, reason: reason)
            } else { live.append((record, size)) }
        }
        var total = live.reduce(0) { $0 + $1.1 }
        let oldestFirst = live.sorted(by: { $0.0.recordedAt < $1.0.recordedAt })
        var index = 0
        while total > capacity && index < oldestFirst.count {
            let (record, size) = oldestFirst[index]
            remove(url(for: record)); total -= size
            history.updateAudio(record.id, asset: nil, reason: "保存容量（250 MB）の上限により音声を削除しました")
            index += 1
        }
        refreshCounts(files)
        if retryable.isEmpty, index == 0, live.count == files.count, live.count == liveNames.count,
           fileCount == live.count, bytesUsed == total {
            validatedIDs = Set(live.map { $0.0.id })
            validUntil = live.reduce(.distantFuture) { limit, item in
                min(limit, item.0.audioAsset!.expiresAt, item.0.recordedAt.addingTimeInterval(Self.lifetime))
            }
        }
        return retryable
    }

    private func refreshCounts(_ listed: [URL]? = nil) {
        // Count actual files, including any deletion failure, rather than claiming space was freed.
        // Directory URLs can carry cached resource values from before unlink.
        let files = (listed ?? wavFiles()).map { URL(fileURLWithPath: $0.path) }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        fileCount = files.count
        bytesUsed = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear(history: inout TranscriptHistoryStore) {
        history.clearAudioReferences(reason: "保存音声を削除しました")
        for file in wavFiles() {
            remove(file)
        }
        refreshCounts()
    }

    func read(_ id: UUID, history: inout TranscriptHistoryStore) throws -> Data {
        let retryable = sweep(history: &history)
        guard !retryable.contains(id) else { throw ReplayError.retryableRead }
        guard let record = history.entries.first(where: { $0.id == id }), record.audioAsset != nil else {
            throw ReplayError.unavailable
        }
        let data: Data
        do {
            data = try readData(url(for: record))
        } catch {
            throw ReplayError.retryableRead
        }
        do {
            let pcm = try PCM16WAV.extractPCM(data)
            guard pcm.count == record.audioAsset?.pcmByteCount else { throw ReplayError.unavailable }
            return pcm
        } catch {
            remove(url(for: record))
            history.updateAudio(id, asset: nil, reason: "保存音声が見つからないか破損しています")
            throw error
        }
    }

    private func remove(_ url: URL) {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return }
            if unlink(url.path) != 0 && errno != ENOENT { DiagnosticLog.record("retained audio deletion failed") }
        }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // An already-missing file needs no deletion diagnostic.
        }
        catch { DiagnosticLog.record("retained audio deletion failed") }
    }
    enum ReplayError: Error, LocalizedError {
        case unavailable, localLimit, retryableRead
        var errorDescription: String? {
            switch self {
            case .retryableRead: return "保存音声を読み込めません。時間をおいて再試行してください"
            case .unavailable: return "保存音声がありません（期限切れ・削除・未保存）"
            case .localLimit: return "Appleの再文字起こしは50秒以内の保存音声に限ります"
            }
        }
    }
}
#endif
