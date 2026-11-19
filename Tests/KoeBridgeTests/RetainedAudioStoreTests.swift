#if os(macOS)
import Foundation
import Testing
import KoeBridgeCore
@testable import KoeBridge

@MainActor struct RetainedAudioStoreTests {
    @Test func launchAndLaterSweepsWaitForReadableHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RetainedAudioStore(directory: root.appendingPathComponent("audio"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let file = store.directory.appendingPathComponent(UUID().uuidString + ".wav")
        let wav = try PCM16WAV.encode(Data([1, 0]))
        try wav.write(to: file)
        let url = root.appendingPathComponent("history.json")
        let damaged = Data("{".utf8)
        try damaged.write(to: url)
        var history = TranscriptHistoryStore(fileURL: url)
        #expect(history.loadOutcome == .failed)
        for enabled in [true, false] {
            store.reconcileAtLaunch(history: &history, retentionEnabled: enabled)
            #expect(try Data(contentsOf: file) == wav)
        }
        history.remember("new", isPartial: false, delivery: .blockedFocus, engine: "test")
        store.sweep(history: &history)
        #expect(try Data(contentsOf: url) == damaged)
        #expect(try Data(contentsOf: file) == wav)
        try Data("[]".utf8).write(to: url)
        history = TranscriptHistoryStore(fileURL: url)
        #expect(history.loadOutcome == .empty)
        store.reconcileAtLaunch(history: &history, retentionEnabled: true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func retryableReplayAndExplicitDeletionScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json")
        var history = TranscriptHistoryStore(fileURL: url)
        #expect(history.loadOutcome == .empty)
        let directory = root.appendingPathComponent("audio")
        let store = RetainedAudioStore(directory: directory, readData: { _ in throw CocoaError(.fileReadNoPermission) })
        history.remember("text", isPartial: false, delivery: .reviewRequired, engine: "test")
        let record = try #require(history.entries.first)
        store.write(pcm: Data([1, 0]), record: record, history: &history)
        let file = directory.appendingPathComponent(record.id.uuidString + ".wav")
        let original = try Data(contentsOf: file)
        #expect(throws: RetainedAudioStore.ReplayError.retryableRead) { try store.read(record.id, history: &history) }
        #expect(try Data(contentsOf: file) == original)
        #expect(history.entries.first?.audioAsset != nil)
        #expect(TranscriptHistoryStore(fileURL: url).loadOutcome == .loaded)
        let other = directory.appendingPathComponent("keep.json")
        try Data([7]).write(to: other)
        store.clear(history: &history)
        #expect(try Data(contentsOf: other) == Data([7]))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(history.entries.first?.audioAsset == nil)
        #expect(history.entries.first?.audioUnavailableReason != nil)
        #expect(history.entries.first?.text == record.text)
    }

    @Test func privateFilesExpiryEvictionAndReconciliation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var history = TranscriptHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let store = RetainedAudioStore(directory: root.appendingPathComponent("audio"), capacity: 100)
        let now = Date()
        let pcm = Data([0, 1, 2, 3]) // 48 bytes with header; capacity holds two
        var ids: [UUID] = []
        for index in 0..<3 {
            let rememberedID = history.remember("text", isPartial: false, delivery: .automaticPasteDisabled,
                engine: "test", recordedAt: now.addingTimeInterval(Double(index) - 3))
            let id = try #require(rememberedID)
            ids.append(id)
            let record = try #require(history.entries.first { $0.id == id })
            store.write(pcm: pcm, record: record, history: &history)
        }
        #expect(store.fileCount == 2 && store.bytesUsed == 96)
        #expect(history.entries.first { $0.id == ids[0] }?.audioAsset == nil)
        let newest = store.directory.appendingPathComponent(ids[2].uuidString + ".wav")
        #expect(try PCM16WAV.extractPCM(Data(contentsOf: newest)) == pcm)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: newest.path)
        #expect((dirAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let orphan = store.directory.appendingPathComponent("orphan.wav")
        try pcm.write(to: orphan)
        try FileManager.default.removeItem(at: newest)
        store.sweep(history: &history, now: now)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(history.entries.first { $0.id == ids[2] }?.audioAsset == nil)
        #expect(history.entries.first { $0.id == ids[2] }?.audioUnavailableReason != nil)
        store.sweep(history: &history, now: now.addingTimeInterval(7 * 86400))
        #expect(store.bytesUsed == 0 && store.fileCount == 0)
        #expect(history.entries.count == 3)
    }

    @Test func recordDeletionClearAndOversizeNeverLoseText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var history = TranscriptHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let store = RetainedAudioStore(directory: root.appendingPathComponent("audio"))
        let rememberedID = history.remember("keep text", isPartial: false, delivery: .reviewRequired, engine: "test")
        let id = try #require(rememberedID)
        let record = try #require(history.entries.first)
        store.write(pcm: Data(count: 14_000_002), record: record, history: &history)
        #expect(history.entries.first?.audioAsset == nil && store.fileCount == 0)
        store.write(pcm: Data([1, 0]), record: record, history: &history)
        #expect(store.fileCount == 1)
        store.clear(history: &history)
        #expect(store.fileCount == 0 && history.entries.first?.text == "keep text")
        store.write(pcm: Data([1, 0]), record: record, history: &history)
        history.delete(id)
        store.sweep(history: &history)
        #expect(store.fileCount == 0)
        store.write(pcm: Data([1, 0]), record: record, history: &history)
        store.sweep(history: &history)
        #expect(store.fileCount == 0) // stale writer cannot leave an orphan
        let rememberedMeetingID = history.remember("meeting", isPartial: false,
            delivery: .automaticPasteDisabled, engine: "test", kind: "meeting")
        let meetingID = try #require(rememberedMeetingID)
        let meeting = try #require(history.entries.first { $0.id == meetingID })
        store.write(pcm: Data([1, 0]), record: meeting, history: &history)
        #expect(history.entries.first?.audioAsset == nil && store.fileCount == 0)
        let rememberedNextID = history.remember("next", isPartial: false,
            delivery: .automaticPasteDisabled, engine: "test")
        let nextID = try #require(rememberedNextID)
        let next = try #require(history.entries.first { $0.id == nextID })
        store.write(pcm: Data([1, 0]), record: next, history: &history)
        history.deleteAll()
        store.sweep(history: &history)
        #expect(store.fileCount == 0)
    }

