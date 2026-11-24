#if os(macOS)
import Foundation
import KoeBridgeCore

// Inject the wire transport so lazy setup, headers, framing, and finalization can be exercised offline.
public protocol AmiVoiceSocket: Sendable {
    var state: URLSessionTask.State { get }
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}
extension URLSessionWebSocketTask: AmiVoiceSocket {}

/// Refuses all HTTP redirects so the `Authorization: Bearer` header can never be forwarded off-host.
public final class AmiVoiceNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // The nolog endpoint is fixed; never forward the API-key header elsewhere.
        completionHandler(nil)
    }
}

private final class EphemeralAmiVoiceSocket: AmiVoiceSocket, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        let session = AmiVoiceWebSocketConnection.makeEphemeralSession()
        self.session = session
        self.task = session.webSocketTask(with: request)
    }

    var state: URLSessionTask.State { task.state }
    func resume() { task.resume() }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await task.send(message) }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let wasSuspended = task.state == .suspended
        task.cancel(with: closeCode, reason: reason)
        if closeCode == .normalClosure && !wasSuspended {
            session.finishTasksAndInvalidate()
        } else {
            session.invalidateAndCancel()
        }
    }

    deinit {
        session.invalidateAndCancel()
    }
}

/// One lazy AmiVoice WebSocket session per take. The socket opens only on the first
/// non-empty admitted PCM chunk, serializes `s`, `p`, and `e` writes through one queue,
/// and completes strictly upon the server's `"e"` ack with zero heuristic dwell.
@MainActor public final class AmiVoiceWebSocketConnection {
    public nonisolated static let defaultSetupTimeout: Duration = .seconds(10)
    public nonisolated static let defaultSendTimeout: Duration = .seconds(10)
    public nonisolated static let defaultFinalizationTimeout: Duration = .seconds(FinalizationPolicy.maximumWaitSeconds)

    public var onUpdate: ((RecognitionPreview) -> Void)?
    public var onError: ((ConnectionError) -> Void)?

    public let engine: AmiVoiceEngine
    public private(set) var assembler: AmiVoiceTranscriptAssembler
    public private(set) var sentAudioBytes = 0
    public private(set) var sentAudioChunks = 0
    public private(set) var didOpenSocket = false
    public var speechDurationMS: Int { assembler.speechDurationMS }
    public var speechDurationSeconds: Double { assembler.speechDurationSeconds }

    private let apiKey: String
    private let profileWords: [String]
    private let profileId: String?
    private let resultUpdatedIntervalMS: Int?
    private let setupTimeout: Duration
    private let sendTimeout: Duration
    private let finalizationTimeout: Duration
    private let makeSocket: (URLRequest) -> any AmiVoiceSocket

    private var socket: (any AmiVoiceSocket)?
    private var receiver: Task<Void, Never>?
    private var openTask: Task<Void, Error>?
    private var sendTail: Task<Void, Error>?
    private var endTask: Task<Void, Error>?
    private var endAckWaiters: [CheckedContinuation<Void, Never>] = []

    private var openStarted = false
    private var ready = false
    private var closedByClient = false
    private var inputEnded = false
    private var failure: ConnectionError?
    private var completedText: String?
    private var endSendBeganInstant: ContinuousClock.Instant?
    private var endWriteCompletedInstant: ContinuousClock.Instant?
    private var receivedFrames = 0

    public init(
        apiKey: String,
        engine: AmiVoiceEngine = .e2eJapaneseGeneral,
        vocabulary: [String] = [],
        profileId: String? = nil,
        resultUpdatedIntervalMS: Int? = nil,
        finalBudget: TranscriptAssembler.FinalBudget? = .dictation,
        setupTimeout: Duration = AmiVoiceWebSocketConnection.defaultSetupTimeout,
        sendTimeout: Duration = AmiVoiceWebSocketConnection.defaultSendTimeout,
        finalizationTimeout: Duration = AmiVoiceWebSocketConnection.defaultFinalizationTimeout,
        makeSocket: @escaping (URLRequest) -> any AmiVoiceSocket = { AmiVoiceWebSocketConnection.makeDefaultSocket(for: $0) }
    ) {
        self.apiKey = apiKey
        self.engine = engine
        self.profileWords = vocabulary
        self.profileId = profileId
        self.resultUpdatedIntervalMS = resultUpdatedIntervalMS
        self.assembler = AmiVoiceTranscriptAssembler(budget: finalBudget)
        self.setupTimeout = setupTimeout
        self.sendTimeout = sendTimeout
        self.finalizationTimeout = finalizationTimeout
        self.makeSocket = makeSocket
    }

