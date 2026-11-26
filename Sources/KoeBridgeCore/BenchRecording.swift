import Foundation

public enum BenchSentenceCategory: Int, CaseIterable, Codable, Sendable, Hashable {
    case daily = 1
    case properNoun = 2
    case numericAlphanumeric = 3

    public var code: String {
        switch self {
        case .daily: return "D"
        case .properNoun: return "N"
        case .numericAlphanumeric: return "M"
        }
    }

    public var label: String {
        switch self {
        case .daily: return "日常文"
        case .properNoun: return "固有名詞"
        case .numericAlphanumeric: return "数字・英字"
        }
    }
}

public struct BenchSentence: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let category: BenchSentenceCategory
    public let referenceText: String

    public init(id: String, category: BenchSentenceCategory, referenceText: String) {
        self.id = id
        self.category = category
        self.referenceText = referenceText
    }

    public static let all: [BenchSentence] = [
        BenchSentence(id: "D1", category: .daily, referenceText: "明日の午後3時に、駅前のカフェで待ち合わせしましょう。"),
        BenchSentence(id: "D2", category: .daily, referenceText: "週末に冷蔵庫の中身を整理して、買い物リストを作りました。"),
        BenchSentence(id: "D3", category: .daily, referenceText: "帰りにコンビニで牛乳と卵を買ってきてください。"),
        BenchSentence(id: "D4", category: .daily, referenceText: "来月から新しいプロジェクトが始まるので、準備を進めています。"),
        BenchSentence(id: "N1", category: .properNoun, referenceText: "佐藤さんはトヨタ自動車の工場見学に参加しました。"),
        BenchSentence(id: "N2", category: .properNoun, referenceText: "鈴木先生は京都大学で人工知能の講義を担当しています。"),
        BenchSentence(id: "N3", category: .properNoun, referenceText: "高橋さんは北海道の小樽で写真展を開く予定です。"),
        BenchSentence(id: "N4", category: .properNoun, referenceText: "中村さんはパナソニックの新製品発表会を取材しました。"),
        BenchSentence(id: "M1", category: .numericAlphanumeric, referenceText: "AAPLは2.5パーセント下落しました。"),
        BenchSentence(id: "M2", category: .numericAlphanumeric, referenceText: "売上は前年比12.8パーセント増の3.4億円でした。"),
        BenchSentence(id: "M3", category: .numericAlphanumeric, referenceText: "会議の資料はPDFで共有され、バージョンは2.0です。"),
        BenchSentence(id: "M4", category: .numericAlphanumeric, referenceText: "MSFTの株価は425.60ドルで取引を終えました。")
    ]
}

public enum BenchVoiceCondition: String, CaseIterable, Codable, Sendable, Hashable {
    case normal
    case whisper

    public var label: String {
        switch self {
        case .normal: return "普通声"
        case .whisper: return "小声"
        }
    }

    public var promptLabel: String {
        switch self {
        case .normal: return "普通声で読んでください"
        case .whisper: return "小声で読んでください"
        }
    }
}

public struct BenchRecordingGroup: Identifiable, Hashable, Sendable {
    public let voice: BenchVoiceCondition
    public let repetition: Int

    public init(voice: BenchVoiceCondition, repetition: Int) {
        self.voice = voice
        self.repetition = repetition
    }

    public var id: String { "\(voice.rawValue)-\(repetition)" }
    public var title: String { "\(voice.label) \(repetition)回目" }

    public static let all: [BenchRecordingGroup] = [
        BenchRecordingGroup(voice: .normal, repetition: 1),
        BenchRecordingGroup(voice: .normal, repetition: 2),
        BenchRecordingGroup(voice: .whisper, repetition: 1),
        BenchRecordingGroup(voice: .whisper, repetition: 2)
    ]
}

public struct BenchRecordingItem: Identifiable, Equatable, Hashable, Sendable {
    public struct ParsedClipID: Equatable, Sendable {
        public let sentenceID: String
        public let voice: BenchVoiceCondition
        public let repetition: Int

        public init(sentenceID: String, voice: BenchVoiceCondition, repetition: Int) {
            self.sentenceID = sentenceID
            self.voice = voice
            self.repetition = repetition
        }
    }

    public let sentence: BenchSentence
    public let voice: BenchVoiceCondition
    public let repetition: Int

    public init(sentence: BenchSentence, voice: BenchVoiceCondition, repetition: Int) {
        self.sentence = sentence
        self.voice = voice
        self.repetition = repetition
    }

    public var id: String { clipID }

    public var clipID: String {
        "p1-\(sentence.id.lowercased())-\(voice.rawValue)-\(repetition)"
    }

    public var fileName: String {
        clipID + ".wav"
    }

    public var group: BenchRecordingGroup {
        BenchRecordingGroup(voice: voice, repetition: repetition)
    }

    public static let all: [BenchRecordingItem] = {
        var result: [BenchRecordingItem] = []
        result.reserveCapacity(BenchSentence.all.count * BenchRecordingGroup.all.count)
        for group in BenchRecordingGroup.all {
            for sentence in BenchSentence.all {
                result.append(BenchRecordingItem(sentence: sentence, voice: group.voice, repetition: group.repetition))
            }
        }
        return result
    }()

