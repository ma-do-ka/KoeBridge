#if os(macOS)
import Foundation
import Testing
import KoeBridgeCore
import KoeBridgeEngines

private final class ScriptedAmiVoiceSocket: AmiVoiceSocket, @unchecked Sendable {
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while utteranceErrorConn.assembler.fatalError == nil && ContinuousClock.now < deadline {
            await Task.yield()
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
        let pDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while provideErrorConn.assembler.fatalError == nil && ContinuousClock.now < pDeadline {
            await Task.yield()
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

            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !connection.assembler.exceededFinalBudget && ContinuousClock.now < deadline {
                await Task.yield()
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

        try await connection.sendAudio(Data([0x01, 0x02]))
        let socket = try #require(capturedSocket)

        let send1 = Task { try await connection.sendAudio(blockedChunk) }
        let blockDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while socket.pendingSendCount == 0 && ContinuousClock.now < blockDeadline {
            await Task.yield()
        }
        #expect(socket.pendingSendCount == 1)

        let send2Ready = AsyncStream<Void>.makeStream()
        let send2 = Task {
            send2Ready.continuation.yield()
            try await connection.sendAudio(Data([0x20, 0x21]))
        }
        var send2Iterator = send2Ready.stream.makeAsyncIterator()
        _ = await send2Iterator.next()

        let endReady = AsyncStream<Void>.makeStream()
        let end = Task {
            endReady.continuation.yield()
            return try await connection.endAudioAndAwaitFinal()
        }
        var endIterator = endReady.stream.makeAsyncIterator()
        _ = await endIterator.next()

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
        try await providerConn.sendAudio(Data([0x01, 0x02]))
        let socket0 = try #require(providerSocket)
        let sendP1 = Task { try await providerConn.sendAudio(blockedChunk) }
        let deadline0 = ContinuousClock.now.advanced(by: .seconds(2))
        while socket0.pendingSendCount == 0 && ContinuousClock.now < deadline0 {
            await Task.yield()
        }
        #expect(socket0.pendingSendCount == 1)

        let sendP2Ready = AsyncStream<Void>.makeStream()
        let sendP2 = Task {
            sendP2Ready.continuation.yield()
            try await providerConn.sendAudio(Data([0x20, 0x21]))
        }
        var sendP2Iterator = sendP2Ready.stream.makeAsyncIterator()
        _ = await sendP2Iterator.next()

        let endPReady = AsyncStream<Void>.makeStream()
        let endP = Task {
            endPReady.continuation.yield()
            return try await providerConn.endAudioAndAwaitFinal()
        }
        var endPIterator = endPReady.stream.makeAsyncIterator()
        _ = await endPIterator.next()

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
        try await cancelConn.sendAudio(Data([0x01, 0x02]))
        let socket1 = try #require(cancelSocket)
        let sendA1 = Task { try await cancelConn.sendAudio(blockedChunk) }
        let deadline1 = ContinuousClock.now.advanced(by: .seconds(2))
        while socket1.pendingSendCount == 0 && ContinuousClock.now < deadline1 {
            await Task.yield()
        }
        #expect(socket1.pendingSendCount == 1)

        let sendA2Ready = AsyncStream<Void>.makeStream()
        let sendA2 = Task {
            sendA2Ready.continuation.yield()
            try await cancelConn.sendAudio(Data([0x20, 0x21]))
        }
        var sendA2Iterator = sendA2Ready.stream.makeAsyncIterator()
        _ = await sendA2Iterator.next()

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
        try await callerCancelConn.sendAudio(Data([0x01, 0x02]))
        let socket2 = try #require(callerCancelSocket)
        let sendB1 = Task { try await callerCancelConn.sendAudio(blockedChunk) }
        let deadline2 = ContinuousClock.now.advanced(by: .seconds(2))
        while socket2.pendingSendCount == 0 && ContinuousClock.now < deadline2 {
            await Task.yield()
        }
        #expect(socket2.pendingSendCount == 1)

        let sendB2Ready = AsyncStream<Void>.makeStream()
        let sendB2 = Task {
            sendB2Ready.continuation.yield()
            try await callerCancelConn.sendAudio(Data([0x20, 0x21]))
        }
        var sendB2Iterator = sendB2Ready.stream.makeAsyncIterator()
        _ = await sendB2Iterator.next()

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
        let connection = AmiVoiceWebSocketConnection(apiKey: "fixture-amivoice-key") { request in
            let socket = ScriptedAmiVoiceSocket(request: request) { message, ws in
                if case .string(let text) = message, text == "e" {
                    ws.feed(#"A {"text":"順序保証","code":""}"#)
                    ws.feed("e")
                }
            }
            capturedSocket = socket
            return socket
        }

        // Start send1 and wait until lazy "s" has been sent, while withholding "s" ack.
        let send1 = Task { try await connection.sendAudio(Data([0xAA, 0xBB])) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while capturedSocket?.sentMessages.isEmpty != false && ContinuousClock.now < deadline {
            await Task.yield()
        }
        let socket = try #require(capturedSocket)

        // Enqueue send2 and endAudioAndAwaitFinal while "s" ack is still pending.
        let send2Ready = AsyncStream<Void>.makeStream()
        let send2 = Task {
            send2Ready.continuation.yield()
            try await connection.sendAudio(Data([0xCC, 0xDD]))
        }
        var send2Iterator = send2Ready.stream.makeAsyncIterator()
        _ = await send2Iterator.next()

        let endReady = AsyncStream<Void>.makeStream()
        let end = Task {
            endReady.continuation.yield()
            return try await connection.endAudioAndAwaitFinal()
        }
        var endIterator = endReady.stream.makeAsyncIterator()
        _ = await endIterator.next()

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
#endif
