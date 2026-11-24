import Foundation

/// AmiVoice Cloud Platform recognition engine variants supported by KoeBridge.
public enum AmiVoiceEngine: String, CaseIterable, Codable, Sendable, Identifiable {
    case e2eJapaneseGeneral = "-a2-ja-general"
    case e2eJapaneseGeneralBatch = "-a2b-ja-general"
    case hybridJapaneseInput = "-a-general-input"
    case hybridJapaneseConversation = "-a-general"

    public var id: String { rawValue }

    public var isE2E: Bool {
        switch self {
        case .e2eJapaneseGeneral, .e2eJapaneseGeneralBatch:
            return true
        case .hybridJapaneseInput, .hybridJapaneseConversation:
            return false
        }
    }

    public var supportsInterimPreview: Bool {
        self != .e2eJapaneseGeneralBatch
    }

    public var supportsWrittenOnlyBoost: Bool {
        isE2E
    }

    public var label: String {
        switch self {
        case .e2eJapaneseGeneral: return "日本語E2E_汎用"
        case .e2eJapaneseGeneralBatch: return "日本語E2E_汎用バッチ"
        case .hybridJapaneseInput: return "音声入力_汎用"
        case .hybridJapaneseConversation: return "会話_汎用"
        }
    }

    /// Tax-included WebSocket/Sync `nolog` rate (JPY per billed speech second).
    public var nologPriceJPYPerSecond: Double { 0.04125 }
}

/// Wire framing errors when decoding AmiVoice WebSocket server text frames.
public enum AmiVoiceWireError: Error, LocalizedError, Equatable, Sendable {
    case emptyFrame
    case malformedFrame
    case invalidJSON

    public var errorDescription: String? {
        "AmiVoice APIの応答を解析できません"
    }
}

/// Only closed, finite error categories cross the AmiVoice provider trust boundary.
/// Raw provider error messages are discarded at decode time and never reach logs or UI.
public struct AmiVoiceProviderError: LocalizedError, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case authentication
        case unsupportedAudio
        case serverBusy
        case serverUnavailable
        case timeout
        case noSpeechRejected
        case rejected
    }

    public enum Command: String, Equatable, Sendable {
        case start = "s"
        case provide = "p"
        case end = "e"
    }

    public let kind: Kind
    public let diagnosticCode: String

    private init(kind: Kind, diagnosticCode: String) {
        self.kind = kind
        self.diagnosticCode = diagnosticCode
    }

    /// Maps an AmiVoice JSON utterance result `code` into a finite category.
    public init(resultCode: String) {
        switch resultCode {
        case "-":
            self.init(kind: .authentication, diagnosticCode: "result_auth")
        case "+":
            self.init(kind: .unsupportedAudio, diagnosticCode: "result_plus")
        case "%":
            self.init(kind: .unsupportedAudio, diagnosticCode: "result_percent")
        case "b":
            self.init(kind: .serverBusy, diagnosticCode: "result_b")
        case "!":
            self.init(kind: .serverUnavailable, diagnosticCode: "result_bang")
        case ">":
            self.init(kind: .serverUnavailable, diagnosticCode: "result_gt")
        case "<":
            self.init(kind: .serverUnavailable, diagnosticCode: "result_lt")
        case "#":
            self.init(kind: .serverUnavailable, diagnosticCode: "result_hash")
        case "x":
            self.init(kind: .serverUnavailable, diagnosticCode: "result_x")
        case "?":
            self.init(kind: .serverUnavailable, diagnosticCode: "result_question")
        case "$":
            self.init(kind: .timeout, diagnosticCode: "result_dollar")
        case "t":
            self.init(kind: .timeout, diagnosticCode: "result_t")
        case "s":
            self.init(kind: .timeout, diagnosticCode: "result_s")
        case "e":
            self.init(kind: .timeout, diagnosticCode: "result_e")
        case "o":
            self.init(kind: .noSpeechRejected, diagnosticCode: "result_o")
        case "c":
            self.init(kind: .rejected, diagnosticCode: "result_c")
        default:
            self.init(kind: .rejected, diagnosticCode: "result_unknown")
        }
    }

    /// Classifies a WebSocket `s`/`p`/`e` command error message and discards the raw text.
    public init(command: Command, message: String) {
        let classified = Self.classifyCommandMessage(message.lowercased())
        self.init(kind: classified.kind, diagnosticCode: "\(command.rawValue)_\(classified.suffix)")
    }

    public var diagnostic: String {
        "kind=\(kind.rawValue) code=\(diagnosticCode)"
    }

    public var errorDescription: String? {
        switch kind {
        case .authentication:
            return "AmiVoice APIキーとアクセス権を確認してください。"
        case .unsupportedAudio:
            return "音声形式がAmiVoiceで処理できませんでした。"
        case .serverBusy:
            return "AmiVoiceサーバーが混雑しています。時間をおいてもう一度お試しください。"
        case .serverUnavailable:
            return "AmiVoiceサーバーを利用できません。時間をおいてもう一度お試しください。"
        case .timeout:
            return "AmiVoiceの応答が時間内に完了しませんでした。時間をおいてもう一度お試しください。"
        case .noSpeechRejected:
            return "認識できる音声が検出されませんでした。"
        case .rejected:
            return "AmiVoiceへのリクエストが拒否されました。"
        }
    }

    private static func classifyCommandMessage(_ normalized: String) -> (kind: Kind, suffix: String) {
        if containsAny(normalized, ["auth", "appkey", "forbidden", "unauthorized", "credential", "permission"]) {
            return (.authentication, "auth")
        }
        if containsAny(normalized, ["timeout", "timed out"]) {
            return (.timeout, "timeout")
        }
        if containsAny(normalized, ["busy", "allocate", "too many", "capacity", "rate"]) {
            return (.serverBusy, "busy")
        }
        if containsAny(normalized, [
            "can't feed", "cant feed", "recognizer server", "unavailable",
            "can't connect", "cant connect", "connection", "internal",
            "server error", "maintenance", "disconnected"
        ]) {
            return (.serverUnavailable, "unavailable")
        }
        if containsAny(normalized, [
            "unsupported", "invalid audio", "audio format", "codec",
            "sample rate", "too large", "packet"
        ]) {
            return (.unsupportedAudio, "audio")
        }
        if containsAny(normalized, ["no speech", "no voice"]) {
            return (.noSpeechRejected, "no_speech")
        }
        return (.rejected, "rejected")
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}

