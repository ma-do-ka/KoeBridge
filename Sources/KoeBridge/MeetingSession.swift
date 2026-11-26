#if os(macOS)
import Foundation
import KoeBridgeCore
import KoeBridgeEngines

private final class MeetingAudioCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func append(_ data: Data) { lock.lock(); count += data.count; lock.unlock() }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// No insertion target and no DictationTake delivery hooks. Each source owns a
/// recognizer, capture/admission state, bounded queue, and sequential rollover.
@MainActor final class MeetingSession {
    let engine: RecognitionMode
    let recordedAt = Date()
    private let origin = ProcessInfo.processInfo.systemUptime
    private let vocabulary: [String]
    private let style: TranscriptionStyle
    private let japaneseHint: Bool
    private let apiKey: String?
    private let amiVoiceKey: String?
    private let amiVoiceEngine: AmiVoiceEngine
    private let amiVoiceProfileId: String?
    private let microphoneUID: String
    private var transcript = MeetingTranscript()
    private var tasks: [Task<Void, Never>] = []
    private var chunks: [MeetingTranscript.Source: Chunk] = [:]
    private(set) var stopping = false
    private var systemFailed = false
    private var micFailed = false
    private var requestedMicrophone = false
    private(set) var microphoneRecoveryMessage: String?
    private var completed = false
    private var recognitionProblems: [String] = []
    var onUsage: ((EngineUsageSample, [GeminiTokenSample]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFinished: ((String, Bool) -> Void)?
    var onMicrophoneStarted: (() -> Void)?
    var onMicrophoneInterruption: ((MicrophoneInputInterruption) -> Void)?
    var onMicrophoneFailure: ((Error, MicrophoneCapture.EngineLifetime.Disposition) -> Void)?

    @MainActor final class Chunk {
        var mic: MicrophoneCapture?
        var system: SystemAudioCapture?
        var local: LocalTranscribing?
        var cloud: GeminiLiveConnection?
        var amiVoice: AmiVoiceWebSocketConnection?
        var stopRequested = false
        var captureEnd: CaptureEnd = .normal
        var captureEnded = false
        var captureDrain: Task<Void, Never>?
        var failed = false
        var startedAt = ProcessInfo.processInfo.systemUptime
        fileprivate var usageRecorded = false
        let requestedAt = Date()
        var localProcessedBytes = 0
        var admittedBytes = 0
        fileprivate let emittedAudio = MeetingAudioCount()
        var timer: Task<Void, Never>?
        var continuation: AsyncStream<Data>.Continuation?
        var worker: Task<String, Error>?
        let integrity = AudioIntegrityState()
        func microphoneStopped(losses: Int) {
            if losses > 0 { integrity.markDropped() }
        }
        var finalText: String?
        var partial: String { finalText ?? local?.transcript ?? cloud?.assembler.recoveryText ?? amiVoice?.assembler.recoveryText ?? "" }
    }

    init(engine: RecognitionMode, vocabulary: [String], style: TranscriptionStyle,
         japaneseHint: Bool, apiKey: String?, microphoneUID: String,
         amiVoiceKey: String? = nil, amiVoiceEngine: AmiVoiceEngine = .e2eJapaneseGeneral,
         amiVoiceProfileId: String? = nil) {
        self.engine = engine; self.vocabulary = vocabulary; self.style = style
        self.japaneseHint = japaneseHint; self.apiKey = apiKey; self.microphoneUID = microphoneUID
        self.amiVoiceKey = amiVoiceKey; self.amiVoiceEngine = amiVoiceEngine
        self.amiVoiceProfileId = amiVoiceProfileId
    }

    static func chunkDurationSeconds(for engine: RecognitionMode) -> TimeInterval {
        switch engine {
        case .local: return 50.0
        case .gemini, .amivoice: return 480.0
        }
    }

    func start() {
        start(runChunk: runChunk)
    }

    func start(runChunk: @escaping (Chunk, MeetingTranscript.Source) async throws -> Void) {
        guard tasks.isEmpty, !completed else { return }
        if stopping { finishMeeting(); return }
        tasks = [Task { await self.run(.microphone, runChunk: runChunk) }, Task { await self.run(.system, runChunk: runChunk) }]
        Task { [self] in
            for task in tasks { await task.value }
            finishMeeting()
            tasks = []
        }
    }

    /// Permission denial happens before start, so complete without launching chunks.
    func microphonePermissionDenied() {
        micFailed = true
        stop()
        finishMeeting()
    }

    private func finishMeeting() {
        var text = transcript.text
        if systemFailed { text += (text.isEmpty ? "" : "\n\n") + "システム音声は途中で停止しました" }
        if micFailed { text += (text.isEmpty ? "" : "\n\n") + "マイクが停止したため会議モードを終了しました" }
        if !recognitionProblems.isEmpty { text += "\n\n" + recognitionProblems.joined(separator: "\n") }
        finish(text, partial: micFailed || systemFailed || !recognitionProblems.isEmpty)
    }

    func save(_ text: String, partial: Bool, to history: inout TranscriptHistoryStore) -> UUID? {
        history.remember(text, isPartial: partial,
                         delivery: partial ? .recognitionInterrupted : .automaticPasteDisabled,
                         engine: engine.label, recordedAt: recordedAt, kind: "meeting")
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        for (source, chunk) in chunks {
            chunk.stopRequested = true
            // Stop during model download/connection setup must not wait for
            // preparation to finish. Active captures still drain normally.
            if chunk.worker == nil {
                chunk.local?.cancel(); chunk.cloud?.cancel(); chunk.amiVoice?.cancel()
                let index = source == .microphone ? 0 : 1
                if tasks.indices.contains(index) { tasks[index].cancel() }
            }
        }
    }
    /// Shutdown cannot await recognition. Save a single honest partial snapshot
    /// synchronously, invalidate callbacks, and stop all upload/capture owners.
    func interrupt(_ reason: String) {
        guard !completed else { return }
        stop()
        var snapshot = transcript
        for (source, chunk) in chunks {
            chunk.captureEnd = .cancelled
            recordUsage(chunk, interrupted: true)
            snapshot.append(source: source, offset: segmentOffset(chunk, source: source), text: chunk.partial)
            chunk.timer?.cancel(); chunk.worker?.cancel()
            chunk.cloud?.cancel(); chunk.amiVoice?.cancel(); chunk.local?.cancel()
            Task { await self.endCapture(chunk) }
        }
        tasks.forEach { $0.cancel() }
        let text = snapshot.text
        finish(text.isEmpty ? "" : text + "\n\n" + reason, partial: true)
    }
    private func finish(_ text: String, partial: Bool) {
        guard !completed else { return }
        completed = true
        onFinished?(text, partial)
        onFinished = nil; onStatus = nil
    }
    private func segmentOffset(_ chunk: Chunk, source: MeetingTranscript.Source) -> TimeInterval {
        let start = (chunk.system?.startedAtUptime ?? chunk.startedAt) - origin
        if source == .system { return start + (chunk.system?.releasedFrom ?? 0) }
        // Capture emits a contiguous admitted suffix. Count at the callback,
        // not at the worker: backpressure/failure must not shift its start.
        return start + max(0, Double(chunk.mic?.totalPCMBytes ?? 0) / 32_000 - Double(chunk.emittedAudio.bytes) / 32_000)
    }
    func systemPermissionRevoked() {
        systemFailed = true
        chunks[.system]?.failed = true
        chunks[.system]?.stopRequested = true
    }
    var liveStatus: String {
        let seconds = Int(ProcessInfo.processInfo.systemUptime - origin)
        func activity(_ source: MeetingTranscript.Source) -> String {
            guard let chunk = chunks[source] else { return "待機" }
            let evidence = source == .microphone ? chunk.mic?.activityEvidence : chunk.system?.activityEvidence
            switch evidence?.classification {
            case .activity: return "発話"
            case .nearSilence: return "無音"
            case .uncertain: return "音あり（未確認）"
            default: return chunk.captureEnded ? "確定待ち" : "準備中"
            }
        }
        return String(format: "会議モード%@ %02d:%02d・マイク %@・システム %@",
            stopping ? "停止処理中" : "中", seconds / 60, seconds % 60,
            activity(.microphone), systemFailed ? "停止" : activity(.system))
    }

    private func run(_ source: MeetingTranscript.Source, runChunk: (Chunk, MeetingTranscript.Source) async throws -> Void) async {
        while !stopping && !(source == .system && systemFailed) {
            let chunk = Chunk()
            chunks[source] = chunk
            do { try await runChunk(chunk, source) }
            catch {
                // Stop explicitly cancels a source still preparing its recognizer.
                // A capture or finalization error after that stage is a real failure.
                if !(stopping && Task.isCancelled && chunk.worker == nil) {
                    chunk.failed = true
                }
                if !stopping {
                    // End this source rather than silently skipping a failed chunk.
                    if source == .microphone { micFailed = true; stop() }
                    else { systemFailed = true }
                }
            }
            chunk.timer?.cancel()
            await endCapture(chunk)
            if chunk.finalText == nil, let worker = chunk.worker {
                do { chunk.finalText = try await worker.value }
                catch { chunk.failed = true }
            }
            recordChunk(source: source, offset: segmentOffset(chunk, source: source), text: chunk.partial,
                        recognitionFailed: chunk.failed, dropped: chunk.integrity.droppedChunks)
            recordUsage(chunk, interrupted: completed)
            chunk.cloud?.cancel(); chunk.amiVoice?.cancel(); chunk.local?.cancel()
            chunks[source] = nil
            if chunk.failed { break }
        }
    }

    private func recordUsage(_ chunk: Chunk, interrupted: Bool) {
        guard !chunk.usageRecorded else { return }
        chunk.usageRecorded = true
        let outcome: UsageOutcome
        if interrupted { outcome = .cancelled }
        else if chunk.failed || chunk.integrity.droppedChunks > 0 { outcome = .failure }
        else { outcome = chunk.finalText == nil ? .cancelled : .success }
        let sample: EngineUsageSample
        let tokens: [GeminiTokenSample]
        switch engine {
        case .local:
            sample = EngineUsageSample(at: chunk.requestedAt, engine: .apple,
                                       audioSeconds: Double(chunk.localProcessedBytes) / 32_000,
                                       outcome: outcome)
            tokens = []
        case .gemini:
            sample = EngineUsageSample(at: chunk.requestedAt, engine: .gemini,
                                       audioSeconds: Double(chunk.cloud?.sentAudioBytes ?? 0) / 32_000,
                                       outcome: outcome)
            tokens = chunk.cloud?.tokenSamples ?? []
        case .amivoice:
            let speechSeconds: Double? = chunk.amiVoice.flatMap { conn -> Double? in
                if conn.speechDurationMS > 0 { return conn.speechDurationSeconds }
                if conn.assembler.endAcknowledged && conn.assembler.finalCount == 0 { return 0.0 }
                return nil
            }
            sample = EngineUsageSample(at: chunk.requestedAt, engine: .amivoice,
                                       audioSeconds: Double(chunk.amiVoice?.sentAudioBytes ?? 0) / 32_000,
                                       outcome: outcome,
                                       speechSeconds: speechSeconds,
                                       engineVariant: chunk.amiVoice?.engine.rawValue ?? amiVoiceEngine.rawValue)
            tokens = []
        }
        onUsage?(sample, tokens)
    }

    private func recordChunk(source: MeetingTranscript.Source, offset: TimeInterval, text: String,
                             recognitionFailed: Bool, dropped: Int) {
        if dropped > 0 || recognitionFailed {
            let problem = dropped > 0 ? "音声が欠落しました" : "認識が中断しました"
            recognitionProblems.append("\(source.label)：\(problem)（途中結果を保存）")
        }
        transcript.append(source: source, offset: offset, text: text)
    }

    private func runChunk(_ chunk: Chunk, source: MeetingTranscript.Source) async throws {
        switch engine {
        case .local:
            let local = LocalTranscriberFactory.make(); chunk.local = local
            try await local.start()
        case .gemini:
            guard let apiKey else { throw VoiceController.AppError.noKey }
            let cloud = GeminiLiveConnection(finalBudget: nil); chunk.cloud = cloud
            try await cloud.connect(apiKey: apiKey, vocabulary: vocabulary, style: style, japaneseHint: japaneseHint)
        case .amivoice:
            guard let amiVoiceKey else { throw VoiceController.AppError.noAmiVoiceKey }
            // Lazy open on first non-empty PCM chunk; unlimited finalBudget for meeting chunks.
            chunk.amiVoice = AmiVoiceWebSocketConnection(
                apiKey: amiVoiceKey,
                engine: amiVoiceEngine,
                vocabulary: vocabulary,
                profileId: amiVoiceProfileId,
                finalBudget: nil
            )
        }
        guard !stopping, !chunk.stopRequested else { return }
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(480))
        chunk.continuation = continuation
        let integrity = chunk.integrity
        let emittedAudio = chunk.emittedAudio
        let audio: (Data) -> Void = { data in
            emittedAudio.append(data)
            if case .dropped = continuation.yield(data) { integrity.markDropped() }
        }
        let failureWithInterruption: (MicrophoneInputInterruption) -> Void = { [weak self, weak chunk] interruption in
            Task { @MainActor in
                guard let self, let chunk, !chunk.captureEnded else { return }
                chunk.failed = true; chunk.stopRequested = true
                if source == .microphone {
                    self.micFailed = true
                    self.onMicrophoneInterruption?(interruption)
                    self.stop()
                }
                else { self.systemFailed = true }
            }
        }
        let failure: () -> Void = { failureWithInterruption(.inputChange) }
        chunk.worker = Task {
            do {
                for await data in stream {
                    chunk.admittedBytes += data.count
                    switch self.engine {
                    case .gemini:
                        if let cloud = chunk.cloud { try await cloud.sendAudio(data) }
                    case .amivoice:
                        if let amiVoice = chunk.amiVoice { try await amiVoice.sendAudio(data) }
                    case .local:
                        if let local = chunk.local {
                            try local.appendPCM16(data)
                            chunk.localProcessedBytes += data.count
                        }
                    }
                }
                guard integrity.droppedChunks == 0 else { throw VoiceController.AppError.audioDropped }
                guard chunk.admittedBytes > 0 else { return "" }
                switch self.engine {
                case .gemini:
                    if let cloud = chunk.cloud { try await cloud.endAudio(); return try await cloud.awaitFinal() }
                    return ""
                case .amivoice:
                    return try await chunk.amiVoice?.endAudioAndAwaitFinal() ?? ""
                case .local:
                    return try await chunk.local?.endAudioAndAwaitFinal() ?? ""
                }
            } catch {
                chunk.captureEnd = .interrupted
                chunk.stopRequested = true
                throw error
            }
        }
        chunk.startedAt = ProcessInfo.processInfo.systemUptime
        if source == .microphone {
            let mic = MicrophoneCapture(selectedInputUID: microphoneUID, explicitStart: !requestedMicrophone)
            requestedMicrophone = true
            chunk.mic = mic
            do {
                try await mic.start(onAudio: audio, onDeviceChanged: failureWithInterruption)
            } catch {
                if !(error is CancellationError) {
                    microphoneRecoveryMessage = mic.recoveryDisposition.message
                    onMicrophoneFailure?(error, mic.recoveryDisposition)
                }
                throw error
            }
            onMicrophoneStarted?()
            chunk.startedAt = ProcessInfo.processInfo.systemUptime - Double(mic.totalPCMBytes) / 32_000
        } else {
            let system = SystemAudioCapture(onAudio: audio, onFailure: failure)
            chunk.system = system
            try await system.start()
        }
        try Task.checkCancellation()
        if stopping { chunk.stopRequested = true }
        let deadline = chunk.startedAt + Self.chunkDurationSeconds(for: engine)
        chunk.timer = Task {
            do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) }
            catch { return }
            chunk.stopRequested = true
            // Stop directly at the deadline; do not wait for the status poll.
            await self.endCapture(chunk)
        }
        while !chunk.stopRequested && !stopping {
            onStatus?(liveStatus)
            try await Task.sleep(for: .milliseconds(200))
        }
        await endCapture(chunk)
        let final = try await chunk.worker?.value ?? ""
        // Keep finalized text even if a backend's transcript property differs.
        chunk.finalText = final
    }
    private func endCapture(_ chunk: Chunk) async {
        if let drain = chunk.captureDrain { await drain.value; return }
        chunk.captureEnded = true
        let drain = Task { @MainActor in
            let end: CaptureEnd = (chunk.failed || micFailed || chunk.integrity.droppedChunks > 0)
                ? .interrupted : chunk.captureEnd
            if let mic = chunk.mic {
                let losses = await withCheckedContinuation { done in mic.stop(end) { done.resume(returning: $0) } }
                chunk.microphoneStopped(losses: losses)
            }
            if let system = chunk.system, !(await system.stop(end)) { chunk.integrity.markDropped() }
            chunk.continuation?.finish(); chunk.continuation = nil
        }
        chunk.captureDrain = drain
        await drain.value
    }
}
#endif