    public nonisolated static func makeEphemeralSession(
        delegate: URLSessionTaskDelegate = AmiVoiceNoRedirectDelegate()
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public nonisolated static func makeDefaultSocket(for request: URLRequest) -> any AmiVoiceSocket {
        EphemeralAmiVoiceSocket(request: request)
    }

    public nonisolated static func makeWebSocketRequest(apiKey: String) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw ConnectionError.setup(AmiVoiceProviderError(resultCode: "-").localizedDescription)
        }
        guard let url = URL(string: AmiVoiceWire.nologWebSocketEndpoint),
              url.absoluteString == AmiVoiceWire.nologWebSocketEndpoint else {
            throw ConnectionError.badURL
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    public nonisolated static func diagnosticFailure(_ error: Error) -> String {
        if let provider = error as? AmiVoiceProviderError { return provider.diagnostic }
        if let connectionError = error as? ConnectionError { return connectionError.diagnostic }
        if let wireError = error as? AmiVoiceWireError {
            switch wireError {
            case .emptyFrame: return "kind=wire code=empty_frame"
            case .malformedFrame: return "kind=wire code=malformed_frame"
            case .invalidJSON: return "kind=wire code=invalid_json"
            }
        }
        return "kind=connection code=\((error as NSError).code)"
    }

    public nonisolated static func connectionFailureReason(for error: Error) -> String {
        if let provider = error as? AmiVoiceProviderError { return provider.localizedDescription }
        if let wire = error as? AmiVoiceWireError { return wire.localizedDescription }
        if let connectionError = error as? ConnectionError {
            if case .setup = connectionError {
                return UserFacingErrorMessage.message(for: error, operation: "AmiVoiceへの接続")
            }
            if let description = connectionError.errorDescription { return description }
        }
        return UserFacingErrorMessage.message(for: error, operation: "AmiVoiceへの接続")
    }

    public func sendAudio(_ data: Data) async throws {
        try checkCanContinue()
        guard !inputEnded else { throw ConnectionError.disconnected }
        guard !data.isEmpty else { return }
        if !openStarted {
            let request = try Self.makeWebSocketRequest(apiKey: apiKey)
            let startCommand = AmiVoiceWire.startCommand(
                engine: engine,
                resultUpdatedIntervalMS: resultUpdatedIntervalMS,
                profileWords: profileWords,
                profileId: profileId
            )
            openStarted = true
            openTask = enqueueOpen(request: request, startCommand: startCommand)
        }
        let slices = Self.audioSlices(for: data)
        var lastTask: Task<Void, Error>?
        for (index, slice) in slices.enumerated() {
            let chunkCount = index == slices.count - 1 ? 1 : 0
            lastTask = enqueueWrite(
                .data(AmiVoiceWire.audioPacket(slice)),
                audioByteCount: slice.count,
                audioChunkCount: chunkCount,
                ending: false
            )
        }
        guard let task = lastTask else { return }
        try await awaitSend(task)
    }

    public func endAudioAndAwaitFinal() async throws -> String {
        if let completedText { return completedText }
        defer { if completedText == nil { cancel() } }
        try checkCanContinue()
        guard openStarted else {
            inputEnded = true
            throw ConnectionError.noSpeech
        }
        inputEnded = true
        let task: Task<Void, Error>
        if let existing = endTask {
            task = existing
        } else {
            let queued = enqueueWrite(.string(AmiVoiceWire.endCommand), audioByteCount: 0, ending: true)
            endTask = queued
            task = queued
        }
        try await awaitSend(task)
        let deadline = (endSendBeganInstant ?? ContinuousClock.now).advanced(by: finalizationTimeout)
        if !assembler.endAcknowledged && failure == nil && !assembler.exceededFinalBudget && !closedByClient {
            await waitForEndAck(until: deadline)
        }
        try Task.checkCancellation()
        if let completedText { return completedText }
        try checkConnectionState()
        guard assembler.endAcknowledged else {
            EngineDiagnostics.record("amivoice finalization timeout; finalCount=\(assembler.finalCount) speechMS=\(assembler.speechDurationMS) sentChunks=\(sentAudioChunks)")
            throw ConnectionError.finalizationTimeout
        }
        switch assembler.completion {
        case .text(let text):
            completedText = text
            let waited = (endWriteCompletedInstant ?? endSendBeganInstant ?? ContinuousClock.now).duration(to: .now)
            EngineDiagnostics.record("amivoice finalized; waitSeconds=\(waited) finalCount=\(assembler.finalCount) speechMS=\(assembler.speechDurationMS)")
            cancel()
            return text
        case .noSpeech:
            throw ConnectionError.noSpeech
        case .budgetExceeded:
            throw ConnectionError.finalBudgetExceeded
        case .failed(let providerError):
            throw ConnectionError.provider(providerError)
        }
    }

    public func cancel() {
        closedByClient = true
        ready = false
        let activeSocket = socket
        socket = nil
        activeSocket?.cancel(with: .normalClosure, reason: nil)
        receiver?.cancel()
        openTask?.cancel()
        sendTail?.cancel()
        endTask?.cancel()
        receiver = nil
        openTask = nil
        sendTail = nil
        endTask = nil
        onUpdate = nil
        onError = nil
        signalEndAckWaiters()
    }

    private func checkConnectionState() throws {
        if assembler.exceededFinalBudget { throw ConnectionError.finalBudgetExceeded }
        if let failure { throw failure }
        guard !closedByClient else { throw ConnectionError.disconnected }
    }

    private func checkCanContinue() throws {
        try Task.checkCancellation()
        try checkConnectionState()
    }

    private func checkOpenForWrite() throws {
        try checkConnectionState()
        if Task.isCancelled {
            cancel()
            throw CancellationError()
        }
        guard ready, socket != nil else { throw ConnectionError.disconnected }
    }

    private func enqueueOpen(request: URLRequest, startCommand: String) -> Task<Void, Error> {
        let predecessor = sendTail
        let timeout = setupTimeout
        let task = Task { [weak self] in
            do {
                try await predecessor?.value
            } catch {
                if let self {
                    try self.checkConnectionState()
                }
                throw error
            }
            guard let self else { throw ConnectionError.disconnected }
            try self.checkConnectionState()
            if Task.isCancelled {
                self.cancel()
                throw CancellationError()
            }
            let connectionBeganAt = Date()
            let ws = self.makeSocket(request)
            self.socket = ws
            self.didOpenSocket = true
            ws.resume()
            let setupWatchdog = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self,
                      !Task.isCancelled,
                      !self.ready,
                      !self.closedByClient,
                      self.failure == nil else { return }
                self.recordTerminalFailure(.setupTimeout, closeSocket: ws)
            }
            defer { setupWatchdog.cancel() }
            do {
                try await withTaskCancellationHandler {
                    try await ws.send(.string(startCommand))
                    var startAcknowledged = false
                    while !startAcknowledged {
                        try self.checkConnectionState()
                        try Task.checkCancellation()
                        let message = try await ws.receive()
                        try self.checkConnectionState()
                        guard !Task.isCancelled else { throw CancellationError() }
                        self.receivedFrames += 1
                        let frame = try Self.decode(message)
                        switch frame {
                        case .startAck(nil):
                            startAcknowledged = true
                        case .startAck(.some(let providerError)):
                            self.assembler.apply(frame)
                            throw providerError
                        case .provideError(let providerError), .endAck(.some(let providerError)):
                            self.assembler.apply(frame)
                            throw providerError
                        case .serverInfo, .speechStart, .speechEnd, .recognitionStarted, .interim, .utteranceFinal, .endAck(nil):
                            break
                        }
                    }
                    try self.checkConnectionState()
                    try Task.checkCancellation()
                    guard self.socket != nil else { throw ConnectionError.disconnected }
                    self.ready = true
                    self.receiver = Task { [weak self] in await self?.receiveLoop() }
                } onCancel: {
                    ws.cancel(with: .goingAway, reason: nil)
                }
            } catch {
                EngineDiagnostics.record("amivoice connection failed; \(Self.diagnosticFailure(self.failure ?? error))")
                try self.checkConnectionState()
                if Task.isCancelled || error is CancellationError {
                    self.cancel()
                    throw CancellationError()
                }
                let resolved = Self.mapSetupError(error)
                self.recordTerminalFailure(resolved, closeSocket: ws)
                throw resolved
            }
            EngineDiagnostics.record("amivoice connected; engine=\(self.engine.rawValue) setupSeconds=\(String(format: "%.3f", Date().timeIntervalSince(connectionBeganAt)))")
        }
        sendTail = task
        return task
    }