/// Decoded AmiVoice `A` / `R` per-utterance final payload.
/// Raw provider error `message` and unrecognized `code` strings are never retained.
public struct AmiVoiceUtteranceResult: Equatable, Sendable {
    public let text: String
    public let error: AmiVoiceProviderError?
    public let utteranceID: String?
    public let startTimeMS: Int?
    public let endTimeMS: Int?

    public init(
        text: String,
        error: AmiVoiceProviderError? = nil,
        utteranceID: String? = nil,
        startTimeMS: Int? = nil,
        endTimeMS: Int? = nil
    ) {
        self.text = error == nil ? text : ""
        self.error = error
        self.utteranceID = utteranceID.flatMap { $0.isEmpty ? nil : $0 }
        self.startTimeMS = startTimeMS.flatMap { $0 >= 0 ? $0 : nil }
        self.endTimeMS = endTimeMS.flatMap { $0 >= 0 ? $0 : nil }
    }
}

/// Decoded AmiVoice WebSocket server text frame.
public enum AmiVoiceServerFrame: Equatable, Sendable {
    case startAck(AmiVoiceProviderError?)
    case provideError(AmiVoiceProviderError)
    case endAck(AmiVoiceProviderError?)
    case speechStart(ms: Int)
    case speechEnd(ms: Int)
    case recognitionStarted
    case serverInfo
    case interim(String)
    case utteranceFinal(AmiVoiceUtteranceResult)

    /// Schema category only. Never includes transcript text or raw server messages.
    public var diagnosticKind: String {
        switch self {
        case .startAck(nil): return "startAck.ok"
        case .startAck(.some): return "startAck.error"
        case .provideError: return "provideError"
        case .endAck(nil): return "endAck.ok"
        case .endAck(.some): return "endAck.error"
        case .speechStart: return "speechStart"
        case .speechEnd: return "speechEnd"
        case .recognitionStarted: return "recognitionStarted"
        case .serverInfo: return "serverInfo"
        case .interim: return "interim"
        case .utteranceFinal(let result):
            return result.error == nil ? "utteranceFinal.ok" : "utteranceFinal.error"
        }
    }
}

