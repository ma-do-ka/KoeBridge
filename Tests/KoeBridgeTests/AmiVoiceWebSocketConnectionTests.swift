#if os(macOS)
import Foundation
import Testing
import KoeBridgeCore
@testable import KoeBridgeEngines
@testable import KoeBridge

// Parallel CI can starve MainActor continuation delivery long beyond the nominal
// 5 ms poll interval; CI observed 18.6 s of such delay. These waits observe
// monotonic in-process progress (enqueued writes, socket state), so the budget is
// sized at a 60 s equivalent (12,000 x 5 ms) to stay above that evidence while
// matching the 60 s setup bound. Assertions on the conditions remain exact.
private let amiVoiceSchedulingWaitIterations = 12_000

final class ScriptedAmiVoiceSocket: AmiVoiceSocket, @unchecked Sendable {
    private let lock = NSLock()
    let request: URLRequest
    private var _state: URLSessionTask.State = .suspended
    private var _resumed = false
    private var _cancelled = false
    private var _sentMessages: [URLSessionWebSocketTask.Message] = []
    private var _closeCodes: [URLSessionWebSocketTask.CloseCode] = []
    private var pendingSends: [CheckedContinuation<Void, Error>] = []
    private let frames = AsyncStream<Result<URLSessionWebSocketTask.Message, Error>>.makeStream()
    private let blockSendPredicate: (@Sendable (URLSessionWebSocketTask.Message) -> Bool)?
    private let onSend: (@Sendable (URLSessionWebSocketTask.Message, ScriptedAmiVoiceSocket) -> Void)?

    init(
        request: URLRequest,
        blockSendPredicate: (@Sendable (URLSessionWebSocketTask.Message) -> Bool)? = nil,
        onSend: (@Sendable (URLSessionWebSocketTask.Message, ScriptedAmiVoiceSocket) -> Void)? = nil
    ) {
        self.request = request
        self.blockSendPredicate = blockSendPredicate
        self.onSend = onSend
    }

    var state: URLSessionTask.State {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    var resumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _resumed
    }

    var sentMessages: [URLSessionWebSocketTask.Message] {
        lock.lock()
        defer { lock.unlock() }
        return _sentMessages
    }

    var closeCodes: [URLSessionWebSocketTask.CloseCode] {
        lock.lock()
        defer { lock.unlock() }
        return _closeCodes
    }

    var pendingSendCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingSends.count
    }

    func resume() {
        lock.lock()
        _resumed = true
        if !_cancelled { _state = .running }
        lock.unlock()
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        var iterator = frames.stream.makeAsyncIterator()
        guard let next = await iterator.next() else { throw CancellationError() }
        return try next.get()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.lock()
        if _cancelled {
            lock.unlock()
            throw CancellationError()
        }
        _sentMessages.append(message)
        let shouldBlock = blockSendPredicate?(message) ?? false
        lock.unlock()

        onSend?(message, self)

        if shouldBlock {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if _cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingSends.append(continuation)
                lock.unlock()
            }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        _cancelled = true
        _state = .completed
        _closeCodes.append(closeCode)
        let waiting = pendingSends
        pendingSends.removeAll()
        lock.unlock()
        for continuation in waiting {
            continuation.resume(throwing: CancellationError())
        }
        frames.continuation.finish()
    }

    func feed(_ text: String) {
        frames.continuation.yield(.success(.string(text)))
    }

    func feedData(_ data: Data) {
        frames.continuation.yield(.success(.data(data)))
    }

    func feedError(_ error: Error) {
        frames.continuation.yield(.failure(error))
    }
}

@MainActor struct AmiVoiceWebSocketConnectionTests {
    private func waitForCondition(_ message: String, until predicate: () -> Bool) async throws {
        for _ in 0..<amiVoiceSchedulingWaitIterations {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record(Comment(rawValue: message))
        throw CancellationError()
    }

    @Test func lazyOpenDefersSocketUntilFirstNonEmptyPCM() async throws {
        var sockets: [ScriptedAmiVoiceSocket] = []
        let connection = AmiVoiceWebSocketConnection(
            apiKey: "fixture-amivoice-key",
            engine: .e2eJapaneseGeneral,
            vocabulary: ["KoeBridge"]
        ) { request in
            let socket = ScriptedAmiVoiceSocket(request: request) { message, ws in
                guard case .string(let text) = message else { return }
                if text.hasPrefix("s ") {
                    ws.feed("s")
                } else if text == "e" {
                    ws.feed(#"A {"text":"こんにちは","code":""}"#)
                    ws.feed("e")
                }
            }
            sockets.append(socket)
            return socket
        }

        // Construction and empty chunks must never open a WebSocket.
        #expect(sockets.isEmpty)
        #expect(!connection.didOpenSocket)
        try await connection.sendAudio(Data())
        #expect(sockets.isEmpty)
        #expect(!connection.didOpenSocket)

        let chunk1 = Data([0x01, 0x02, 0x03, 0x04])
        let chunk2 = Data([0x05, 0x06])
        try await connection.sendAudio(chunk1)
        #expect(sockets.count == 1)
        #expect(connection.didOpenSocket)
        #expect(connection.sentAudioBytes == 4)
        #expect(connection.sentAudioChunks == 1)

        try await connection.sendAudio(chunk2)
        #expect(sockets.count == 1)
        #expect(connection.sentAudioBytes == 6)
        #expect(connection.sentAudioChunks == 2)

        let text = try await connection.endAudioAndAwaitFinal()
        #expect(text == "こんにちは")

        let socket = try #require(sockets.first)
        #expect(socket.resumed)
        #expect(socket.closeCodes.first == .normalClosure)

        let sent = socket.sentMessages
        #expect(sent.count == 4)
        if case .string(let startCmd) = sent[0] {
            #expect(startCmd == #"s LSB16K -a2-ja-general resultUpdatedInterval=300 profileWords="KoeBridge""#)
            #expect(!startCmd.contains("authorization="))
            #expect(!startCmd.contains("fixture-amivoice-key"))
        } else {
            Issue.record("Expected text s-command as first frame")
        }
        if case .data(let frame1) = sent[1] {
            #expect(frame1 == Data([0x70, 0x01, 0x02, 0x03, 0x04]))
        } else {
            Issue.record("Expected binary p-packet for chunk 1")
        }
        if case .data(let frame2) = sent[2] {
            #expect(frame2 == Data([0x70, 0x05, 0x06]))
        } else {
            Issue.record("Expected binary p-packet for chunk 2")
        }
        if case .string(let endCmd) = sent[3] {
            #expect(endCmd == "e")
        } else {
            Issue.record("Expected text e-command as final frame")
        }
    }

    @Test func endAudioWithoutNonEmptyPCMNeverOpensSocketAndFailsClosed() async {
        var socketOpens = 0
        let connection = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            socketOpens += 1
            return ScriptedAmiVoiceSocket(request: request)
        }
        do {
            try await connection.sendAudio(Data())
            _ = try await connection.endAudioAndAwaitFinal()
            Issue.record("Expected noSpeech when no non-empty PCM was sent")
        } catch AmiVoiceWebSocketConnection.ConnectionError.noSpeech {
            // Expected fail-closed result.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(socketOpens == 0)
        #expect(!connection.didOpenSocket)
        #expect(connection.sentAudioBytes == 0)
    }

    @Test func requestUsesNologTrailingSlashBearerHeaderAndNoRedirectDelegate() async throws {
        let request = try AmiVoiceWebSocketConnection.makeWebSocketRequest(apiKey: "  fixture-key-123 \n")
        #expect(request.url?.absoluteString == "wss://acp-api.amivoice.com/v1/nolog/")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key-123")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)

        // Blank API key must fail before creating any socket.
        var opens = 0
        let blankKeyConnection = AmiVoiceWebSocketConnection(apiKey: "   \n") { req in
            opens += 1
            return ScriptedAmiVoiceSocket(request: req)
        }
        do {
            try await blankKeyConnection.sendAudio(Data([0x01, 0x02]))
            Issue.record("Expected blank key to be rejected")
        } catch AmiVoiceWebSocketConnection.ConnectionError.setup {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(opens == 0)

        // Verify ephemeral URLSession configuration and no-redirect security delegate.
        let session = AmiVoiceWebSocketConnection.makeEphemeralSession()
        defer { session.invalidateAndCancel() }
        #expect(session.delegate is AmiVoiceNoRedirectDelegate)
        #expect(session.configuration.urlCache == nil)
        #expect(session.configuration.httpCookieStorage == nil)
        #expect(session.configuration.httpShouldSetCookies == false)
        #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)

        let noRedirect = try #require(session.delegate as? AmiVoiceNoRedirectDelegate)
        let originURL = try #require(URL(string: "https://acp-api.amivoice.com/v1/nolog/"))
        let redirectURL = try #require(URL(string: "https://attacker.example/steal"))
        let response = try #require(HTTPURLResponse(
            url: originURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectURL.absoluteString]
        ))
        var redirectRequest = URLRequest(url: redirectURL)
        redirectRequest.setValue("Bearer fixture-key-123", forHTTPHeaderField: "Authorization")
        let dummyTask = session.dataTask(with: originURL)
        let forwarded: URLRequest? = await withCheckedContinuation { continuation in
            noRedirect.urlSession(
                session,
                task: dummyTask,
                willPerformHTTPRedirection: response,
                newRequest: redirectRequest
            ) { next in
                continuation.resume(returning: next)
            }
        }
        #expect(forwarded == nil)
    }

