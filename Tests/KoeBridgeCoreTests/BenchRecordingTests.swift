import Foundation
import Testing
@testable import KoeBridgeCore

struct BenchRecordingTests {
    private static let expectedReferences: [String: String] = [
        "D1": "明日の午後3時に、駅前のカフェで待ち合わせしましょう。",
        "D2": "週末に冷蔵庫の中身を整理して、買い物リストを作りました。",
        "D3": "帰りにコンビニで牛乳と卵を買ってきてください。",
        "D4": "来月から新しいプロジェクトが始まるので、準備を進めています。",
        "N1": "佐藤さんはトヨタ自動車の工場見学に参加しました。",
        "N2": "鈴木先生は京都大学で人工知能の講義を担当しています。",
        "N3": "高橋さんは北海道の小樽で写真展を開く予定です。",
        "N4": "中村さんはパナソニックの新製品発表会を取材しました。",
        "M1": "AAPLは2.5パーセント下落しました。",
        "M2": "売上は前年比12.8パーセント増の3.4億円でした。",
        "M3": "会議の資料はPDFで共有され、バージョンは2.0です。",
        "M4": "MSFTの株価は425.60ドルで取引を終えました。"
    ]

    @Test func itemTableIntegrityAndClipIDRoundTrip() throws {
        #expect(BenchSentence.all.count == 12)
        #expect(BenchRecordingGroup.all.count == 4)
        #expect(BenchRecordingItem.all.count == 48)

        let clipIDs = BenchRecordingItem.all.map(\.clipID)
        #expect(Set(clipIDs).count == 48)

        for sentence in BenchSentence.all {
            #expect(Self.expectedReferences[sentence.id] == sentence.referenceText)
        }
        #expect(BenchSentence.all.filter { $0.category == .daily }.count == 4)
        #expect(BenchSentence.all.filter { $0.category == .properNoun }.count == 4)
        #expect(BenchSentence.all.filter { $0.category == .numericAlphanumeric }.count == 4)

        for item in BenchRecordingItem.all {
            let parsed = try #require(BenchRecordingItem.parse(clipID: item.clipID))
            #expect(parsed.sentenceID == item.sentence.id)
            #expect(parsed.voice == item.voice)
            #expect(parsed.repetition == item.repetition)
            #expect(BenchRecordingItem.item(forClipID: item.clipID) == item)
            #expect(item.fileName == item.clipID + ".wav")
        }

        #expect(BenchRecordingItem.parse(clipID: "p1-d1-normal-1") == .init(sentenceID: "D1", voice: .normal, repetition: 1))
        #expect(BenchRecordingItem.parse(clipID: "p1-m4-whisper-2") == .init(sentenceID: "M4", voice: .whisper, repetition: 2))
        #expect(BenchRecordingItem.parse(clipID: "p1-D1-normal-1") == nil)
        #expect(BenchRecordingItem.parse(clipID: "p2-d1-normal-1") == nil)
        #expect(BenchRecordingItem.parse(clipID: "p1-d1-loud-1") == nil)
        #expect(BenchRecordingItem.parse(clipID: "p1-d1-normal-3") == nil)
        #expect(BenchRecordingItem.parse(clipID: "p1-d1-normal-01") == nil)
    }

    @Test func canonicalWAVHeaderAndPayloadRoundTrip() throws {
        var pcm = Data(capacity: 3_200)
        for sampleIndex in 0..<1_600 {
            let sample = Int16(truncatingIfNeeded: (sampleIndex * 199) - 16_000).littleEndian
            pcm.append(UInt8(truncatingIfNeeded: sample))
            pcm.append(UInt8(truncatingIfNeeded: Int(sample) >> 8))
        }
        let wav = try PCM16WAV.encode(pcm)
        #expect(wav.count == 44 + pcm.count)

        func u16(at offset: Int) -> UInt16 {
            UInt16(wav[offset]) | (UInt16(wav[offset + 1]) << 8)
        }
        func u32(at offset: Int) -> UInt32 {
            UInt32(wav[offset])
                | (UInt32(wav[offset + 1]) << 8)
                | (UInt32(wav[offset + 2]) << 16)
                | (UInt32(wav[offset + 3]) << 24)
        }

        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(u32(at: 4) == UInt32(pcm.count + 36))
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: wav[12..<16], as: UTF8.self) == "fmt ")
        #expect(u32(at: 16) == 16)
        #expect(u16(at: 20) == 1)      // PCM
        #expect(u16(at: 22) == 1)      // mono
        #expect(u32(at: 24) == 16_000) // 16 kHz
        #expect(u32(at: 28) == 32_000) // byte rate
        #expect(u16(at: 32) == 2)      // block align
        #expect(u16(at: 34) == 16)     // bits per sample
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        #expect(u32(at: 40) == UInt32(pcm.count))
        #expect(try PCM16WAV.extractPCM(wav) == pcm)
    }

    @Test func progressStoreRoundTripsAndRecoversSafelyWithoutDeletingWAVs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BenchRec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audioDir = root.appendingPathComponent("audio", isDirectory: true)
        let progressURL = root.appendingPathComponent("recording-progress.json")

        var store = BenchRecordingProgressStore(audioDirectory: audioDir, progressFileURL: progressURL)
        #expect(store.loadOutcome == .empty)
        #expect(store.recordedCount == 0)

        let first = try #require(BenchRecordingItem.item(forClipID: "p1-d1-normal-1"))
        let second = try #require(BenchRecordingItem.item(forClipID: "p1-d2-normal-1"))
        let normalPCM = Data(repeating: 0x11, count: 16_000) // 0.5 s
        let shortPCM = Data(repeating: 0x22, count: 6_400)   // 0.2 s (< 0.3 s)

        let savedFirst = try store.saveRecording(for: first, pcm16LE: normalPCM, recordedAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(savedFirst.fileName == "p1-d1-normal-1.wav")
        #expect(savedFirst.duration == 0.5)
        #expect(!savedFirst.isTooShort)

        let savedSecond = try store.saveRecording(for: second, pcm16LE: shortPCM, recordedAt: Date(timeIntervalSince1970: 1_700_000_010))
        #expect(savedSecond.duration == 0.2)
        #expect(savedSecond.isTooShort)
        #expect(store.recordedCount == 2)
        #expect(store.nextUnrecordedItem(after: second.clipID)?.clipID == "p1-d3-normal-1")

        let reloaded = BenchRecordingProgressStore(audioDirectory: audioDir, progressFileURL: progressURL)
        #expect(reloaded.loadOutcome == .loaded)
        #expect(reloaded.recordedCount == 2)
        #expect(reloaded.progress(for: first.clipID)?.duration == 0.5)
        #expect(reloaded.progress(for: second.clipID)?.isTooShort == true)

        let firstWAV = audioDir.appendingPathComponent(first.fileName)
        let secondWAV = audioDir.appendingPathComponent(second.fileName)
        #expect(try PCM16WAV.extractPCM(Data(contentsOf: firstWAV)) == normalPCM)
        #expect(try PCM16WAV.extractPCM(Data(contentsOf: secondWAV)) == shortPCM)

        // Corrupt progress JSON must degrade to empty state without deleting existing WAVs.
        try Data("{corrupt json".utf8).write(to: progressURL, options: .atomic)
        let recovered = BenchRecordingProgressStore(audioDirectory: audioDir, progressFileURL: progressURL)
        #expect(recovered.loadOutcome == .recoveredFromCorrupt)
        #expect(recovered.recordedCount == 0)
        #expect(FileManager.default.fileExists(atPath: firstWAV.path))
        #expect(FileManager.default.fileExists(atPath: secondWAV.path))
    }
}
