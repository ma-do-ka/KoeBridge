import Foundation
import KoeBridgeCore

struct BenchRecordingSelfTests {
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

    func itemTableIntegrityAndRoundTrip() throws {
        check(BenchSentence.all.count == 12)
        check(BenchRecordingGroup.all.count == 4)
        check(BenchRecordingItem.all.count == 48)
        check(Set(BenchRecordingItem.all.map(\.clipID)).count == 48)

        for sentence in BenchSentence.all {
            check(Self.expectedReferences[sentence.id] == sentence.referenceText)
        }
        for item in BenchRecordingItem.all {
            let parsed = try require(BenchRecordingItem.parse(clipID: item.clipID))
            check(parsed.sentenceID == item.sentence.id)
            check(parsed.voice == item.voice)
            check(parsed.repetition == item.repetition)
            check(item.fileName == item.clipID + ".wav")
        }
        check(BenchRecordingItem.parse(clipID: "p1-m4-whisper-2") == .init(sentenceID: "M4", voice: .whisper, repetition: 2))
        check(BenchRecordingItem.parse(clipID: "p1-D1-normal-1") == nil)
    }

    func canonicalWAVHeaderAndPayloadRoundTrip() throws {
        let pcm = Data([0x01, 0x02, 0xFE, 0xFF, 0x10, 0x00])
        let wav = try PCM16WAV.encode(pcm)
        check(wav.count == 44 + pcm.count)
        check(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        check(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        check(String(decoding: wav[12..<16], as: UTF8.self) == "fmt ")
        check(wav[20] == 1 && wav[21] == 0)     // PCM format = 1
        check(wav[22] == 1 && wav[23] == 0)     // mono = 1
        let sampleRate = UInt32(wav[24]) | (UInt32(wav[25]) << 8) | (UInt32(wav[26]) << 16) | (UInt32(wav[27]) << 24)
        check(sampleRate == 16_000)
        check(wav[34] == 16 && wav[35] == 0)    // 16-bit
        try check(PCM16WAV.extractPCM(wav) == pcm)
    }

    func progressStorePersistenceAndCorruptRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BenchRecSelf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audioDir = root.appendingPathComponent("audio", isDirectory: true)
        let progressURL = root.appendingPathComponent("recording-progress.json")

        var store = BenchRecordingProgressStore(audioDirectory: audioDir, progressFileURL: progressURL)
        check(store.loadOutcome == .empty && store.recordedCount == 0)

        let item = try require(BenchRecordingItem.item(forClipID: "p1-d1-normal-1"))
        let pcm = Data(repeating: 0x05, count: 6_400) // 0.2s (< 0.3s)
        let saved = try store.saveRecording(for: item, pcm16LE: pcm, recordedAt: Date(timeIntervalSince1970: 1_700_000_000))
        check(saved.fileName == "p1-d1-normal-1.wav" && saved.isTooShort)

        let reloaded = BenchRecordingProgressStore(audioDirectory: audioDir, progressFileURL: progressURL)
        check(reloaded.loadOutcome == .loaded && reloaded.recordedCount == 1)
        check(reloaded.progress(for: item.clipID)?.isTooShort == true)

        try Data("bad json".utf8).write(to: progressURL, options: .atomic)
        let recovered = BenchRecordingProgressStore(audioDirectory: audioDir, progressFileURL: progressURL)
        check(recovered.loadOutcome == .recoveredFromCorrupt && recovered.recordedCount == 0)
        check(FileManager.default.fileExists(atPath: audioDir.appendingPathComponent(item.fileName).path))
    }
}
