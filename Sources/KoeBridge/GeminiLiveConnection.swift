#if os(macOS)
import Foundation
import KoeBridgeCore

/// One WebSocket per dictation. Do not send microphone audio until setupComplete.
/// API transport follows Google's Gemini 3.5 Transcribe Live WebSocket protocol.
@MainActor final class GeminiLiveConnection {
    var onEvent: ((TranscribeEvent) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private(set) var assembler = TranscriptAssembler()
    private var lastFinalAt: Date?
    private var turnCompleteAt: Date?
    private var failure: String?
    private var ready = false
    private var closedByClient = false
    private var endedAt: Date?
    private var firstAudioSentAt: Date?
    private var lastTranscriptionAt: Date?
    private var sentAudioChunks = 0
    private(set) var sentAudioBytes = 0
    private(set) var tokenSamples: [GeminiTokenSample] = []
    private var interimEvents = 0
    private var finalEvents = 0
    private var duplicateFinalEvents = 0
    private var receivedFrames = 0
    private var unrecognizedFrames = 0

    func connect(apiKey: String, vocabulary: [String], smart: Bool, japaneseHint: Bool) async throws {
        var components = URLComponents(string: GeminiWire.endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw ConnectionError.badURL }
        let connectionBeganAt = Date()
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        closedByClient = false
        ws.resume()
        try await ws.send(.string(GeminiWire.setup(vocabulary: vocabulary, smart: smart, japaneseHint: japaneseHint)))
        // A one-shot watchdog interrupts a stuck setup handshake.
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return } // successful setup cancels this timer
            guard let self, !self.ready else { return }
            self.failure = "Gemini接続準備がタイムアウトしました"
            self.socket?.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        while !ready {
            let message: URLSessionWebSocketTask.Message
            do { message = try await ws.receive() }
            catch { throw ConnectionError.setup(error.localizedDescription) }
            let raw = Self.string(message)
            captureUsage(raw)
            for event in try GeminiWire.parse(raw) {
                if case .error(let reason) = event { throw ConnectionError.setup(reason) }
                if case .setupComplete = event { ready = true }
                if case .final = event { handle(event) }
            }
        }
        receiver = Task { [weak self] in await self?.receiveLoop() }
        assembler.beginActivity()
        DiagnosticLog.record("gemini connected; setupSeconds=\(String(format: "%.3f", Date().timeIntervalSince(connectionBeganAt)))")
        // With automatic VAD enabled, the first audio starts recognition.
        // Do not send manual activityStart in this mode.
    }

    private func receiveLoop() async {
        guard let ws = socket else { return }
        while !Task.isCancelled {
            do {
                let msg = try await ws.receive()
                receivedFrames += 1
                let raw = Self.string(msg)
                let gotUsage = captureUsage(raw)
                let events = try GeminiWire.parse(raw)
                if events.isEmpty && !gotUsage {
                    unrecognizedFrames += 1
                    // Log schema categories only, NEVER contents or secrets.
                    if unrecognizedFrames <= 3 {
                        DiagnosticLog.record("gemini frame without transcription event; shape=\(GeminiWire.frameKind(Self.string(msg)))")
                    }
                }
                for event in events { handle(event) }
            } catch {
                // URLSessionWebSocketTask.receive may fail independently of send.
                // Inform the recording controller immediately: otherwise the
                // overlay stays alive and a new shortcut appears to be broken.
                if !closedByClient && !Task.isCancelled {
                    handle(.error("Gemini受信が終了しました: \(error.localizedDescription)"))
                }
                break
            }
        }
    }

    @discardableResult
    private func captureUsage(_ raw: String) -> Bool {
        guard let usage = GeminiWire.parseTokenUsage(raw) else { return false }
        // A separate usageMetadata message is a separate report, even when
        // two turns happen to have equal values. Do not infer cost or estimate
        // unavailable counts. Cap transient per-session observations.
        if tokenSamples.count < 1_024 {
            tokenSamples.append(GeminiTokenSample(at: Date(), usage: usage))
        }
        return true
    }

    private func handle(_ event: TranscribeEvent) {
        // Duplicate/unchanged final events are not evidence that the service
        // finished new audio after the user stopped. Only a newly accepted
        // committed segment may advance the finalization clock.
        let committedBefore = assembler.finalCount
        assembler.apply(event)
        if case .final = event {
            finalEvents += 1
            if assembler.finalCount > committedBefore { lastFinalAt = Date() }
            else { duplicateFinalEvents += 1 }
            lastTranscriptionAt = Date()
        }
        if case .interim = event {
            interimEvents += 1
            lastTranscriptionAt = Date()
        }
        if case .turnComplete = event { turnCompleteAt = Date() }
        if case .error(let msg) = event { failure = msg }
        onEvent?(event)
    }