    @Test func interleavedSpeechEventsAndProgressivePreviewUpdates() async throws {
        var previews: [RecognitionPreview] = []
        var capturedSocket: ScriptedAmiVoiceSocket?
        let connection = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            let socket = ScriptedAmiVoiceSocket(request: request) { message, ws in
                guard case .string(let text) = message else { return }
                if text.hasPrefix("s ") {
                    ws.feed("G server-info-before-start-ack")
                    ws.feed("s")
                } else if text == "e" {
                    ws.feed(#"A {"text":"次の発話です。","code":"","utteranceid":"u2"}"#)
                    ws.feed("e")
                }
            }
            capturedSocket = socket
            return socket
        }
        connection.onUpdate = { previews.append($0) }

        try await connection.sendAudio(Data(repeating: 0x11, count: 1_600))
        let socket = try #require(capturedSocket)
        socket.feed("G info")
        socket.feed("S 120")
        socket.feed("C")
        socket.feed(#"U {"text":"これは..."}"#)
        socket.feed(#"U {"text":"..."}"#) // Empty after ellipsis stripping -> ignored.
        socket.feed("E 1120")
        // Official AmiVoice trace: S(k+1) can arrive before A(k).
        socket.feed("S 1300")
        socket.feed(#"A {"text":"これはテストです。","code":"","utteranceid":"u1"}"#)
        socket.feed(#"U {"text":"次の発話..."}"#)
        socket.feed("E 2550")

        let final = try await connection.endAudioAndAwaitFinal()
        #expect(final == "これはテストです。次の発話です。")
        #expect(connection.speechDurationMS == 2_250)
        #expect(connection.speechDurationSeconds == 2.25)
        #expect(connection.assembler.finalCount == 2)
        #expect(previews.contains(RecognitionPreview(finalizedPrefix: "", volatileTail: "これは")))
        #expect(previews.contains(RecognitionPreview(finalizedPrefix: "これはテストです。", volatileTail: "")))
        #expect(previews.contains(RecognitionPreview(finalizedPrefix: "これはテストです。", volatileTail: "次の発話")))
        #expect(previews.last == RecognitionPreview(finalizedPrefix: "これはテストです。次の発話です。", volatileTail: ""))
    }

    @Test func multiUtteranceAssemblyAcross15SecondSplitAndTrailingNoSpeechSegment() async throws {
        var capturedSocket: ScriptedAmiVoiceSocket?
        let connection = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            let socket = ScriptedAmiVoiceSocket(request: request) { message, ws in
                guard case .string(let text) = message else { return }
                if text.hasPrefix("s ") {
                    ws.feed("s")
                } else if text == "e" {
                    // Trailing noise-only segment (code "o") must not discard earlier utterances.
                    ws.feed("S 22100")
                    ws.feed("E 22400")
                    ws.feed(#"A {"text":"","code":"o"}"#)
                    ws.feed("e")
                }
            }
            capturedSocket = socket
            return socket
        }

        try await connection.sendAudio(Data(repeating: 0x22, count: 1_600))
        let socket = try #require(capturedSocket)
        // Simulate >15 s continuous speech split by AmiVoice into multiple utterances.
        socket.feed("S 0")
        socket.feed("E 14800")
        socket.feed(#"A {"text":"最初の十五秒のテキスト","code":""}"#)
        socket.feed("S 14800")
        socket.feed("E 19500")
        socket.feed(#"A {"text":"Swift","code":""}"#)
        socket.feed("S 19500")
        socket.feed("E 22000")
        socket.feed(#"A {"text":"6","code":""}"#)

        let final = try await connection.endAudioAndAwaitFinal()
        #expect(final == "最初の十五秒のテキストSwift 6")
        #expect(connection.assembler.finalCount == 3)
        #expect(connection.assembler.rejectedSegmentCount == 1)
        #expect(connection.speechDurationMS == 22_300)
    }

    @Test func allSegmentsRejectedAsNoSpeechFailsClosed() async throws {
        let connection = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            ScriptedAmiVoiceSocket(request: request) { message, ws in
                guard case .string(let text) = message else { return }
                if text.hasPrefix("s ") {
                    ws.feed("s")
                } else if text == "e" {
                    ws.feed("S 0")
                    ws.feed("E 400")
                    ws.feed(#"A {"text":"","code":"o"}"#)
                    ws.feed("e")
                }
            }
        }
        try await connection.sendAudio(Data([0x01, 0x02]))
        do {
            _ = try await connection.endAudioAndAwaitFinal()
            Issue.record("Expected noSpeech when all segments returned code=o")
        } catch AmiVoiceWebSocketConnection.ConnectionError.noSpeech {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(connection.assembler.rejectedSegmentCount == 1)
    }

    @Test func strictEndAckFinalizationCompletesImmediatelyAndTimesOutFailClosedWithoutAck() async throws {
        // 1. Immediate completion upon "e" ack with zero heuristic dwell.
        let fastConnection = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            ScriptedAmiVoiceSocket(request: request) { message, ws in
                guard case .string(let text) = message else { return }
                if text.hasPrefix("s ") {
                    ws.feed("s")
                } else if text == "e" {
                    ws.feed(#"A {"text":"即時確定","code":""}"#)
                    ws.feed("e")
                }
            }
        }
        try await fastConnection.sendAudio(Data([0x01, 0x02]))
        let started = ContinuousClock.now
        let immediate = try await fastConnection.endAudioAndAwaitFinal()
        let elapsed = started.duration(to: .now)
        #expect(immediate == "即時確定")
        // Property under test: ack-driven completion with zero heuristic dwell.
        // The 2 s ceiling catches dwell/poll regressions (well below the 8 s default timeout)
        // without promising tight MainActor scheduler latency under parallel CI load.
        #expect(elapsed < .seconds(2))

        // 2. Missing "e" ack must fail closed even when an A utterance already arrived.
        var timeoutSocket: ScriptedAmiVoiceSocket?
        let stalledConnection = AmiVoiceWebSocketConnection(
            apiKey: "fixture-amivoice-key",
            finalizationTimeout: .milliseconds(80)
        ) { request in
            let socket = ScriptedAmiVoiceSocket(request: request) { message, ws in
                guard case .string(let text) = message else { return }
                if text.hasPrefix("s ") {
                    ws.feed("s")
                } else if text == "e" {
                    ws.feed(#"A {"text":"未確定の途中テキスト","code":""}"#)
                    // Intentionally omit "e" ack.
                }
            }
            timeoutSocket = socket
            return socket
        }
        try await stalledConnection.sendAudio(Data([0x01, 0x02]))
        do {
            _ = try await stalledConnection.endAudioAndAwaitFinal()
            Issue.record("Expected finalizationTimeout when e-ack never arrives")
        } catch AmiVoiceWebSocketConnection.ConnectionError.finalizationTimeout {
            // Expected fail-closed behavior.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(stalledConnection.assembler.recoveryText == "未確定の途中テキスト")
        #expect(timeoutSocket?.closeCodes.isEmpty == false)
    }

    @Test func defaultTimeoutsMatchDesignContract() {
        #expect(AmiVoiceWebSocketConnection.defaultSetupTimeout == .seconds(10))
        #expect(AmiVoiceWebSocketConnection.defaultSendTimeout == .seconds(10))
        #expect(AmiVoiceWebSocketConnection.defaultFinalizationTimeout == .seconds(FinalizationPolicy.maximumWaitSeconds))
    }

    @Test func setupErrorAndSetupTimeoutFailClosedWithoutLeakingRawServerText() async {
        let marker = "amivoice-secret-setup-leak-9f1a"
        var capturedError: AmiVoiceWebSocketConnection.ConnectionError?
        let rejected = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            ScriptedAmiVoiceSocket(request: request) { message, ws in
                if case .string(let text) = message, text.hasPrefix("s ") {
                    ws.feed("s authentication failed: \(marker)")
                }
            }
        }
        rejected.onError = { capturedError = $0 }
        do {
            try await rejected.sendAudio(Data([0x01, 0x02]))
            Issue.record("Expected provider auth failure on s-ack error")
        } catch AmiVoiceWebSocketConnection.ConnectionError.provider(let providerError) {
            #expect(providerError.kind == .authentication)
            let wrapped = AmiVoiceWebSocketConnection.ConnectionError.provider(providerError)
            for output in [
                providerError.localizedDescription,
                providerError.diagnostic,
                wrapped.localizedDescription,
                AmiVoiceWebSocketConnection.diagnosticFailure(wrapped),
                AmiVoiceWebSocketConnection.connectionFailureReason(for: providerError)
            ] {
                #expect(!output.contains(marker))
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(rejected.sentAudioBytes == 0)
        #expect(rejected.assembler.fatalError?.kind == .authentication)
        if case .provider(let err)? = capturedError {
            #expect(err.kind == .authentication)
        } else {
            Issue.record("Expected onError callback with provider error")
        }

        // Setup watchdog timeout when server never replies to "s".
        var timedOutSocket: ScriptedAmiVoiceSocket?
        let stalledSetup = AmiVoiceWebSocketConnection(
            apiKey: "fixture-amivoice-key",
            setupTimeout: .milliseconds(80)
        ) { request in
            let socket = ScriptedAmiVoiceSocket(request: request)
            timedOutSocket = socket
            return socket
        }
        do {
            try await stalledSetup.sendAudio(Data([0x01, 0x02]))
            Issue.record("Expected setupTimeout when server never sends s-ack")
        } catch AmiVoiceWebSocketConnection.ConnectionError.setupTimeout {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(stalledSetup.sentAudioBytes == 0)
        #expect(timedOutSocket?.closeCodes.contains(.goingAway) == true)
    }

    @Test func perFrameSendWatchdogFailsClosedWhenBinarySendStalls() async {
        var stalledSocket: ScriptedAmiVoiceSocket?
        let connection = AmiVoiceWebSocketConnection(
            apiKey: "fixture-amivoice-key",
            sendTimeout: .milliseconds(80)
        ) { request in
            let socket = ScriptedAmiVoiceSocket(
                request: request,
                blockSendPredicate: { message in
                    if case .data = message { return true }
                    return false
                },
                onSend: { message, ws in
                    if case .string(let text) = message, text.hasPrefix("s ") {
                        ws.feed("s")
                    }
                }
            )
            stalledSocket = socket
            return socket
        }

        do {
            try await connection.sendAudio(Data([0x01, 0x02, 0x03, 0x04]))
            Issue.record("Expected sendTimeout when p-frame write hangs")
        } catch AmiVoiceWebSocketConnection.ConnectionError.sendTimeout {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(connection.sentAudioBytes == 0)
        #expect(stalledSocket?.closeCodes.contains(.goingAway) == true)
    }

    @Test func providerErrorsInProvideUtteranceAndEndFramesFailClosed() async throws {
        // 1. Non-"o" utterance error after a valid earlier segment must fail closed (never auto-paste prefix).
        let marker = "amivoice-raw-provider-secret-4c2b"
        var capturedSocket: ScriptedAmiVoiceSocket?
        let utteranceErrorConn = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            let socket = ScriptedAmiVoiceSocket(request: request) { message, ws in
                if case .string(let text) = message, text.hasPrefix("s ") {
                    ws.feed("s")
                }
            }
            capturedSocket = socket
            return socket
        }
        try await utteranceErrorConn.sendAudio(Data([0x01, 0x02]))
        let socket = try #require(capturedSocket)
        socket.feed(#"A {"text":"前半の認識結果","code":""}"#)
        socket.feed(#"A {"text":"ignored","code":"b","message":"\#(marker)"}"#)
        try await waitForCondition("Utterance provider error was not applied") {
            utteranceErrorConn.assembler.fatalError != nil
        }
        #expect(utteranceErrorConn.assembler.committedText.isEmpty)
        #expect(utteranceErrorConn.assembler.recoveryText == "前半の認識結果")
        do {
            _ = try await utteranceErrorConn.endAudioAndAwaitFinal()
            Issue.record("Expected provider serverBusy error")
        } catch AmiVoiceWebSocketConnection.ConnectionError.provider(let err) {
            #expect(err.kind == .serverBusy)
            #expect(!err.localizedDescription.contains(marker))
            #expect(!err.diagnostic.contains(marker))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // 2. Mid-stream "p <error>" fails closed.
        var provideSocket: ScriptedAmiVoiceSocket?
        let provideErrorConn = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            let ws = ScriptedAmiVoiceSocket(request: request) { message, s in
                if case .string(let text) = message, text.hasPrefix("s ") { s.feed("s") }
            }
            provideSocket = ws
            return ws
        }
        try await provideErrorConn.sendAudio(Data([0x01, 0x02]))
        provideSocket?.feed("p can't feed audio data to recognizer server \(marker)")
        try await waitForCondition("Mid-stream provider error was not applied") {
            provideErrorConn.assembler.fatalError != nil
        }
        do {
            try await provideErrorConn.sendAudio(Data([0x03, 0x04]))
            Issue.record("Expected provider serverUnavailable error")
        } catch AmiVoiceWebSocketConnection.ConnectionError.provider(let err) {
            #expect(err.kind == .serverUnavailable)
            #expect(!err.localizedDescription.contains(marker))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // 3. "e <error>" ack fails closed.
        let endErrorConn = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            ScriptedAmiVoiceSocket(request: request) { message, ws in
                guard case .string(let text) = message else { return }
                if text.hasPrefix("s ") { ws.feed("s") }
                else if text == "e" { ws.feed("e timeout occurred \(marker)") }
            }
        }
        try await endErrorConn.sendAudio(Data([0x01, 0x02]))
        do {
            _ = try await endErrorConn.endAudioAndAwaitFinal()
            Issue.record("Expected provider timeout error on e-ack error")
        } catch AmiVoiceWebSocketConnection.ConnectionError.provider(let err) {
            #expect(err.kind == .timeout)
            #expect(!err.localizedDescription.contains(marker))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func overBudgetFinalsCloseSocketImmediatelyAndFailClosed() async throws {
        for budget in [
            TranscriptAssembler.FinalBudget(bytes: 4, identities: 100),
            TranscriptAssembler.FinalBudget(bytes: 1_000, identities: 1)
        ] {
            var capturedSocket: ScriptedAmiVoiceSocket?
            var errorCount = 0
            var lastError: AmiVoiceWebSocketConnection.ConnectionError?
            let connection = AmiVoiceWebSocketConnection(
                apiKey: "fixture-amivoice-key",
                finalBudget: budget
            ) { request in
                let socket = ScriptedAmiVoiceSocket(request: request) { message, ws in
                    if case .string(let text) = message, text.hasPrefix("s ") { ws.feed("s") }
                }
                capturedSocket = socket
                return socket
            }
            connection.onError = { err in
                errorCount += 1
                lastError = err
            }

            try await connection.sendAudio(Data([0x01, 0x02]))
            let socket = try #require(capturedSocket)
            socket.feed(#"A {"text":"ab","code":""}"#)
            socket.feed(#"A {"text":"cd","code":""}"#)
            socket.feed(#"A {"text":"ef","code":""}"#)

            try await waitForCondition("Final budget overrun was not applied") {
                connection.assembler.exceededFinalBudget
            }
            #expect(connection.assembler.exceededFinalBudget)
            #expect(connection.assembler.finalCount == 1)
            #expect(connection.assembler.committedText.isEmpty)
            #expect(connection.assembler.recoveryText == "ab")
            #expect(errorCount == 1)
            #expect(lastError == .finalBudgetExceeded)
            #expect(socket.closeCodes.first == .normalClosure)

            do {
                try await connection.sendAudio(Data([0x03, 0x04]))
                Issue.record("Expected sendAudio after budget exceeded to fail closed")
            } catch AmiVoiceWebSocketConnection.ConnectionError.finalBudgetExceeded {
                // Expected.
            } catch {
                Issue.record("Unexpected error from sendAudio: \(error)")
            }

            do {
                _ = try await connection.endAudioAndAwaitFinal()
                Issue.record("Expected endAudioAndAwaitFinal after budget exceeded to fail closed")
            } catch AmiVoiceWebSocketConnection.ConnectionError.finalBudgetExceeded {
                // Expected.
            } catch {
                Issue.record("Unexpected error from endAudioAndAwaitFinal: \(error)")
            }
        }
    }

    @Test func pipelinedWritesObserveFinalBudgetExceededOnBudgetOverrun() async throws {
        var capturedSocket: ScriptedAmiVoiceSocket?
        let blockedChunk = Data([0x10, 0x11])
        let blockedFrame = Data([0x70, 0x10, 0x11])
        var enqueuedWrites = 0
        let connection = AmiVoiceWebSocketConnection(
            apiKey: "fixture-amivoice-key",
            finalBudget: TranscriptAssembler.FinalBudget(bytes: 4, identities: 100)
        ) { request in
            let socket = ScriptedAmiVoiceSocket(
                request: request,
                blockSendPredicate: { message in
                    if case .data(let payload) = message {
                        return payload == blockedFrame
                    }
                    return false
                },
                onSend: { message, ws in
                    if case .string(let text) = message, text.hasPrefix("s ") {
                        ws.feed("s")
                    }
                }
            )
            capturedSocket = socket
            return socket
        }
        connection.onWriteEnqueued = { enqueuedWrites += 1 }

        try await connection.sendAudio(Data([0x01, 0x02]))
        let socket = try #require(capturedSocket)

        let send1 = Task { try await connection.sendAudio(blockedChunk) }
        try await waitForCondition("Blocked pipelined write did not reach the socket") {
            socket.pendingSendCount == 1
        }
        #expect(socket.pendingSendCount == 1)

        // Enqueue p2 fully before creating the end task: this reproduces origin/main's
        // structural guarantee that p2 precedes e in the serialized write queue, so e
        // cannot run first and make send2 fail with .disconnected.
        let send2 = Task { try await connection.sendAudio(Data([0x20, 0x21])) }
        try await waitForCondition("Pipelined send2 was not enqueued before end") {
            enqueuedWrites == 3
        }
        let end = Task { try await connection.endAudioAndAwaitFinal() }
        try await waitForCondition("Pipelined writes were not all enqueued") {
            enqueuedWrites == 4
        }

        socket.feed(#"A {"text":"ab","code":""}"#)
        socket.feed(#"A {"text":"cd","code":""}"#)
        socket.feed(#"A {"text":"ef","code":""}"#)

        do {
            try await send1.value
            Issue.record("Expected in-flight sendAudio to fail with finalBudgetExceeded")
        } catch AmiVoiceWebSocketConnection.ConnectionError.finalBudgetExceeded {
            // Expected.
        } catch {
            Issue.record("Unexpected error from in-flight sendAudio: \(error)")
        }

        do {
            try await send2.value
            Issue.record("Expected pipelined sendAudio to fail with finalBudgetExceeded")
        } catch AmiVoiceWebSocketConnection.ConnectionError.finalBudgetExceeded {
            // Expected.
        } catch {
            Issue.record("Unexpected error from pipelined sendAudio: \(error)")
        }

        do {
            _ = try await end.value
            Issue.record("Expected pipelined endAudioAndAwaitFinal to fail with finalBudgetExceeded")
        } catch AmiVoiceWebSocketConnection.ConnectionError.finalBudgetExceeded {
            // Expected.
        } catch {
            Issue.record("Unexpected error from pipelined endAudioAndAwaitFinal: \(error)")
        }
    }

    @Test func pipelinedWritesSurfaceTerminalFailuresAndPreserveCallerCancellation() async throws {
        let blockedChunk = Data([0x10, 0x11])
        let blockedFrame = Data([0x70, 0x10, 0x11])

        // 1. Provider error surfaces ConnectionError.provider to all pipelined callers even when endAudio's defer calls cancel().
        var providerSocket: ScriptedAmiVoiceSocket?
        var providerEnqueuedWrites = 0
        let providerConn = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            let socket = ScriptedAmiVoiceSocket(
                request: request,
                blockSendPredicate: { message in
                    if case .data(let payload) = message { return payload == blockedFrame }
                    return false
                },
                onSend: { message, ws in
                    if case .string(let text) = message, text.hasPrefix("s ") { ws.feed("s") }
                }
            )
            providerSocket = socket
            return socket
        }
        providerConn.onWriteEnqueued = { providerEnqueuedWrites += 1 }
        try await providerConn.sendAudio(Data([0x01, 0x02]))
        let socket0 = try #require(providerSocket)
        let sendP1 = Task { try await providerConn.sendAudio(blockedChunk) }
        try await waitForCondition("Blocked provider write did not reach the socket") {
            socket0.pendingSendCount == 1
        }
        #expect(socket0.pendingSendCount == 1)

        // Enqueue p2 fully before creating the end task so p2 precedes e in the queue.
        let sendP2 = Task { try await providerConn.sendAudio(Data([0x20, 0x21])) }
        try await waitForCondition("Provider pipelined send2 was not enqueued before end") {
            providerEnqueuedWrites == 3
        }
        let endP = Task { try await providerConn.endAudioAndAwaitFinal() }
        try await waitForCondition("Provider pipelined writes were not all enqueued") {
            providerEnqueuedWrites == 4
        }

        socket0.feed("p can't feed audio data to recognizer server")

        for (label, task) in [("sendP1", sendP1), ("sendP2", sendP2)] {
            do {
                try await task.value
                Issue.record("Expected provider serverUnavailable for \(label)")
            } catch AmiVoiceWebSocketConnection.ConnectionError.provider(let err) {
                #expect(err.kind == .serverUnavailable)
            } catch {
                Issue.record("Unexpected error from \(label): \(error)")
            }
        }
        do {
            _ = try await endP.value
            Issue.record("Expected provider serverUnavailable for pipelined endAudioAndAwaitFinal")
        } catch AmiVoiceWebSocketConnection.ConnectionError.provider(let err) {
            #expect(err.kind == .serverUnavailable)
        } catch {
            Issue.record("Unexpected error from endP: \(error)")
        }

        // 2. External connection.cancel() surfaces disconnected to uncancelled pipelined callers.
        var cancelSocket: ScriptedAmiVoiceSocket?
        var cancelEnqueuedWrites = 0
        let cancelConn = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            let socket = ScriptedAmiVoiceSocket(
                request: request,
                blockSendPredicate: { message in
                    if case .data(let payload) = message { return payload == blockedFrame }
                    return false
                },
                onSend: { message, ws in
                    if case .string(let text) = message, text.hasPrefix("s ") { ws.feed("s") }
                }
            )
            cancelSocket = socket
            return socket
        }
        cancelConn.onWriteEnqueued = { cancelEnqueuedWrites += 1 }
        try await cancelConn.sendAudio(Data([0x01, 0x02]))
        let socket1 = try #require(cancelSocket)
        let sendA1 = Task { try await cancelConn.sendAudio(blockedChunk) }
        try await waitForCondition("Blocked cancellation write did not reach the socket") {
            socket1.pendingSendCount == 1
        }
        #expect(socket1.pendingSendCount == 1)

        let sendA2 = Task { try await cancelConn.sendAudio(Data([0x20, 0x21])) }
        try await waitForCondition("Cancellation pipelined write was not enqueued") {
            cancelEnqueuedWrites == 3
        }

        cancelConn.cancel()

        do {
            try await sendA1.value
            Issue.record("Expected disconnected for uncancelled in-flight writer after connection.cancel()")
        } catch AmiVoiceWebSocketConnection.ConnectionError.disconnected {
            // Expected.
        } catch {
            Issue.record("Unexpected error from sendA1: \(error)")
        }

        do {
            try await sendA2.value
            Issue.record("Expected disconnected for uncancelled pipelined writer after connection.cancel()")
        } catch AmiVoiceWebSocketConnection.ConnectionError.disconnected {
            // Expected.
        } catch {
            Issue.record("Unexpected error from sendA2: \(error)")
        }

        // 3. Genuine caller task cancellation surfaces CancellationError to the cancelled caller,
        // while an uncancelled pipelined sibling observes disconnected.
        var callerCancelSocket: ScriptedAmiVoiceSocket?
        var callerCancelEnqueuedWrites = 0
        let callerCancelConn = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            let socket = ScriptedAmiVoiceSocket(
                request: request,
                blockSendPredicate: { message in
                    if case .data(let payload) = message { return payload == blockedFrame }
                    return false
                },
                onSend: { message, ws in
                    if case .string(let text) = message, text.hasPrefix("s ") { ws.feed("s") }
                }
            )
            callerCancelSocket = socket
            return socket
        }
        callerCancelConn.onWriteEnqueued = { callerCancelEnqueuedWrites += 1 }
        try await callerCancelConn.sendAudio(Data([0x01, 0x02]))
        let socket2 = try #require(callerCancelSocket)
        let sendB1 = Task { try await callerCancelConn.sendAudio(blockedChunk) }
        try await waitForCondition("Blocked caller-cancellation write did not reach the socket") {
            socket2.pendingSendCount == 1
        }
        #expect(socket2.pendingSendCount == 1)

        let sendB2 = Task { try await callerCancelConn.sendAudio(Data([0x20, 0x21])) }
        try await waitForCondition("Caller-cancellation pipelined write was not enqueued") {
            callerCancelEnqueuedWrites == 3
        }

        sendB1.cancel()

        do {
            try await sendB1.value
            Issue.record("Expected CancellationError when caller cancels sendAudio task")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error from cancelled sendB1: \(error)")
        }

        do {
            try await sendB2.value
            Issue.record("Expected disconnected for uncancelled pipelined writer after sibling cancellation")
        } catch AmiVoiceWebSocketConnection.ConnectionError.disconnected {
            // Expected.
        } catch {
            Issue.record("Unexpected error from sendB2: \(error)")
        }
    }

    @Test func cancelClosesSocketClearsCallbacksAndPreventsCrossTakeCarryover() async throws {
        var firstSocket: ScriptedAmiVoiceSocket?
        var updatesAfterCancel = 0
        var cancelled = false
        let take1 = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            let socket = ScriptedAmiVoiceSocket(request: request) { message, ws in
                if case .string(let text) = message, text.hasPrefix("s ") { ws.feed("s") }
            }
            firstSocket = socket
            return socket
        }
        take1.onUpdate = { _ in
            if cancelled { updatesAfterCancel += 1 }
        }

        try await take1.sendAudio(Data([0x01, 0x02]))
        let socket1 = try #require(firstSocket)
        socket1.feed(#"U {"text":"途中..."}"#)
        let countBeforeCancel = socket1.sentMessages.count

        cancelled = true
        take1.cancel()
        #expect(socket1.closeCodes.first == .normalClosure)

        // Late frames after cancel must never fire callbacks.
        socket1.feed(#"A {"text":"遅延到着","code":""}"#)
        await Task.yield()
        #expect(updatesAfterCancel == 0)

        // Subsequent sends / finalization fail closed with zero new frames written.
        do {
            try await take1.sendAudio(Data([0x03, 0x04]))
            Issue.record("Expected disconnected after cancel")
        } catch AmiVoiceWebSocketConnection.ConnectionError.disconnected {
            // Expected.
        }
        do {
            _ = try await take1.endAudioAndAwaitFinal()
            Issue.record("Expected disconnected on finalize after cancel")
        } catch AmiVoiceWebSocketConnection.ConnectionError.disconnected {
            // Expected.
        }
        #expect(socket1.sentMessages.count == countBeforeCancel)

        // Next take starts completely clean with zero carryover from take 1.
        var take2Opens = 0
        let take2 = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            take2Opens += 1
            return ScriptedAmiVoiceSocket(request: request) { message, ws in
                guard case .string(let text) = message else { return }
                if text.hasPrefix("s ") { ws.feed("s") }
                else if text == "e" {
                    ws.feed(#"A {"text":"新しいテイク","code":""}"#)
                    ws.feed("e")
                }
            }
        }
        #expect(take2Opens == 0)
        #expect(take2.sentAudioBytes == 0)
        #expect(take2.assembler.finalized.isEmpty)
        try await take2.sendAudio(Data([0x09, 0x0A]))
        #expect(take2Opens == 1)
        let take2Text = try await take2.endAudioAndAwaitFinal()
        #expect(take2Text == "新しいテイク")
    }

    @Test func serializedSendQueuePreservesStrictSBeforePBeforeEOrder() async throws {
        var capturedSocket: ScriptedAmiVoiceSocket?
        var enqueuedWrites = 0
        // The test intentionally withholds the s-ack while queued writers are
        // observed. CI saw the unrelated default 10 s watchdog fire after 18.6 s
        // of parallel scheduling delay; keep it outside that measurement.
        let connection = AmiVoiceWebSocketConnection(
            apiKey: "fixture-amivoice-key",
            setupTimeout: .seconds(60)
        ) { request in
            let socket = ScriptedAmiVoiceSocket(request: request) { message, ws in
                if case .string(let text) = message, text == "e" {
                    ws.feed(#"A {"text":"順序保証","code":""}"#)
                    ws.feed("e")
                }
            }
            capturedSocket = socket
            return socket
        }
        connection.onWriteEnqueued = { enqueuedWrites += 1 }

        // Start send1 and wait until lazy "s" has been sent, while withholding "s" ack.
        let send1 = Task { try await connection.sendAudio(Data([0xAA, 0xBB])) }
        try await waitForCondition("Lazy setup write did not reach the socket") {
            capturedSocket?.sentMessages.isEmpty == false
        }
        let socket = try #require(capturedSocket)

        // Enqueue send2 before creating the end task so p2 precedes e in the
        // serialized queue; both stay queued while "s" ack is still pending.
        let send2 = Task { try await connection.sendAudio(Data([0xCC, 0xDD])) }
        try await waitForCondition("Queued send2 was not enqueued before end") {
            enqueuedWrites == 2
        }
        let end = Task { try await connection.endAudioAndAwaitFinal() }
        try await waitForCondition("Queued writes were not all enqueued before setup completion") {
            enqueuedWrites == 3
        }

        // Neither p1, p2, nor e may be written before "s" ack completes.
        #expect(socket.sentMessages.count == 1)

        socket.feed("s")
        try await send1.value
        try await send2.value
        let result = try await end.value
        #expect(result == "順序保証")
        #expect(connection.sentAudioBytes == 4)
        #expect(connection.sentAudioChunks == 2)

        let sent = socket.sentMessages
        #expect(sent.count == 4)
        if case .string(let first) = sent[0] { #expect(first.hasPrefix("s ")) } else { Issue.record("Expected s first") }
        if case .data(let second) = sent[1] { #expect(second == Data([0x70, 0xAA, 0xBB])) } else { Issue.record("Expected p1 second") }
        if case .data(let third) = sent[2] { #expect(third == Data([0x70, 0xCC, 0xDD])) } else { Issue.record("Expected p2 third") }
        if case .string(let fourth) = sent[3] { #expect(fourth == "e") } else { Issue.record("Expected e fourth") }
    }

    @Test func receiveDropBeforeEndAckFailsClosedImmediately() async throws {
        let marker = "socket-drop-raw-detail-3a7f"
        let connection = AmiVoiceWebSocketConnection(
            apiKey: "fixture-amivoice-key",
            finalizationTimeout: .seconds(5)
        ) { request in
            ScriptedAmiVoiceSocket(request: request) { message, ws in
                guard case .string(let text) = message else { return }
                if text.hasPrefix("s ") {
                    ws.feed("s")
                } else if text == "e" {
                    ws.feed(#"A {"text":"切断前テキスト","code":""}"#)
                    ws.feedError(NSError(
                        domain: NSURLErrorDomain,
                        code: -1005,
                        userInfo: [NSLocalizedDescriptionKey: marker]
                    ))
                }
            }
        }
        try await connection.sendAudio(Data([0x01, 0x02]))
        let started = ContinuousClock.now
        do {
            _ = try await connection.endAudioAndAwaitFinal()
            Issue.record("Expected receiveFailed when socket drops before e-ack")
        } catch AmiVoiceWebSocketConnection.ConnectionError.receiveFailed(let reason) {
            #expect(!reason.contains(marker))
            // Immediacy check: a receive failure must fail closed without ever
            // entering the 5 s finalizationTimeout wait, so 2 s separates immediate
            // failure from dwell. It is not scheduling slack for parallel CI.
            #expect(started.duration(to: .now) < .seconds(2))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(connection.assembler.recoveryText == "切断前テキスト")
    }

    @Test func engineDiagnosticsHookCapturesEventsSynchronously() {
        let previous = EngineDiagnostics.record
        defer { EngineDiagnostics.record = previous }
        var recorded: [String] = []
        EngineDiagnostics.record = { recorded.append($0) }
        EngineDiagnostics.record("amivoice diagnostics test")
        #expect(recorded == ["amivoice diagnostics test"])
    }

    @Test func connectionFailureReasonAndDiagnosticFailureNeverLeakRawTransportText() {
        let marker = "raw-offline-marker-88d2"
        let transport = NSError(
            domain: NSURLErrorDomain,
            code: -1009,
            userInfo: [NSLocalizedDescriptionKey: marker]
        )
        let reason = AmiVoiceWebSocketConnection.connectionFailureReason(for: transport)
        let diagnostic = AmiVoiceWebSocketConnection.diagnosticFailure(transport)
        #expect(reason == UserFacingErrorMessage.message(for: transport, operation: "AmiVoiceへの接続"))
        #expect(diagnostic == "kind=connection code=-1009")
        #expect(!reason.contains(marker))
        #expect(!diagnostic.contains(marker))

        // Setup errors are mapped once without echoing raw strings or double-prefixing.
        let raw = "AmiVoice API: \(marker)"
        let setupError = AmiVoiceWebSocketConnection.ConnectionError.setup(raw)
        let mapped = AmiVoiceWebSocketConnection.connectionFailureReason(for: setupError)
        let presented = AmiVoiceWebSocketConnection.ConnectionError.setup(mapped).errorDescription ?? ""
        #expect(mapped == UserFacingErrorMessage.message(for: setupError, operation: "AmiVoiceへの接続"))
        #expect(presented == "AmiVoice API: \(mapped)")
        #expect(!presented.contains("AmiVoice API: AmiVoice API:"))
        #expect(!presented.contains(marker))
    }
}

@MainActor private final class FakeLocalTranscriber: LocalTranscribing {
    var transcript = ""
    var onUpdate: ((RecognitionPreview) -> Void)?
    let requiresSpeechAuthorization = false
    var startCount = 0
    var cancelCount = 0
    func start() async throws { startCount += 1 }
    func appendPCM16(_ data: Data) throws {}
    func appendRecoveryPCM(_ data: Data, range: Range<Int>) async throws {}
    func endAudioAndAwaitFinal() async throws -> String { transcript }
    func cancel() { cancelCount += 1 }
}

@MainActor struct AmiVoiceTakePipelineTests {
    private func makeTake(preferred: RecognitionMode = .amivoice) -> DictationTake {
        DictationTake(preferred: preferred, style: .verbatim, japaneseHint: true,
                      vocabulary: ["KoeBridge"], shouldPaste: false, options: .init())
    }

    @Test func missingAmiVoiceKeyFallsBackImmediatelyToApple() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = FakeLocalTranscriber()
        var env = VoiceController.PreparationEnvironment()
        env.loadKeyForUse = { _ in nil }
        env.makeLocalTranscriber = { local }
        let controller = VoiceController(preparation: env, storageDirectory: root)

        let take = makeTake(preferred: .amivoice)
        let start = ContinuousClock.now
        take.recordingStart = start

        let mode = try await controller.prepareRecognizer(take)
        #expect(mode == .local)
        #expect(take.effectiveMode == .local)
        #expect(take.fellBackToApple)
        #expect(!take.amiVoiceAttempted)
        #expect(take.amiVoice == nil)
        #expect(take.appleAttempted)
        #expect(take.local === local)
        #expect(local.startCount == 1)
        #expect(take.usedMode == RecognitionMode.local.label)
        #expect(take.recordingDeadline == start.advanced(by: .seconds(50)))

        take.successfulEngine = .local
        take.appleAudioBytes = 32_000
        let usage = take.usageSamples(recognizedText: "救済テキスト", cancelled: false)
        #expect(usage.tokens.isEmpty)
        #expect(usage.engines.count == 1)
        #expect(usage.engines[0].engine == .apple)
        #expect(usage.engines[0].fallback)
        #expect(usage.engines[0].outcome == .success)
        #expect(usage.engines[0].audioSeconds == 1.0)
        take.releaseResources()
    }

    @Test func presentAmiVoiceKeyPreparesLazyConnectionAndReleaseClearsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var sockets: [ScriptedAmiVoiceSocket] = []
        var env = VoiceController.PreparationEnvironment()
        env.loadKeyForUse = { $0 == .amivoice ? "fixture-amivoice-key" : nil }
        env.makeAmiVoiceConnection = { key, engine, vocab in
            AmiVoiceWebSocketConnection(apiKey: key, engine: engine, vocabulary: vocab) { request in
                let ws = ScriptedAmiVoiceSocket(request: request) { message, socket in
                    if case .string(let text) = message, text.hasPrefix("s ") {
                        socket.feed("s")
                    }
                }
                sockets.append(ws)
                return ws
            }
        }
        let controller = VoiceController(preparation: env, storageDirectory: root)
        let take = makeTake(preferred: .amivoice)
        let start = ContinuousClock.now
        take.recordingStart = start

        let mode = try await controller.prepareRecognizer(take)
        #expect(mode == .amivoice)
        #expect(take.effectiveMode == .amivoice)
        #expect(!take.fellBackToApple)
        #expect(take.amiVoiceAttempted)
        #expect(!take.appleAttempted)
        #expect(take.amiVoice != nil)
        #expect(take.amiVoice?.didOpenSocket == false)
        #expect(sockets.isEmpty)
        #expect(take.usedMode == RecognitionMode.amivoice.label)
        #expect(take.recordingDeadline == start.advanced(by: .seconds(480)))

        try await take.amiVoice?.sendAudio(Data([0x01, 0x02]))
        #expect(sockets.count == 1)
        #expect(take.amiVoice?.didOpenSocket == true)

        take.releaseResources()
        #expect(take.amiVoice == nil)
        #expect(sockets[0].closeCodes.isEmpty == false)
    }

    @Test func amiVoiceRescueEligibilityBoundaries() async throws {
        let exactLimit = DictationTake.maximumRescueBytes
        #expect(exactLimit == 50 * 32_000)

        // 1. Exactly 50 s + mid-take s-ack error + clean drain + 0 dropped -> rescue allowed.
        do {
            let take = makeTake(preferred: .amivoice)
            let connection = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
                ScriptedAmiVoiceSocket(request: request) { message, ws in
                    if case .string(let text) = message, text.hasPrefix("s ") {
                        ws.feed("s Authentication failed")
                    }
                }
            }
            take.amiVoice = connection
            take.captureDrainedCleanly = true
            take.stoppingAt = Date()
            let half = Data(count: exactLimit / 2)
            let stream = AsyncStream<Data> { output in
                output.yield(half)
                output.yield(half)
                output.finish()
            }
            var rescues = 0
            let text = try await take.transcribeLive(
                stream,
                cloudEngine: .amivoice,
                budgetExceeded: { connection.assembler.exceededFinalBudget },
                send: connection.sendAudio,
                finish: {
                    Issue.record("Should not finalize after mid-take send failure")
                    return ""
                },
                rescue: {
                    rescues += 1
                    #expect(take.audioBackup.count == exactLimit)
                    return "境界救済"
                }
            )
            #expect(text == "境界救済")
            #expect(rescues == 1)
            #expect(take.successfulEngine == .local)
        }

        // 2. Exactly 50 s + finish() failure + clean drain + 0 dropped -> rescue allowed.
        do {
            let take = makeTake(preferred: .amivoice)
            let connection = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
                ScriptedAmiVoiceSocket(request: request) { message, ws in
                    guard case .string(let text) = message else { return }
                    if text.hasPrefix("s ") {
                        ws.feed("s")
                    } else if text == "e" {
                        ws.feedError(NSError(domain: NSURLErrorDomain, code: -1005))
                    }
                }
            }
            take.amiVoice = connection
            take.captureDrainedCleanly = true
            take.stoppingAt = Date()
            let chunk = Data(count: exactLimit / 4)
            let stream = AsyncStream<Data> { output in
                for _ in 0..<4 { output.yield(chunk) }
                output.finish()
            }
            var rescues = 0
            let text = try await take.transcribeLive(
                stream,
                cloudEngine: .amivoice,
                budgetExceeded: { connection.assembler.exceededFinalBudget },
                send: connection.sendAudio,
                finish: { try await connection.endAudioAndAwaitFinal() },
                rescue: {
                    rescues += 1
                    #expect(take.audioBackup.count == exactLimit)
                    return "完了失敗救済"
                }
            )
            #expect(text == "完了失敗救済")
            #expect(rescues == 1)
            #expect(take.successfulEngine == .local)
        }

        // 3. 50 s + epsilon (2 bytes) + mid-take send failure -> no rescue, localRecoveryTooLong.
        do {
            let take = makeTake(preferred: .amivoice)
            let connection = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
                ScriptedAmiVoiceSocket(request: request) { message, ws in
                    if case .string(let text) = message, text.hasPrefix("s ") {
                        ws.feed("s Server busy")
                    }
                }
            }
            take.amiVoice = connection
            take.captureDrainedCleanly = true
            take.stoppingAt = Date()
            let stream = AsyncStream<Data> { output in
                output.yield(Data(count: exactLimit))
                output.yield(Data([0x01, 0x02]))
                output.finish()
            }
            var rescues = 0
            do {
                _ = try await take.transcribeLive(
                    stream,
                    cloudEngine: .amivoice,
                    budgetExceeded: { connection.assembler.exceededFinalBudget },
                    send: connection.sendAudio,
                    finish: { try await connection.endAudioAndAwaitFinal() },
                    rescue: {
                        rescues += 1
                        return "unexpected"
                    }
                )
                Issue.record("Expected localRecoveryTooLong for 50 s + epsilon send failure")
            } catch VoiceController.AppError.localRecoveryTooLong {}
            #expect(rescues == 0)
        }

        // 4. 50 s + epsilon (2 bytes) + finish() failure -> no rescue, localRecoveryTooLong.
        do {
            let take = makeTake(preferred: .amivoice)
            let connection = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
                ScriptedAmiVoiceSocket(request: request) { message, ws in
                    guard case .string(let text) = message else { return }
                    if text.hasPrefix("s ") {
                        ws.feed("s")
                    } else if text == "e" {
                        ws.feedError(NSError(domain: NSURLErrorDomain, code: -1005))
                    }
                }
            }
            take.amiVoice = connection
            take.captureDrainedCleanly = true
            take.stoppingAt = Date()
            let stream = AsyncStream<Data> { output in
                output.yield(Data(count: exactLimit))
                output.yield(Data([0x01, 0x02]))
                output.finish()
            }
            var rescues = 0
            do {
                _ = try await take.transcribeLive(
                    stream,
                    cloudEngine: .amivoice,
                    budgetExceeded: { connection.assembler.exceededFinalBudget },
                    send: connection.sendAudio,
                    finish: { try await connection.endAudioAndAwaitFinal() },
                    rescue: {
                        rescues += 1
                        return "unexpected"
                    }
                )
                Issue.record("Expected localRecoveryTooLong for 50 s + epsilon finish failure")
            } catch VoiceController.AppError.localRecoveryTooLong {}
            #expect(rescues == 0)
        }

        // 5. droppedChunks > 0 blocks rescue even when <= 50 s and cleanly drained.
        do {
            let take = makeTake(preferred: .amivoice)
            take.captureDrainedCleanly = true
            take.stoppingAt = Date()
            take.audioIntegrity.markDropped()
            let stream = AsyncStream<Data> { output in
                output.yield(Data([0x01, 0x02, 0x03, 0x04]))
                output.finish()
            }
            var rescues = 0
            do {
                _ = try await take.transcribeLive(
                    stream,
                    cloudEngine: .amivoice,
                    send: { _ in throw VoiceController.AppError.connectionLost },
                    finish: { return "" },
                    rescue: {
                        rescues += 1
                        return "unexpected"
                    }
                )
                Issue.record("Expected audioDropped when droppedChunks > 0")
            } catch VoiceController.AppError.audioDropped {}
            #expect(rescues == 0)
        }

        // 6. Unclean drain or missing stoppingAt blocks rescue.
        for (drained, hasStop) in [(false, true), (true, false)] {
            let take = makeTake(preferred: .amivoice)
            take.captureDrainedCleanly = drained
            take.stoppingAt = hasStop ? Date() : nil
            let stream = AsyncStream<Data> { output in
                output.yield(Data([0x01, 0x02]))
                output.finish()
            }
            var rescues = 0
            do {
                _ = try await take.transcribeLive(
                    stream,
                    cloudEngine: .amivoice,
                    send: { _ in throw VoiceController.AppError.connectionLost },
                    finish: { return "" },
                    rescue: {
                        rescues += 1
                        return "unexpected"
                    }
                )
                Issue.record("Expected audioDropped when drain or stoppingAt is incomplete")
            } catch VoiceController.AppError.audioDropped {}
            #expect(rescues == 0)
        }
    }

    @Test func amiVoiceOverBudgetClosesSocketPreservesBoundedPrefixAndSkipsRescue() async throws {
        for budget in [TranscriptAssembler.FinalBudget(bytes: 12, identities: 100),
                       TranscriptAssembler.FinalBudget(bytes: 1000, identities: 1)] {
            var capturedSocket: ScriptedAmiVoiceSocket?
            let connection = AmiVoiceWebSocketConnection(
                apiKey: "fixture-amivoice-key",
                finalBudget: budget
            ) { request in
                let ws = ScriptedAmiVoiceSocket(request: request) { message, socket in
                    if case .string(let text) = message, text.hasPrefix("s ") {
                        socket.feed("s")
                    }
                }
                capturedSocket = ws
                return ws
            }
            var budgetErrors = 0
            connection.onError = { error in
                if error == .finalBudgetExceeded { budgetErrors += 1 }
            }
            try await connection.sendAudio(Data([0x01, 0x02]))
            let socket = try #require(capturedSocket)
            for _ in 0..<8 {
                socket.feed(#"A {"text":"ab","code":""}"#)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !connection.assembler.exceededFinalBudget && ContinuousClock.now < deadline {
                await Task.yield()
            }
            #expect(connection.assembler.exceededFinalBudget)
            #expect(budgetErrors == 1)
            #expect(connection.assembler.committedText.isEmpty)
            #expect(socket.closeCodes.isEmpty == false)

            let take = makeTake(preferred: .amivoice)
            take.amiVoice = connection
            take.captureDrainedCleanly = true
            take.stoppingAt = Date()
            let stream = AsyncStream<Data> { output in
                output.yield(Data([0x03, 0x04]))
                output.finish()
            }
            var delivered: [String] = []
            do {
                delivered.append(try await take.transcribeLive(
                    stream,
                    cloudEngine: .amivoice,
                    budgetExceeded: { connection.assembler.exceededFinalBudget },
                    send: connection.sendAudio,
                    finish: { try await connection.endAudioAndAwaitFinal() },
                    rescue: {
                        Issue.record("Over-budget AmiVoice take must never enter Apple rescue")
                        return "unexpected"
                    }
                ))
                Issue.record("Expected finalBudgetExceeded")
            } catch AmiVoiceWebSocketConnection.ConnectionError.finalBudgetExceeded {}
            #expect(delivered.isEmpty)
            #expect(!take.recoverableText.isEmpty)
            #expect(take.recoverableText == connection.assembler.recoveryText)
        }
    }

    @Test func reviewSessionMessageSwitchesExhaustivelyForAmiVoiceAndLocal() async {
        let options = TranscriptionOptions(
            textContextCheckEnabled: true,
            audioRecheckEnabled: true,
            audioRecheckPolicy: .always
        )

        var amivoiceRechecked = false
        let amiVoiceReview = DictationReviewSession(
            originalText: "テスト結果",
            engine: .amivoice,
            options: options,
            stoppedAt: Date(),
            audio: Data(count: 3_200),
            vocabulary: [],
            style: .verbatim,
            japaneseHint: true
        )
        let amiVoiceOutput = await amiVoiceReview.run { amivoiceRechecked = true }
        #expect(amiVoiceOutput == "テスト結果")
        #expect(!amivoiceRechecked)
        #expect(amiVoiceReview.record?.status == .incomplete)
        #expect(amiVoiceReview.record?.note == "AmiVoiceの認識結果にはGemini用の追加チェックを実行していません。")

        for nonCloudEngine in [RecognitionMode?.some(.local), RecognitionMode?.none] {
            var rechecked = false
            let review = DictationReviewSession(
                originalText: "ローカル結果",
                engine: nonCloudEngine,
                options: options,
                stoppedAt: Date(),
                audio: Data(count: 3_200),
                vocabulary: [],
                style: .verbatim,
                japaneseHint: true
            )
            let output = await review.run { rechecked = true }
            #expect(output == "ローカル結果")
            #expect(!rechecked)
            #expect(review.record?.status == .incomplete)
            #expect(review.record?.note == "Appleの認識結果にはGemini用の追加チェックを実行していません。")
        }
    }

    @Test func amiVoiceReplayChunks16KBKeyCacheUsageSamplesAndErrorMappings() async throws {
        // 16 KiB p-chunk replay streaming
        var capturedSocket: ScriptedAmiVoiceSocket?
        let connection = AmiVoiceWebSocketConnection(
            apiKey: "fixture-amivoice-key",
            engine: .e2eJapaneseGeneral
        ) { request in
            let ws = ScriptedAmiVoiceSocket(request: request) { message, socket in
                guard case .string(let text) = message else { return }
                if text.hasPrefix("s ") {
                    socket.feed("s")
                } else if text == "e" {
                    socket.feed("S 500")
                    socket.feed("E 2000")
                    socket.feed(#"A {"text":"再文字起こし結果","code":""}"#)
                    socket.feed("e")
                }
            }
            capturedSocket = ws
            return ws
        }
        let pcm = Data(count: 40_000)
        let replayed = try await VoiceController.streamReplayPCM(pcm, through: connection)
        #expect(replayed == "再文字起こし結果")
        let socket = try #require(capturedSocket)
        let binarySizes: [Int] = socket.sentMessages.compactMap { message in
            if case .data(let data) = message {
                #expect(data.first == 0x70)
                return data.count - 1
            }
            return nil
        }
        #expect(binarySizes == [16_384, 16_384, 7_232])

        // DictationTake AmiVoice usageSamples
        let take = makeTake(preferred: .amivoice)
        take.amiVoiceAttempted = true
        take.amiVoiceStartedAt = Date()
        take.amiVoice = connection
        take.successfulEngine = .amivoice
        let usage = take.usageSamples(recognizedText: replayed, cancelled: false)
        #expect(usage.tokens.isEmpty)
        #expect(usage.engines.count == 1)
        #expect(usage.engines[0].engine == .amivoice)
        #expect(usage.engines[0].outcome == .success)
        #expect(usage.engines[0].audioSeconds == Double(40_000) / 32_000)
        #expect(usage.engines[0].speechSeconds == 1.5)
        #expect(usage.engines[0].engineVariant == AmiVoiceEngine.e2eJapaneseGeneral.rawValue)

        // VoiceController key cache covers both Gemini and AmiVoice and clears both on invalidate
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var geminiRegistered = false
        var amiVoiceRegistered = true
        var reads: [CredentialProvider: Int] = [:]
        var env = VoiceController.PreparationEnvironment()
        env.keyRegistered = { provider in
            reads[provider, default: 0] += 1
            switch provider {
            case .gemini: return geminiRegistered
            case .amivoice: return amiVoiceRegistered
            }
        }
        let controller = VoiceController(preparation: env, storageDirectory: root)
        #expect(!controller.hasKey)
        #expect(!controller.hasKey)
        #expect(controller.hasAmiVoiceKey)
        #expect(controller.hasAmiVoiceKey)
        #expect(reads[.gemini] == 1)
        #expect(reads[.amivoice] == 1)
        geminiRegistered = true
        amiVoiceRegistered = false
        controller.invalidateKeyRegistration()
        #expect(controller.hasKey)
        #expect(!controller.hasAmiVoiceKey)
        #expect(reads[.gemini] == 2)
        #expect(reads[.amivoice] == 2)

        // Local rescue labels and error mappings
        #expect(VoiceController.localRescueModeLabel(for: .gemini) == "Appleオンデバイス（Gemini失敗時の救済）")
        #expect(VoiceController.localRescueModeLabel(for: .amivoice) == "Appleオンデバイス（AmiVoice失敗時の救済）")
        #expect(VoiceController.localRescueModeLabel(for: .local) == "Appleオンデバイス（救済）")

        let authErr = AmiVoiceProviderError(resultCode: "-")
        #expect(VoiceController.failureCategory(AmiVoiceWebSocketConnection.ConnectionError.provider(authErr)) == "amivoice.provider.authentication")
        #expect(VoiceController.failureCategory(AmiVoiceWebSocketConnection.ConnectionError.finalBudgetExceeded) == "amivoice.final_budget")
        #expect(VoiceController.failureCategory(AmiVoiceWebSocketConnection.ConnectionError.finalizationTimeout) == "amivoice.finalization_timeout")
        #expect(VoiceController.failureCategory(AmiVoiceWebSocketConnection.ConnectionError.noSpeech) == "amivoice.no_speech")
        #expect(VoiceController.failureCategory(AmiVoiceWireError.malformedFrame) == "amivoice.wire.malformed_frame")
        #expect(VoiceController.userFacingFailure(VoiceController.AppError.noAmiVoiceKey, operation: "音声認識").contains("AmiVoice"))
        #expect(VoiceController.userFacingFailure(AmiVoiceWebSocketConnection.ConnectionError.provider(authErr), operation: "音声認識") == authErr.errorDescription)
    }
}
#endif
