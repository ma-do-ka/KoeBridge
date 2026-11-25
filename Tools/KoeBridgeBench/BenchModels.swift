import Foundation
import KoeBridgeCore

enum BenchFailure: Error, LocalizedError {
    case usage(String)
    case manifest(String)
    case input(String)
    case quota(String)
    case output(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .manifest(let message), .input(let message),
             .quota(let message), .output(let message):
            return message
        }
    }
}

enum BenchEngine: String, Codable, CaseIterable, Sendable {
    case apple
    case gemini
    case amivoice

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .gemini: return "Gemini Live"
        case .amivoice: return "AmiVoice"
        }
    }

    var reportRank: Int {
        switch self {
        case .apple: return 0
        case .gemini: return 1
        case .amivoice: return 2
        }
    }
}

enum BenchPacing: String, Sendable {
    case realtime
    case fast
}

enum BenchExecutionOrder: String, Sendable {
    case roundRobin = "round-robin"
    case fixed
}

struct BenchOptions: Sendable {
    var manifestPath = "Tools/KoeBridgeBench/corpus/manifest.json"
    var audioDir = NSHomeDirectory() + "/.cache/koebridge-bench/audio"
    var outDir = NSHomeDirectory() + "/.cache/koebridge-bench/results"
    var live = false
    var engines: [BenchEngine] = [.gemini, .apple, .amivoice]
    var amivoiceEngine = AmiVoiceEngine.e2eJapaneseGeneral.rawValue
    var pacing: BenchPacing = .realtime
    var order: BenchExecutionOrder = .roundRobin
    var usdJPY = BenchmarkCost.defaultUSDJPY
    var monthlyCapSeconds = 2_700.0
    var vocabFile: String?

    static let usage = """
    Usage: swift run KoeBridgeBench [options]

    Modes:
      --dry-run                         Validate manifest/audio without network calls (default)
      --live                            Run cloud/local engines (explicit opt-in)

    Options:
      --manifest PATH                   Corpus manifest (default: Tools/KoeBridgeBench/corpus/manifest.json)
      --audio-dir DIR                   Canonical WAV directory (default: ~/.cache/koebridge-bench/audio)
      --out DIR                         Result directory (default: ~/.cache/koebridge-bench/results)
      --engines apple,gemini,amivoice   Engines to run in live mode
      --amivoice-engine ENGINE          AmiVoice engine (default: -a2-ja-general)
      --pacing realtime|fast            Chunk pacing (default: realtime, 1,600 bytes / 50 ms)
      --order round-robin|fixed         Engine execution order (default: round-robin)
      --usd-jpy RATE                    FX rate for cost estimates (default: 158)
      --monthly-cap-seconds SECONDS     AmiVoice monthly safety cap (default: 2700)
      --vocab-file PATH                 Optional secondary vocabulary-ablation arm
      --help                            Show this help
    """