/// Pure-Foundation encoder and decoder for the AmiVoice WebSocket `LSB16K` protocol.
public enum AmiVoiceWire {
    /// Trailing `/` is mandatory: omitting it silently falls back to logged mode.
    public static let nologWebSocketEndpoint = "wss://acp-api.amivoice.com/v1/nolog/"
    public static let audioFormat = "LSB16K"
    public static let maximumAudioPacketBytes = 16_000_000
    public static let maximumProfileWordsBytes = 4_096
    public static let maximumProfileWordCount = 100
    public static let defaultResultUpdatedIntervalMS = 300
    public static let endCommand = "e"

    /// Builds the WebSocket `s` command. Credentials travel in the HTTP upgrade
    /// `Authorization: Bearer` header, never inline via `authorization=`.
    public static func startCommand(
        engine: AmiVoiceEngine = .e2eJapaneseGeneral,
        resultUpdatedIntervalMS: Int? = nil,
        profileWords: [String] = [],
        profileId: String? = nil
    ) -> String {
        let interval = engine.supportsInterimPreview
            ? max(0, resultUpdatedIntervalMS ?? defaultResultUpdatedIntervalMS)
            : 0
        var parts = ["s", audioFormat, engine.rawValue, "resultUpdatedInterval=\(interval)"]
        if let sanitizedProfileId = sanitizeProfileId(profileId) {
            parts.append("profileId=:\(sanitizedProfileId)")
        } else if engine.supportsWrittenOnlyBoost,
                  profileId == nil,
                  let encodedWords = encodeProfileWords(profileWords) {
            parts.append("profileWords=\"\(encodedWords)\"")
        }
        return parts.joined(separator: " ")
    }

