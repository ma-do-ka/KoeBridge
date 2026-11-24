#if os(macOS)
import Foundation
import KoeBridgeCore

// Inject the wire transport so setup, receive, and adoption can be exercised offline.
public protocol GeminiSocket: Sendable {
    var state: URLSessionTask.State { get }
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}
extension URLSessionWebSocketTask: GeminiSocket {}

private final class GeminiPingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return }
        self.continuation = continuation
        lock.unlock()
    }
    @discardableResult func resolve(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}

/// One socket and one manual activity per take. Setup does not assert speech.
/// Start, admitted PCM, and end markers all share the same ordered send queue.
@MainActor public final class GeminiLiveConnection {
    public var onEvent: ((TranscribeEvent) -> Void)?
    private var socket: (any GeminiSocket)?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var sendTail: Task<Void, Error>?
    private var endTask: Task<Void, Error>?
    public private(set) var assembler: TranscriptAssembler
    private var receivedGoAway = false
    private let makeSocket: (URL) -> any GeminiSocket

    public init(finalBudget: TranscriptAssembler.FinalBudget? = .dictation,
                makeSocket: @escaping (URL) -> any GeminiSocket = { URLSession.shared.webSocketTask(with: $0) }) {
        assembler = TranscriptAssembler(budget: finalBudget)
        self.makeSocket = makeSocket
    }
    private var lastFinalAt: ContinuousClock.Instant?
    private var endpointState = TimedManualEndpointState<ContinuousClock.Instant>()
    private var failure: String?
    private var ready = false
    private var started = false
    private var activityStartQueued = false
    private var closedByClient = false
    private var inputEnded = false
    private var endSendBeganInstant: ContinuousClock.Instant?
    private var completedText: String?
    private var lastTranscriptionAt: ContinuousClock.Instant?
    private var sentAudioChunks = 0
    public private(set) var sentAudioBytes = 0
    public private(set) var tokenSamples: [GeminiTokenSample] = []
    private var interimEvents = 0
    private var finalEvents = 0
    private var duplicateFinalEvents = 0
    private var receivedFrames = 0
    private var unrecognizedFrames = 0

    public var isUsableForPrewarm: Bool { ready && !receivedGoAway && !closedByClient && failure == nil && socket?.state == .running }