    static func parse(_ arguments: [String]) throws -> BenchOptions {
        var options = BenchOptions()
        var sawLive = false
        var sawDryRun = false
        var index = 1

        func matches(_ argument: String, _ name: String) -> Bool {
            argument == name || argument.hasPrefix(name + "=")
        }

        func takeValue(_ argument: String, _ name: String) throws -> String {
            let prefix = name + "="
            if argument.hasPrefix(prefix) {
                let value = String(argument.dropFirst(prefix.count))
                guard !value.isEmpty else { throw BenchFailure.usage("\(name) には値が必要です") }
                return value
            }
            guard index + 1 < arguments.count else {
                throw BenchFailure.usage("\(name) には値が必要です")
            }
            index += 1
            let value = arguments[index]
            guard !value.isEmpty else { throw BenchFailure.usage("\(name) には値が必要です") }
            return value
        }

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" {
                throw BenchFailure.usage(Self.usage)
            } else if argument == "--live" {
                sawLive = true
                options.live = true
            } else if argument == "--dry-run" {
                sawDryRun = true
                options.live = false
            } else if matches(argument, "--manifest") {
                options.manifestPath = expandHome(try takeValue(argument, "--manifest"))
            } else if matches(argument, "--audio-dir") {
                options.audioDir = expandHome(try takeValue(argument, "--audio-dir"))
            } else if matches(argument, "--out") {
                options.outDir = expandHome(try takeValue(argument, "--out"))
            } else if matches(argument, "--engines") {
                let raw = try takeValue(argument, "--engines")
                var parsed: [BenchEngine] = []
                for token in raw.split(separator: ",") {
                    let name = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let engine = BenchEngine(rawValue: name) else {
                        throw BenchFailure.usage("未知のエンジンです: \(name)")
                    }
                    if !parsed.contains(engine) { parsed.append(engine) }
                }
                guard !parsed.isEmpty else { throw BenchFailure.usage("--engines が空です") }
                options.engines = parsed
            } else if matches(argument, "--amivoice-engine") {
                let raw = try takeValue(argument, "--amivoice-engine")
                guard AmiVoiceEngine(rawValue: raw) != nil else {
                    throw BenchFailure.usage("未知のAmiVoiceエンジンです: \(raw)")
                }
                options.amivoiceEngine = raw
            } else if matches(argument, "--pacing") {
                let raw = try takeValue(argument, "--pacing")
                guard let pacing = BenchPacing(rawValue: raw) else {
                    throw BenchFailure.usage("--pacing は realtime または fast です")
                }
                options.pacing = pacing
            } else if matches(argument, "--order") {
                let raw = try takeValue(argument, "--order")
                guard let order = BenchExecutionOrder(rawValue: raw) else {
                    throw BenchFailure.usage("--order は round-robin または fixed です")
                }
                options.order = order
            } else if matches(argument, "--usd-jpy") {
                let raw = try takeValue(argument, "--usd-jpy")
                guard let value = Double(raw), value.isFinite, value > 0 else {
                    throw BenchFailure.usage("--usd-jpy は正の数値です")
                }
                options.usdJPY = value
            } else if matches(argument, "--monthly-cap-seconds") {
                let raw = try takeValue(argument, "--monthly-cap-seconds")
                guard let value = Double(raw), value.isFinite, value > 0 else {
                    throw BenchFailure.usage("--monthly-cap-seconds は正の数値です")
                }
                options.monthlyCapSeconds = value
            } else if matches(argument, "--vocab-file") {
                options.vocabFile = expandHome(try takeValue(argument, "--vocab-file"))
            } else {
                throw BenchFailure.usage("未知の引数です: \(argument)\n\n" + Self.usage)
            }
            index += 1
        }

        if sawLive && sawDryRun {
            throw BenchFailure.usage("--live と --dry-run は同時に指定できません")
        }
        return options
    }

    static func expandHome(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

struct CorpusAudioFormat: Codable, Equatable {
    let container: String
    let encoding: String
    let sample_rate_hz: Int
    let channels: Int
}

struct CorpusClip: Codable, Equatable {
    let id: String
    let track: Int
    let category: Int
    let category_name: String
    let file: String
    let reference: String
    let sha256: String?
    let estimated_seconds: Double
    let voice: String?
}

struct CorpusManifest: Codable {
    let schema_version: Int
    let language: String
    let audio_format: CorpusAudioFormat
    let clips: [CorpusClip]

    static func load(from path: String) throws -> CorpusManifest {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BenchFailure.manifest("manifestを読めません: \(path)")
        }
        do {
            let manifest = try JSONDecoder().decode(CorpusManifest.self, from: data)
            try manifest.validate()
            return manifest
        } catch let failure as BenchFailure {
            throw failure
        } catch {
            throw BenchFailure.manifest("manifest JSONの構造が不正です: \(path)")
        }
    }

    func validate() throws {
        guard schema_version == 1 else { throw BenchFailure.manifest("schema_version は 1 である必要があります") }
        guard language == "ja-JP" else { throw BenchFailure.manifest("language は ja-JP である必要があります") }
        guard audio_format.container == "WAV",
              audio_format.encoding == "PCM_S16LE",
              audio_format.sample_rate_hz == 16_000,
              audio_format.channels == 1 else {
            throw BenchFailure.manifest("audio_format は WAV / PCM_S16LE / 16000 Hz / mono である必要があります")
        }
        guard clips.count == 36 else { throw BenchFailure.manifest("clips は 36 件である必要があります") }

        var seen = Set<String>()
        for clip in clips {
            guard seen.insert(clip.id).inserted else {
                throw BenchFailure.manifest("clip id が重複しています: \(clip.id)")
            }
            try validate(clip)
        }
        for category in 1...6 {
            guard clips.filter({ $0.track == 1 && $0.category == category }).count == 4 else {
                throw BenchFailure.manifest("Track 1 category \(category) は 4 本である必要があります")
            }
            guard clips.filter({ $0.track == 2 && $0.category == category }).count == 2 else {
                throw BenchFailure.manifest("Track 2 category \(category) は 2 本である必要があります")
            }
        }
    }

    private func validate(_ clip: CorpusClip) throws {
        guard clip.track == 1 || clip.track == 2 else {
            throw BenchFailure.manifest("track は 1 または 2 です: \(clip.id)")
        }
        guard (1...6).contains(clip.category) else {
            throw BenchFailure.manifest("category が範囲外です: \(clip.id)")
        }
        let parts = clip.id.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts[0] == "t\(clip.track)",
              parts[1] == String(clip.category),
              let idNumber = Int(parts[2]),
              String(idNumber) == parts[2],
              idNumber >= 1,
              idNumber <= (clip.track == 1 ? 4 : 2) else {
            throw BenchFailure.manifest("clip id の形式が不正です: \(clip.id)")
        }
        guard clip.file == clip.id + ".wav" else {
            throw BenchFailure.manifest("file は <id>.wav である必要があります: \(clip.id)")
        }
        guard !clip.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BenchFailure.manifest("reference が空です: \(clip.id)")
        }
        guard clip.category_name == Self.expectedCategoryName(track: clip.track, category: clip.category) else {
            throw BenchFailure.manifest("category_name が不正です: \(clip.id)")
        }
        guard clip.estimated_seconds.isFinite,
              (10.0...45.0).contains(clip.estimated_seconds) else {
            throw BenchFailure.manifest("estimated_seconds が範囲外です: \(clip.id)")
        }
        if let sha256 = clip.sha256 {
            let validHex = sha256.count == 64 && sha256.unicodeScalars.allSatisfy { scalar in
                (0x30...0x39).contains(scalar.value) || (0x61...0x66).contains(scalar.value)
            }
            guard validHex else {
                throw BenchFailure.manifest("sha256 は小文字 hex 64 文字である必要があります: \(clip.id)")
            }
        }
        if clip.track == 1 {
            guard clip.voice == nil else {
                throw BenchFailure.manifest("Track 1 に voice は指定できません: \(clip.id)")
            }
        } else {
            let expectedVoice = idNumber == 1 ? "Kyoko" : "Otoya"
            guard clip.voice == expectedVoice else {
                throw BenchFailure.manifest("Track 2 の voice が不正です: \(clip.id)")
            }
        }
    }

    private static func expectedCategoryName(track: Int, category: Int) -> String {
        switch category {
        case 1: return "会話メモ"
        case 2: return "ビジネス・敬語と同音異義語"
        case 3: return "日本語＋英語の技術用語"
        case 4: return "数字・日付・金額・バージョン"
        case 5: return track == 1 ? "言い淀みと間" : "口語・短い区切りのある発話"
        default: return "長めの連続発話"
        }
    }
}