    /// Validates a server-side `profileId`, rejecting `__`-prefixed reserved IDs
    /// and any scalar outside ASCII `[A-Za-z0-9_-]`.
    public static func sanitizeProfileId(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("__") else {
            return nil
        }
        let isValid = trimmed.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 0x30 && v <= 0x39)
                || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x61 && v <= 0x7A)
                || v == 0x5F
                || v == 0x2D
        }
        return isValid ? trimmed : nil
    }

    /// Sanitizes, deduplicates, escapes, and bounds per-request E2E `profileWords`.
    /// Returns the space-delimited value placed inside `profileWords="..."`, or `nil` if empty.
    public static func encodeProfileWords(_ words: [String]) -> String? {
        var seen = Set<String>()
        var accepted: [String] = []
        var byteCount = 0
        for raw in words {
            guard accepted.count < maximumProfileWordCount else { break }
            guard let sanitized = sanitizeProfileWord(raw) else { continue }
            guard !seen.contains(sanitized) else { continue }
            let escaped = sanitized.replacingOccurrences(of: "\"", with: "\"\"")
            let separatorBytes = accepted.isEmpty ? 0 : 1
            let addition = separatorBytes + escaped.utf8.count
            guard addition <= maximumProfileWordsBytes - byteCount else { continue }
            seen.insert(sanitized)
            accepted.append(escaped)
            byteCount += addition
        }
        guard !accepted.isEmpty else { return nil }
        return accepted.joined(separator: " ")
    }

    /// Wraps raw 16 kHz / 16-bit signed LE mono PCM in an AmiVoice binary `p` packet.
    public static func audioPacket(_ pcm16LE: Data) -> Data {
        var packet = Data(capacity: 1 + pcm16LE.count)
        packet.append(0x70)
        packet.append(pcm16LE)
        return packet
    }

    /// Decodes a single AmiVoice WebSocket server text frame.
    public static func decode(_ text: String) throws -> AmiVoiceServerFrame {
        guard let first = text.first else { throw AmiVoiceWireError.emptyFrame }
        switch first {
        case "s":
            if text == "s" { return .startAck(nil) }
            guard text.hasPrefix("s ") else { throw AmiVoiceWireError.malformedFrame }
            return .startAck(AmiVoiceProviderError(command: .start, message: String(text.dropFirst(2))))
        case "p":
            guard text.hasPrefix("p ") else { throw AmiVoiceWireError.malformedFrame }
            return .provideError(AmiVoiceProviderError(command: .provide, message: String(text.dropFirst(2))))
        case "e":
            if text == "e" { return .endAck(nil) }
            guard text.hasPrefix("e ") else { throw AmiVoiceWireError.malformedFrame }
            return .endAck(AmiVoiceProviderError(command: .end, message: String(text.dropFirst(2))))
        case "S":
            guard text.hasPrefix("S "), let ms = parseNonNegativeInt(String(text.dropFirst(2))) else {
                throw AmiVoiceWireError.malformedFrame
            }
            return .speechStart(ms: ms)
        case "E":
            guard text.hasPrefix("E "), let ms = parseNonNegativeInt(String(text.dropFirst(2))) else {
                throw AmiVoiceWireError.malformedFrame
            }
            return .speechEnd(ms: ms)
        case "C":
            guard text == "C" else { throw AmiVoiceWireError.malformedFrame }
            return .recognitionStarted
        case "G":
            guard text == "G" || text.hasPrefix("G ") else { throw AmiVoiceWireError.malformedFrame }
            return .serverInfo
        case "U":
            guard text.hasPrefix("U ") else { throw AmiVoiceWireError.malformedFrame }
            let payload = try decodeJSON(InterimPayload.self, from: String(text.dropFirst(2)))
            return .interim(stripInterimEllipsis(payload.text ?? ""))
        case "A", "R":
            guard text.hasPrefix("A ") || text.hasPrefix("R ") else {
                throw AmiVoiceWireError.malformedFrame
            }
            let payload = try decodeJSON(UtterancePayload.self, from: String(text.dropFirst(2)))
            let rawCode = payload.code ?? ""
            let error = rawCode.isEmpty ? nil : AmiVoiceProviderError(resultCode: rawCode)
            let rawText = payload.text ?? payload.results?.first?.text ?? ""
            let startTimeMS = payload.results?.first?.starttime ?? payload.starttime
            let endTimeMS = payload.results?.first?.endtime ?? payload.endtime
            return .utteranceFinal(AmiVoiceUtteranceResult(
                text: rawText,
                error: error,
                utteranceID: payload.utteranceid,
                startTimeMS: startTimeMS,
                endTimeMS: endTimeMS
            ))
        default:
            throw AmiVoiceWireError.malformedFrame
        }
    }

    private struct InterimPayload: Decodable {
        let text: String?
    }

    private struct UtteranceResultItem: Decodable {
        let text: String?
        let starttime: Int?
        let endtime: Int?
    }

    private struct UtterancePayload: Decodable {
        let text: String?
        let code: String?
        let utteranceid: String?
        let starttime: Int?
        let endtime: Int?
        let results: [UtteranceResultItem]?
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(raw.utf8))
        } catch {
            throw AmiVoiceWireError.invalidJSON
        }
    }

    private static func parseNonNegativeInt(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) else {
            return nil
        }
        return Int(trimmed)
    }

    private static func stripInterimEllipsis(_ raw: String) -> String {
        var stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasSuffix("...") {
            stripped = String(stripped.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stripped
    }

    private static func sanitizeProfileWord(_ raw: String) -> String? {
        var cleaned = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "|" || scalar == ":" { continue }
            let v = scalar.value
            let isNonWhitespaceControl = (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D)
                || (v >= 0x7F && v <= 0x9F)
            if isNonWhitespaceControl { continue }
            cleaned.append(scalar)
        }
        let parts = String(cleaned)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "_")
    }
}

/// Assembles AmiVoice WebSocket `S`/`E`/`U`/`A` frames into a bounded transcript,
/// tracking VAD speech duration and enforcing fail-closed delivery semantics.
public struct AmiVoiceTranscriptAssembler: Sendable {
    public enum Completion: Equatable, Sendable {
        case text(String)
        case noSpeech
        case budgetExceeded
        case failed(AmiVoiceProviderError)
    }

    public private(set) var finalized = ""
    public private(set) var interim = ""
    public private(set) var finalCount = 0
    public private(set) var rejectedSegmentCount = 0
    public private(set) var openSpeechStartMS: Int?
    public private(set) var speechDurationMS = 0
    public private(set) var exceededFinalBudget = false
    public private(set) var fatalError: AmiVoiceProviderError?
    public private(set) var endAcknowledged = false