    func sendAudio(_ data: Data) async throws {
        guard let ws = socket, !closedByClient else { throw ConnectionError.disconnected }
        if let failure { throw ConnectionError.setup(failure) }
        // A Live socket can remain TCP-connected while silently ceasing to
        // return transcription events. Do not record for minutes in that state.
        // The generous 45s grace also tolerates a quiet microphone. This is
        // failure recovery, not a guarantee that speech was present.
        let now = Date()
        if let firstAudioSentAt, sentAudioChunks >= 100,
           now.timeIntervalSince(lastTranscriptionAt ?? firstAudioSentAt) > 45 {
            throw ConnectionError.stalled
        }
        if firstAudioSentAt == nil { firstAudioSentAt = now }
        try await ws.send(.string(GeminiWire.audio(data)))
        sentAudioChunks += 1
        sentAudioBytes += data.count
    }

    func endAudio() async throws {
        guard let ws = socket, !closedByClient else { throw ConnectionError.disconnected }
        if let failure { throw ConnectionError.setup(failure) }
        try await ws.send(.string(GeminiWire.audioStreamEnd()))
        endedAt = Date()
        DiagnosticLog.record("gemini audioStreamEnd; audioBytes=\(sentAudioBytes) audioChunks=\(sentAudioChunks) interimEvents=\(interimEvents) finalEvents=\(finalEvents) duplicateFinals=\(duplicateFinalEvents) hasPendingInterim=\(!assembler.interim.isEmpty) receivedFrames=\(receivedFrames) unrecognizedFrames=\(unrecognizedFrames)")
    }

    /// Only final segments are inserted; interim hypotheses remain previews.
    /// `turnComplete` can arrive before/after `inputTranscription`.
    func awaitFinal() async throws -> String {
        guard let endedAt else { throw ConnectionError.disconnected }
        // Avoid locking F8 for six seconds when the service never emits a
        // final. The UI will retain partial text in history on timeout.
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            try Task.checkCancellation()
            if let failure { throw ConnectionError.setup(failure) }
            if FinalizationPolicy.canFinish(endedAt: endedAt, lastFinalAt: lastFinalAt,
                                            turnCompleteAt: turnCompleteAt, now: Date(),
                                            hasPendingInterim: !assembler.interim.isEmpty,
                                            lastTranscriptionAt: lastTranscriptionAt) {
                let text = assembler.committedText
                guard !text.isEmpty else { throw ConnectionError.noFinal }
                DiagnosticLog.record("gemini finalized; waitSeconds=\(String(format: "%.3f", Date().timeIntervalSince(endedAt))) finalEvents=\(finalEvents)")
                return text
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        // Never paste a prefix as if it were the whole utterance. The controller
        // saves the recoverable partial in the ten-entry history instead.
        let lastFinalAge = lastFinalAt.map { String(format: "%.2f", endedAt.timeIntervalSince($0)) } ?? "none"
        DiagnosticLog.record("gemini finalization timeout; finalEvents=\(finalEvents) interimEvents=\(interimEvents) pendingInterim=\(!assembler.interim.isEmpty) lastFinalAgeAtStop=\(lastFinalAge) sentChunks=\(sentAudioChunks)")
        throw ConnectionError.finalizationTimeout
    }

    func cancel() {
        closedByClient = true
        receiver?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        receiver = nil
        socket = nil
    }

    private static func string(_ message: URLSessionWebSocketTask.Message) -> String {
        switch message {
        case .string(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8) ?? "{}"
        @unknown default: return "{}"
        }
    }

    enum ConnectionError: Error, LocalizedError {
        case badURL, setup(String), disconnected, noFinal, stalled, finalizationTimeout
        var errorDescription: String? {
            switch self {
            case .badURL: return "Gemini接続先URLが不正です"
            case .setup(let reason): return "Gemini API: \(reason)"
            case .disconnected: return "Gemini接続がありません"
            case .noFinal: return "Geminiから確定した文字起こしが返りませんでした"
            case .stalled: return "Geminiから45秒以上文字起こしが届かないため接続を復旧します"
            case .finalizationTimeout: return "Geminiから2.5秒以内に確定結果を取得できませんでした。取得済みの文字は履歴に残します"
            }
        }
    }
}
#endif