struct ClipAudio {
    let pcm: Data
    let sha256: String
    let bytes: Int
    let seconds: Double
}

enum AudioLoadState {
    case missing
    case invalid(String)
    case hashMismatch(actual: String)
    case loaded(ClipAudio)
}

struct GeminiTokenCounts: Encodable {
    let prompt_tokens: Int?
    let candidate_tokens: Int?
    let total_tokens: Int
}

struct EngineOutcome {
    var status = "failed"
    var rawText: String?
    var connectMS: Double?
    var ttfiMS: Double?
    var stopToFinalMS: Double?
    var speechSeconds: Double?
    var sentAudioSeconds: Double?
    var geminiTokens: GeminiTokenCounts?
    var estimatedCostJPY = 0.0
    var error: String?
}

struct BenchResultRecord: Encodable {
    let clip_id: String
    let track: Int
    let category: Int
    let engine: String
    let variant: String
    let pcm_sha256: String?
    let pcm_bytes: Int?
    let audio_seconds: Double?
    let speech_seconds: Double?
    let status: String
    let raw_text: String?
    let adopted_text: String?
    let cer_norm: Double?
    let cer_strict: Double?
    let cer_strict_spacing: Double?
    let connect_ms: Double?
    let ttfi_ms: Double?
    let stop_to_final_ms: Double?
    let gemini_tokens: GeminiTokenCounts?
    let estimated_cost_jpy: Double
    let os_version: String
    let apple_backend: String?
    let git_commit: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case clip_id, track, category, engine, variant, pcm_sha256, pcm_bytes, audio_seconds
        case speech_seconds, status, raw_text, adopted_text, cer_norm, cer_strict, cer_strict_spacing
        case connect_ms, ttfi_ms, stop_to_final_ms, gemini_tokens, estimated_cost_jpy
        case os_version, apple_backend, git_commit, error
    }

    private static func encode<T: Encodable>(
        _ value: T?,
        into container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clip_id, forKey: .clip_id)
        try container.encode(track, forKey: .track)
        try container.encode(category, forKey: .category)
        try container.encode(engine, forKey: .engine)
        try container.encode(variant, forKey: .variant)
        try Self.encode(pcm_sha256, into: &container, forKey: .pcm_sha256)
        try Self.encode(pcm_bytes, into: &container, forKey: .pcm_bytes)
        try Self.encode(audio_seconds, into: &container, forKey: .audio_seconds)
        try Self.encode(speech_seconds, into: &container, forKey: .speech_seconds)
        try container.encode(status, forKey: .status)
        try Self.encode(raw_text, into: &container, forKey: .raw_text)
        try Self.encode(adopted_text, into: &container, forKey: .adopted_text)
        try Self.encode(cer_norm, into: &container, forKey: .cer_norm)
        try Self.encode(cer_strict, into: &container, forKey: .cer_strict)
        try Self.encode(cer_strict_spacing, into: &container, forKey: .cer_strict_spacing)
        try Self.encode(connect_ms, into: &container, forKey: .connect_ms)
        try Self.encode(ttfi_ms, into: &container, forKey: .ttfi_ms)
        try Self.encode(stop_to_final_ms, into: &container, forKey: .stop_to_final_ms)
        try Self.encode(gemini_tokens, into: &container, forKey: .gemini_tokens)
        try container.encode(estimated_cost_jpy, forKey: .estimated_cost_jpy)
        try container.encode(os_version, forKey: .os_version)
        try Self.encode(apple_backend, into: &container, forKey: .apple_backend)
        try container.encode(git_commit, forKey: .git_commit)
        try Self.encode(error, into: &container, forKey: .error)
    }
}

struct QuotaLedger: Codable {
    var schema_version: Int
    var months: [String: [String: Double]]

    init(schema_version: Int = 1, months: [String: [String: Double]] = [:]) {
        self.schema_version = schema_version
        self.months = months
    }
}