    private let budget: TranscriptAssembler.FinalBudget?
    private var chargedBytes = 0

    /// Defaults to `TranscriptAssembler.FinalBudget.dictation` (256 KiB, 2,048 utterances);
    /// pass `nil` for long-running `MeetingSession` streams.
    public init(budget: TranscriptAssembler.FinalBudget? = .dictation) {
        self.budget = budget
    }

    public var speechDurationSeconds: Double {
        Double(speechDurationMS) / 1_000.0
    }

    public var displayText: String {
        if interim.isEmpty { return finalized }
        if finalized.isEmpty { return interim }
        return join(finalized, interim)
    }

    /// Preserve the assembler's existing spacing, including the tail separator.
    public var preview: RecognitionPreview {
        RecognitionPreview(
            finalizedPrefix: finalized,
            volatileTail: (needsSpace(finalized, interim) ? " " : "") + interim
        )
    }

    /// Fail-closed committed text: empty if the budget was exceeded or a fatal error occurred.
    public var committedText: String {
        (exceededFinalBudget || fatalError != nil) ? "" : finalized
    }

    /// Bounded partial text preserved for manual history recovery only; never auto-inserted.
    public var recoveryText: String { displayText }

    /// Terminal outcome evaluated once `e` ack arrives (or after a fatal/budget failure).
    public var completion: Completion {
        if exceededFinalBudget { return .budgetExceeded }
        if let fatalError { return .failed(fatalError) }
        if committedText.isEmpty { return .noSpeech }
        return .text(committedText)
    }

    public mutating func apply(_ frame: AmiVoiceServerFrame) {
        switch frame {
        case .speechStart(let ms):
            guard ms >= 0 else { return }
            openSpeechStartMS = ms
        case .speechEnd(let ms):
            guard let start = openSpeechStartMS else { return }
            openSpeechStartMS = nil
            if ms >= start {
                let delta = ms - start
                let (sum, overflow) = speechDurationMS.addingReportingOverflow(delta)
                speechDurationMS = overflow ? Int.max : sum
            }
        case .recognitionStarted, .serverInfo:
            break
        case .startAck(let error):
            if let error, fatalError == nil {
                fatalError = error
            }
        case .provideError(let error):
            if fatalError == nil {
                fatalError = error
            }
        case .endAck(let error):
            endAcknowledged = true
            if let error, fatalError == nil {
                fatalError = error
            }
        case .interim(let text):
            guard !exceededFinalBudget, fatalError == nil else { return }
            let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return }
            interim = candidate
        case .utteranceFinal(let result):
            guard !exceededFinalBudget, fatalError == nil else { return }
            if let error = result.error {
                if error.kind == .noSpeechRejected {
                    rejectedSegmentCount += 1
                    interim = ""
                } else {
                    fatalError = error
                }
                return
            }
            let segment = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else {
                interim = ""
                return
            }
            if let budget {
                let cost = segment.utf8.count + (needsSpace(finalized, segment) ? 1 : 0)
                guard cost <= budget.bytes - chargedBytes, finalCount < budget.identities else {
                    // Even an oversized first final leaves a bounded, manual-only prefix.
                    if finalized.isEmpty && interim.isEmpty {
                        var remaining = budget.bytes - chargedBytes
                        for scalar in segment.unicodeScalars {
                            guard scalar.utf8.count <= remaining else { break }
                            interim.unicodeScalars.append(scalar)
                            remaining -= scalar.utf8.count
                        }
                    }
                    exceededFinalBudget = true
                    return
                }
                chargedBytes += cost
            }
            finalized = join(finalized, segment)
            interim = ""
            finalCount += 1
        }
    }

    private func join(_ a: String, _ b: String) -> String {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        return a + (needsSpace(a, b) ? " " : "") + b
    }

    private func needsSpace(_ a: String, _ b: String) -> Bool {
        guard let left = a.last, let right = b.first else { return false }
        return left.isASCII && right.isASCII && (left.isLetter || left.isNumber) && (right.isLetter || right.isNumber)
    }
}