    private static let byClipID: [String: BenchRecordingItem] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.clipID, $0) }
    )

    public static func item(forClipID clipID: String) -> BenchRecordingItem? {
        byClipID[clipID]
    }

    public static func items(in group: BenchRecordingGroup) -> [BenchRecordingItem] {
        all.filter { $0.voice == group.voice && $0.repetition == group.repetition }
    }

    public static func parse(clipID: String) -> ParsedClipID? {
        let parts = clipID.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "p1" else { return nil }
        let rawSentence = parts[1]
        guard rawSentence == rawSentence.lowercased(),
              let sentence = BenchSentence.all.first(where: { $0.id.lowercased() == rawSentence }),
              let voice = BenchVoiceCondition(rawValue: parts[2]),
              let rep = Int(parts[3]),
              (rep == 1 || rep == 2),
              String(rep) == parts[3] else {
            return nil
        }
        return ParsedClipID(sentenceID: sentence.id, voice: voice, repetition: rep)
    }
}

public struct BenchRecordingProgressStore: Equatable, Sendable {
    public static let minimumRecommendedDuration: TimeInterval = 0.3
    public static let maximumRecordingDuration: TimeInterval = 60.0
    public static let pcmBytesPerSecond = 32_000

    public struct ItemProgress: Codable, Equatable, Sendable {
        public let clipID: String
        public let recorded: Bool
        public let duration: TimeInterval
        public let fileName: String
        public let recordedAt: Date

        public init(clipID: String, recorded: Bool, duration: TimeInterval, fileName: String, recordedAt: Date) {
            self.clipID = clipID
            self.recorded = recorded
            self.duration = duration
            self.fileName = fileName
            self.recordedAt = recordedAt
        }

        public var isTooShort: Bool {
            recorded && duration < BenchRecordingProgressStore.minimumRecommendedDuration
        }
    }

    public struct ProgressDocument: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var items: [String: ItemProgress]

        public init(schemaVersion: Int = 1, items: [String: ItemProgress] = [:]) {
            self.schemaVersion = schemaVersion
            self.items = items
        }
    }

    public enum LoadOutcome: Equatable, Sendable {
        case empty
        case loaded
        case recoveredFromCorrupt
    }

    public static var defaultCacheRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("koebridge-bench", isDirectory: true)
    }

    public static var defaultAudioDirectory: URL {
        defaultCacheRoot.appendingPathComponent("audio", isDirectory: true)
    }

    public static var defaultProgressFileURL: URL {
        defaultCacheRoot.appendingPathComponent("recording-progress.json")
    }

    public let audioDirectory: URL
    public let progressFileURL: URL
    public private(set) var entries: [String: ItemProgress] = [:]
    public private(set) var loadOutcome: LoadOutcome = .empty

    public init(audioDirectory: URL = defaultAudioDirectory,
                progressFileURL: URL = defaultProgressFileURL) {
        self.audioDirectory = audioDirectory
        self.progressFileURL = progressFileURL
        reload()
    }

    public mutating func reload() {
        guard FileManager.default.fileExists(atPath: progressFileURL.path) else {
            entries = [:]
            loadOutcome = .empty
            return
        }
        do {
            let data = try Data(contentsOf: progressFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let doc = try decoder.decode(ProgressDocument.self, from: data)
            guard doc.schemaVersion == 1 else {
                entries = [:]
                loadOutcome = .recoveredFromCorrupt
                return
            }
            var validated: [String: ItemProgress] = [:]
            for (key, value) in doc.items {
                guard key == value.clipID,
                      let item = BenchRecordingItem.item(forClipID: value.clipID),
                      value.fileName == item.fileName,
                      value.duration.isFinite,
                      value.duration >= 0 else {
                    continue
                }
                if value.recorded {
                    validated[key] = value
                }
            }
            entries = validated
            loadOutcome = .loaded
        } catch {
            // Fail-safe recovery: never crash or delete existing WAV files on state loss.
            entries = [:]
            loadOutcome = .recoveredFromCorrupt
        }
    }

    public var recordedCount: Int {
        BenchRecordingItem.all.reduce(0) { count, item in
            count + (isRecorded(item.clipID) ? 1 : 0)
        }
    }

    public func isRecorded(_ clipID: String) -> Bool {
        entries[clipID]?.recorded == true
    }

    public func progress(for clipID: String) -> ItemProgress? {
        entries[clipID]
    }

    public func audioFileURL(for item: BenchRecordingItem) -> URL {
        audioDirectory.appendingPathComponent(item.fileName)
    }

    /// Picks the next unrecorded item after `currentClipID`, wrapping around if needed.
    public func nextUnrecordedItem(after currentClipID: String? = nil) -> BenchRecordingItem? {
        let all = BenchRecordingItem.all
        if let currentClipID,
           let startIndex = all.firstIndex(where: { $0.clipID == currentClipID }) {
            let tail = all[(startIndex + 1)...]
            if let match = tail.first(where: { !isRecorded($0.clipID) }) {
                return match
            }
            let head = all[..<startIndex]
            return head.first(where: { !isRecorded($0.clipID) })
        }
        return all.first(where: { !isRecorded($0.clipID) })
    }

    @discardableResult
    public mutating func saveRecording(for item: BenchRecordingItem,
                                       pcm16LE: Data,
                                       recordedAt: Date = Date()) throws -> ItemProgress {
        let wav = try PCM16WAV.encode(pcm16LE)
        let manager = FileManager.default
        try manager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let fileURL = audioFileURL(for: item)
        try wav.write(to: fileURL, options: .atomic)

        let duration = Double(pcm16LE.count) / Double(Self.pcmBytesPerSecond)
        let entry = ItemProgress(
            clipID: item.clipID,
            recorded: true,
            duration: duration,
            fileName: item.fileName,
            recordedAt: recordedAt
        )
        entries[item.clipID] = entry
        try persist()
        return entry
    }

    private func persist() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: progressFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ProgressDocument(schemaVersion: 1, items: entries))
        try data.write(to: progressFileURL, options: .atomic)
    }
}