    public func connect(apiKey: String, vocabulary: [String], style: TranscriptionStyle, japaneseHint: Bool) async throws {
        guard !started, !closedByClient else { throw ConnectionError.disconnected }
        started = true
        try Task.checkCancellation()
        var components = URLComponents(string: GeminiWire.endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw ConnectionError.badURL }
        let connectionBeganAt = Date()
        let ws = makeSocket(url)
        socket = ws
        ws.resume()
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, !self.ready, !self.closedByClient else { return }
            self.failure = "Gemini接続準備がタイムアウトしました"
            ws.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await ws.send(.string(GeminiWire.setup(vocabulary: vocabulary, style: style, japaneseHint: japaneseHint)))
                var setupComplete = false
                while !setupComplete {
                    try Task.checkCancellation()
                    let frame = try Self.decode(try await ws.receive())
                    if frame.announcesGoAway { receivedGoAway = true }
                    captureUsage(frame.tokenUsage)
                    for event in frame.events {
                        if case .providerError(let failure) = event { throw failure }
                        if case .setupComplete = event { setupComplete = true }
                    }
                }
                try checkOpen()
                assembler.beginActivity()
                receiver = Task { [weak self] in await self?.receiveLoop() }
                // Do not call activityStart merely because the user pressed a key.
                // sendAudio queues it once, immediately before the first admitted PCM.
                ready = true
            } onCancel: { ws.cancel(with: .goingAway, reason: nil) }
        } catch {
            EngineDiagnostics.record("gemini connection failed; \(Self.diagnosticFailure(error))")
            let reason = failure ?? Self.connectionFailureReason(for: error)
            cancel()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw ConnectionError.setup(reason)
        }
        heartbeat = Task { [weak self] in await self?.heartbeatLoop() }
        EngineDiagnostics.record("gemini connected; speechStartDeferred=true setupSeconds=\(String(format: "%.3f", Date().timeIntervalSince(connectionBeganAt)))")
    }

    public static func diagnosticFailure(_ error: Error) -> String {
        if let provider = error as? GeminiProviderError { return provider.diagnostic }
        return "kind=connection code=\((error as NSError).code)"
    }

    public static func connectionFailureReason(for error: Error) -> String {
        if let provider = error as? GeminiProviderError { return provider.localizedDescription }
        if let connectionError = error as? ConnectionError {
            if case .setup = connectionError {
                return UserFacingErrorMessage.message(for: error, operation: "Geminiへの接続")
            }
            if let description = connectionError.errorDescription { return description }
        }
        return UserFacingErrorMessage.message(for: error, operation: "Geminiへの接続")
    }

    private func receiveLoop() async {
        guard let ws = socket else { return }
        while !Task.isCancelled && !closedByClient {
            do {
                let msg = try await ws.receive()
                guard !closedByClient, !Task.isCancelled else { return }
                receivedFrames += 1
                let frame = try Self.decode(msg)
                if frame.announcesGoAway { receivedGoAway = true }
                let gotUsage = captureUsage(frame.tokenUsage)
                if frame.events.isEmpty && !gotUsage {
                    unrecognizedFrames += 1
                    if unrecognizedFrames <= 3 {
                        EngineDiagnostics.record("gemini frame without transcription event; shape=\(frame.diagnosticKind)")
                    }
                }
                for event in frame.events {
                    if case .providerError(let failure) = event {
                        EngineDiagnostics.record("gemini API error; \(Self.diagnosticFailure(failure))")
                        handle(.error(failure.localizedDescription),
                            segmentIdentity: frame.finalSegmentIdentity)
                    } else {
                        handle(event, segmentIdentity: frame.finalSegmentIdentity)
                    }
                }
            } catch {
                if !closedByClient && !Task.isCancelled {
                    EngineDiagnostics.record("gemini receive failed; \(Self.diagnosticFailure(error))")
                    handle(.error(UserFacingErrorMessage.message(for: error, operation: "Geminiの受信")))
                }
                return
            }
        }
    }

    private func heartbeatLoop() async {
        guard let ws = socket else { return }
        while !Task.isCancelled && !closedByClient {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard !closedByClient, !Task.isCancelled else { return }
            let completion = GeminiPingCompletion()
            let watchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard completion.resolve(.failure(ConnectionError.stalled)) else { return }
                guard let self, !self.closedByClient else { return }
                self.handle(.error("Gemini接続の応答確認がタイムアウトしました"))
                ws.cancel(with: .goingAway, reason: nil)
            }
            do {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        completion.install(continuation)
                        ws.sendPing { error in
                            if let error { completion.resolve(.failure(error)) }
                            else { completion.resolve(.success(())) }
                        }
                    }
                } onCancel: {
                    completion.resolve(.failure(CancellationError()))
                    ws.cancel(with: .goingAway, reason: nil)
                }
                watchdog.cancel()
            } catch {
                watchdog.cancel()
                if !closedByClient && !Task.isCancelled {
                    handle(.error("Gemini接続の応答確認に失敗しました"))
                }
                return
            }
        }
    }

    @discardableResult private func captureUsage(_ usage: GeminiTokenUsage?) -> Bool {
        guard let usage else { return false }
        if tokenSamples.count < 1_024 { tokenSamples.append(GeminiTokenSample(at: Date(), usage: usage)) }
        return true
    }
    private func handle(_ event: TranscribeEvent, segmentIdentity: String? = nil) {
        guard !closedByClient, completedText == nil else { return }
        if !activityStartQueued {
            // Setup/keepalive responses cannot become an utterance. Preserve
            // transport failures, but never retain a pre-speech text hypothesis.
            if case .error(let message) = event { failure = message; onEvent?(event) }
            return
        }
        let now = ContinuousClock.now
        let committedBefore = assembler.finalCount
        assembler.apply(event, segmentIdentity: segmentIdentity)
        if assembler.exceededFinalBudget {
            onEvent?(.error(ConnectionError.finalBudgetExceeded.localizedDescription))
            cancel()
            return
        }
        if case .final = event {
            finalEvents += 1
            if assembler.finalCount > committedBefore { lastFinalAt = now }
            else { duplicateFinalEvents += 1 }
            lastTranscriptionAt = now
        }
        if case .interim = event { interimEvents += 1; lastTranscriptionAt = now }
        if case .turnComplete = event { endpointState.receiveTurnComplete(at: now) }
        if case .activityEnd = event { endpointState.receiveActivityEnd(at: now) }
        if case .error(let msg) = event { failure = msg }
        onEvent?(event)
    }
    private func checkOpen() throws {
        try Task.checkCancellation()
        if assembler.exceededFinalBudget { throw ConnectionError.finalBudgetExceeded }
        guard socket != nil, !closedByClient else { throw ConnectionError.disconnected }
        if let failure { throw ConnectionError.setup(failure) }
    }

    /// Queue before awaiting: MainActor methods may reenter during network waits.
    private enum OutgoingMessage {
        case control(String)
        case audio(Data)
    }

    private func enqueue(_ message: OutgoingMessage, ending: Bool = false) throws -> Task<Void, Error> {
        try checkOpen()
        guard let ws = socket else { throw ConnectionError.disconnected }
        let predecessor = sendTail
        let task = Task { [weak self] in
            try await predecessor?.value
            guard let self else { throw ConnectionError.disconnected }
            try self.checkOpen()
            let raw: String
            switch message {
            case .control(let value): raw = value
            case .audio(let pcm):
                raw = try await Self.audioMessage(pcm)
                try self.checkOpen()
            }
            let watchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, !self.closedByClient else { return }
                self.handle(.error("Geminiへの音声送信がタイムアウトしました"))
                ws.cancel(with: .goingAway, reason: nil)
            }
            defer { watchdog.cancel() }
            if ending {
                self.endSendBeganInstant = ContinuousClock.now
                self.endpointState.beginEnd()
            }
            do {
                try await ws.send(.string(raw))
                try self.checkOpen()
                if ending { self.endpointState.endWriteSucceeded(at: .now) }
            } catch {
                if ending { self.endpointState.endWriteFailed() }
                throw error
            }
        }
        sendTail = task
        return task
    }
    private func awaitSend(_ task: Task<Void, Error>) async throws {
        let ws = socket
        try await withTaskCancellationHandler {
            try await task.value
            try checkOpen()
        } onCancel: {
            task.cancel(); ws?.cancel(with: .goingAway, reason: nil)
        }
    }

    public nonisolated static func audioMessage(_ data: Data) async throws -> String {
        try GeminiWire.audio(data)
    }

    public func sendAudio(_ data: Data) async throws {
        try checkOpen()
        guard ready, !inputEnded else { throw ConnectionError.disconnected }
        guard !data.isEmpty else { return }
        if !activityStartQueued {
            _ = try enqueue(.control(GeminiWire.activityStart()))
            activityStartQueued = true
        }
        let task = try enqueue(.audio(data))
        try await awaitSend(task)
        sentAudioChunks += 1
        sentAudioBytes += data.count
    }
    public func endAudio() async throws {
        if let endTask { try await awaitSend(endTask); return }
        try checkOpen()
        guard ready else { throw ConnectionError.disconnected }
        guard activityStartQueued else { throw ConnectionError.noFinal }
        inputEnded = true
        let task = try enqueue(.control(GeminiWire.activityEnd()), ending: true)
        endTask = task
        try await awaitSend(task)
        EngineDiagnostics.record("gemini activityEnd; audioBytes=\(sentAudioBytes) audioChunks=\(sentAudioChunks) interimEvents=\(interimEvents) finalEvents=\(finalEvents) duplicateFinals=\(duplicateFinalEvents) hasPendingInterim=\(!assembler.interim.isEmpty) receivedFrames=\(receivedFrames) unrecognizedFrames=\(unrecognizedFrames)")
    }

    public func awaitFinal() async throws -> String {
        if let completedText { return completedText }
        defer { if completedText == nil { cancel() } }
        try checkOpen()
        guard let endTask else { throw ConnectionError.disconnected }
        try await awaitSend(endTask)
        guard let endedAt = endpointState.writeCompletedAt else { throw ConnectionError.disconnected }
        let deadline = (endSendBeganInstant ?? ContinuousClock.now).advanced(by: .seconds(FinalizationPolicy.maximumWaitSeconds))
        while ContinuousClock.now < deadline {
            try checkOpen()
            if !assembler.hasConflictingFinals,
               FinalizationPolicy.canFinish(endedAt: endedAt, lastFinalAt: lastFinalAt,
                                            endAcknowledgedAt: endpointState.acknowledgedEndAt, now: .now,
                                            hasPendingInterim: !assembler.interim.isEmpty,
                                            lastTranscriptionAt: lastTranscriptionAt) {
                let text = assembler.committedText
                guard !text.isEmpty else { throw ConnectionError.noFinal }
                completedText = text
                EngineDiagnostics.record("gemini finalized; waitSeconds=\(endedAt.duration(to: .now)) finalEvents=\(finalEvents)")
                cancel()
                return text
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let lastFinalAge = lastFinalAt.map { $0.duration(to: endedAt).description } ?? "none"
        EngineDiagnostics.record("gemini finalization timeout; finalEvents=\(finalEvents) interimEvents=\(interimEvents) pendingInterim=\(!assembler.interim.isEmpty) lastFinalAgeAtStop=\(lastFinalAge) sentChunks=\(sentAudioChunks)")
        cancel()
        throw ConnectionError.finalizationTimeout
    }
    public func cancel() {
        closedByClient = true; ready = false
        endpointState.cancel()
        receiver?.cancel(); heartbeat?.cancel(); sendTail?.cancel(); endTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        receiver = nil; heartbeat = nil; sendTail = nil; endTask = nil; socket = nil; onEvent = nil
    }
    private static func decode(_ message: URLSessionWebSocketTask.Message) throws -> GeminiServerFrame {
        switch message {
        case .string(let raw): return try GeminiWire.decode(raw)
        case .data(let data): return try GeminiServerFrame(data: data)
        @unknown default: throw WireError.invalidResponse
        }
    }
    public enum ConnectionError: Error, LocalizedError {
        case badURL, setup(String), disconnected, noFinal, stalled, finalizationTimeout, finalBudgetExceeded
        public var errorDescription: String? {
            switch self {
            case .finalBudgetExceeded: return "認識結果の上限に達したため中断しました。取得済みの文字は途中結果として確認できます"
            case .badURL: return "Gemini接続先URLが不正です"
            case .setup(let reason): return "Gemini API: \(reason)"
            case .disconnected: return "Gemini接続がありません"
            case .noFinal: return "Geminiから確定した文字起こしが返りませんでした"
            case .stalled: return "Gemini接続の応答が停止したため接続を復旧します"
            case .finalizationTimeout: return "Geminiから8秒以内に確定結果を取得できませんでした。取得済みの文字は履歴に残します"
            }
        }
    }
}
#endif