    /// Queue before awaiting: MainActor methods may reenter during network waits.
    private func enqueueWrite(
        _ message: URLSessionWebSocketTask.Message,
        audioByteCount: Int,
        audioChunkCount: Int = 0,
        ending: Bool
    ) -> Task<Void, Error> {
        let predecessor = sendTail
        let timeout = sendTimeout
        let task = Task { [weak self] in
            do {
                try await predecessor?.value
            } catch {
                if let self {
                    try self.checkConnectionState()
                }
                throw error
            }
            guard let self else { throw ConnectionError.disconnected }
            try self.checkOpenForWrite()
            guard let ws = self.socket else { throw ConnectionError.disconnected }
            let watchdog = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self,
                      !Task.isCancelled,
                      !self.closedByClient,
                      self.failure == nil,
                      !self.assembler.exceededFinalBudget,
                      self.completedText == nil else { return }
                EngineDiagnostics.record("amivoice send failed; \(ConnectionError.sendTimeout.diagnostic)")
                self.recordTerminalFailure(.sendTimeout, closeSocket: ws)
            }
            defer { watchdog.cancel() }
            if ending {
                self.endSendBeganInstant = ContinuousClock.now
            }
            do {
                try await ws.send(message)
                if audioByteCount > 0 {
                    self.sentAudioBytes += audioByteCount
                }
                if audioChunkCount > 0 {
                    self.sentAudioChunks += audioChunkCount
                }
                if ending {
                    self.endWriteCompletedInstant = ContinuousClock.now
                    EngineDiagnostics.record("amivoice endAudio; audioBytes=\(self.sentAudioBytes) audioChunks=\(self.sentAudioChunks) speechMS=\(self.assembler.speechDurationMS) finalCount=\(self.assembler.finalCount) receivedFrames=\(self.receivedFrames)")
                }
                try self.checkConnectionState()
                try Task.checkCancellation()
            } catch {
                try self.checkConnectionState()
                if Task.isCancelled || error is CancellationError {
                    self.cancel()
                    throw CancellationError()
                }
                EngineDiagnostics.record("amivoice send failed; \(Self.diagnosticFailure(error))")
                let mapped: ConnectionError
                if let connectionError = error as? ConnectionError {
                    mapped = connectionError
                } else {
                    mapped = .receiveFailed(UserFacingErrorMessage.message(for: error, operation: "AmiVoiceへの送信"))
                }
                self.recordTerminalFailure(mapped, closeSocket: ws)
                throw mapped
            }
        }
        sendTail = task
        return task
    }

    private func awaitSend(_ task: Task<Void, Error>) async throws {
        let ws = socket
        let open = openTask
        try await withTaskCancellationHandler {
            do {
                try await task.value
            } catch {
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
            if completedText == nil {
                try checkCanContinue()
            }
        } onCancel: {
            task.cancel()
            open?.cancel()
            ws?.cancel(with: .goingAway, reason: nil)
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    private func receiveLoop() async {
        guard let ws = socket else { return }
        while !Task.isCancelled && !closedByClient && failure == nil && !assembler.endAcknowledged {
            do {
                let message = try await ws.receive()
                guard !closedByClient, !Task.isCancelled else { return }
                receivedFrames += 1
                let frame = try Self.decode(message)
                handle(frame)
            } catch {
                if !closedByClient && !Task.isCancelled && failure == nil && !assembler.endAcknowledged {
                    EngineDiagnostics.record("amivoice receive failed; \(Self.diagnosticFailure(error))")
                    let reason: String
                    if let wire = error as? AmiVoiceWireError {
                        reason = wire.localizedDescription
                    } else {
                        reason = UserFacingErrorMessage.message(for: error, operation: "AmiVoiceの受信")
                    }
                    recordTerminalFailure(.receiveFailed(reason), closeSocket: ws)
                }
                return
            }
        }
    }

    private func handle(_ frame: AmiVoiceServerFrame) {
        guard !closedByClient, completedText == nil else { return }
        let previousPreview = assembler.preview
        let hadFatalError = assembler.fatalError != nil
        assembler.apply(frame)

        if assembler.exceededFinalBudget {
            EngineDiagnostics.record("amivoice final budget exceeded; finalCount=\(assembler.finalCount)")
            onError?(.finalBudgetExceeded)
            cancel()
            return
        }

        if !hadFatalError, let providerError = assembler.fatalError {
            EngineDiagnostics.record("amivoice API error; \(providerError.diagnostic)")
            recordTerminalFailure(.provider(providerError), closeSocket: socket)
            return
        }

        switch frame {
        case .interim, .utteranceFinal:
            if assembler.preview != previousPreview {
                onUpdate?(assembler.preview)
            }
        case .endAck(nil):
            signalEndAckWaiters()
        case .speechStart, .speechEnd, .recognitionStarted, .serverInfo, .startAck, .provideError, .endAck:
            break
        }
    }

    private func recordTerminalFailure(_ error: ConnectionError, closeSocket ws: (any AmiVoiceSocket)?) {
        if failure == nil {
            failure = error
            onError?(error)
        }
        ready = false
        let activeSocket = ws ?? socket
        socket = nil
        activeSocket?.cancel(with: .goingAway, reason: nil)
        receiver?.cancel()
        receiver = nil
        onUpdate = nil
        onError = nil
        signalEndAckWaiters()
    }

    private func waitForEndAck(until deadline: ContinuousClock.Instant) async {
        let timeoutTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            self?.signalEndAckWaiters()
        }
        defer { timeoutTask.cancel() }
        while !assembler.endAcknowledged,
              !assembler.exceededFinalBudget,
              failure == nil,
              !closedByClient,
              !Task.isCancelled,
              ContinuousClock.now < deadline {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if assembler.endAcknowledged || assembler.exceededFinalBudget || failure != nil || closedByClient || Task.isCancelled || ContinuousClock.now >= deadline {
                        continuation.resume()
                        return
                    }
                    endAckWaiters.append(continuation)
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.signalEndAckWaiters()
                }
            }
        }
    }

    private func signalEndAckWaiters() {
        guard !endAckWaiters.isEmpty else { return }
        let waiters = endAckWaiters
        endAckWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private nonisolated static func mapSetupError(_ error: Error) -> ConnectionError {
        if let provider = error as? AmiVoiceProviderError { return .provider(provider) }
        if let connectionError = error as? ConnectionError { return connectionError }
        return .setup(connectionFailureReason(for: error))
    }

    private nonisolated static func audioSlices(for data: Data) -> [Data] {
        guard data.count > AmiVoiceWire.maximumAudioPacketBytes else { return [data] }
        var slices: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + AmiVoiceWire.maximumAudioPacketBytes, data.endIndex)
            slices.append(Data(data[offset..<end]))
            offset = end
        }
        return slices
    }

    private nonisolated static func decode(_ message: URLSessionWebSocketTask.Message) throws -> AmiVoiceServerFrame {
        switch message {
        case .string(let raw):
            return try AmiVoiceWire.decode(raw)
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw AmiVoiceWireError.malformedFrame
            }
            return try AmiVoiceWire.decode(text)
        @unknown default:
            throw AmiVoiceWireError.malformedFrame
        }
    }

    public enum ConnectionError: Error, LocalizedError, Equatable, Sendable {
        case badURL
        case setup(String)
        case setupTimeout
        case sendTimeout
        case provider(AmiVoiceProviderError)
        case receiveFailed(String)
        case disconnected
        case noSpeech
        case finalizationTimeout
        case finalBudgetExceeded

        public var diagnostic: String {
            switch self {
            case .badURL: return "kind=connection code=bad_url"
            case .setup: return "kind=connection code=setup"
            case .setupTimeout: return "kind=timeout code=setup_timeout"
            case .sendTimeout: return "kind=timeout code=send_timeout"
            case .provider(let error): return error.diagnostic
            case .receiveFailed: return "kind=connection code=receive_failed"
            case .disconnected: return "kind=connection code=disconnected"
            case .noSpeech: return "kind=noSpeech code=no_speech"
            case .finalizationTimeout: return "kind=timeout code=finalization_timeout"
            case .finalBudgetExceeded: return "kind=budget code=final_budget_exceeded"
            }
        }

        public var errorDescription: String? {
            switch self {
            case .badURL:
                return "AmiVoice接続先URLが不正です"
            case .setup(let reason):
                return "AmiVoice API: \(reason)"
            case .setupTimeout:
                return "AmiVoice接続準備がタイムアウトしました"
            case .sendTimeout:
                return "AmiVoiceへの音声送信がタイムアウトしました"
            case .provider(let error):
                return error.errorDescription
            case .receiveFailed(let reason):
                return reason
            case .disconnected:
                return "AmiVoice接続がありません"
            case .noSpeech:
                return "AmiVoiceから認識できる音声が検出されませんでした"
            case .finalizationTimeout:
                return "AmiVoiceから8秒以内に確定結果を取得できませんでした。取得済みの文字は履歴に残します"
            case .finalBudgetExceeded:
                return "認識結果の上限に達したため中断しました。取得済みの文字は途中結果として確認できます"
            }
        }
    }
}
#endif