    @Test func failedWriteKeepsHistoryAndCorruptReplayClearsReference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var history = TranscriptHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let rememberedID = history.remember("keep", isPartial: false, delivery: .reviewRequired, engine: "test")
        let id = try #require(rememberedID)
        let record = try #require(history.entries.first)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: blocked)
        let failing = RetainedAudioStore(directory: blocked)
        failing.write(pcm: Data([1, 0]), record: record, history: &history)
        #expect(history.entries.first?.text == "keep" && history.entries.first?.audioAsset == nil)
        let store = RetainedAudioStore(directory: root.appendingPathComponent("audio"))
        store.write(pcm: Data([1, 0]), record: record, history: &history)
        try Data(count: 46).write(to: store.directory.appendingPathComponent(id.uuidString + ".wav"))
        #expect(throws: (any Error).self) { _ = try store.read(id, history: &history) }
        #expect(history.entries.first?.audioAsset == nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(id.uuidString + ".wav").path))
        #expect(history.entries.first?.text == "keep")
        history.updateAudio(id, asset: .init(relativeFileName: id.uuidString + ".wav", pcmByteCount: Int.max,
            recordedAt: record.recordedAt, expiresAt: Date().addingTimeInterval(86400)))
        store.sweep(history: &history)
        #expect(history.entries.first?.audioAsset == nil) // corrupt metadata cannot overflow +44
    }
}
#endif
