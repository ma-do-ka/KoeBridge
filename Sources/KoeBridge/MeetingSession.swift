#if os(macOS)
import Foundation
import KoeBridgeCore

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

    @MainActor final class Chunk {
        var mic: MicrophoneCapture?
        var system: SystemAudioCapture?
        var local: LocalTranscribing?
        var cloud: GeminiLiveConnection?
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
        var partial: String { finalText ?? local?.transcript ?? cloud?.assembler.recoveryText ?? "" }
    }

    init(engine: RecognitionMode, vocabulary: [String], style: TranscriptionStyle,
         japaneseHint: Bool, apiKey: String?, microphoneUID: String) {
        self.engine = engine; self.vocabulary = vocabulary; self.style = style
        self.japaneseHint = japaneseHint; self.apiKey = apiKey; self.microphoneUID = microphoneUID
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
                chunk.local?.cancel(); chunk.cloud?.cancel()
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
            chunk.cloud?.cancel(); chunk.local?.cancel()
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
            chunk.cloud?.cancel(); chunk.local?.cancel()
            chunks[source] = nil
            if chunk.failed { break }
        }
    }

    private func recordUsage(_ chunk: Chunk, interrupted: Bool) {
        guard !chunk.usageRecorded else { return }
        chunk.usageRecorded = true
        let bytes = engine == .local ? chunk.localProcessedBytes : chunk.cloud?.sentAudioBytes ?? 0
        let outcome: UsageOutcome
        if interrupted { outcome = .cancelled }
        else if chunk.failed || chunk.integrity.droppedChunks > 0 { outcome = .failure }
        else { outcome = chunk.finalText == nil ? .cancelled : .success }
        onUsage?(EngineUsageSample(at: chunk.requestedAt, engine: engine == .local ? .apple : .gemini,
                                   audioSeconds: Double(bytes) / 32_000, outcome: outcome),
                 chunk.cloud?.tokenSamples ?? [])
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
        if engine == .local {
            let local = LocalTranscriberFactory.make(); chunk.local = local
            try await local.start()
        } else {
            guard let apiKey else { throw VoiceController.AppError.noKey }
            let cloud = GeminiLiveConnection(finalBudget: nil); chunk.cloud = cloud
            try await cloud.connect(apiKey: apiKey, vocabulary: vocabulary, style: style, japaneseHint: japaneseHint)
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
        let failure: () -> Void = { [weak self, weak chunk] in
            Task { @MainActor in
                guard let self, let chunk, !chunk.captureEnded else { return }
                chunk.failed = true; chunk.stopRequested = true
                if source == .microphone { self.micFailed = true; self.stop() }
                else { self.systemFailed = true }
            }
        }
        chunk.worker = Task {
            do {
                for await data in stream {
                    chunk.admittedBytes += data.count
                    if let cloud = chunk.cloud { try await cloud.sendAudio(data) }
                    else if let local = chunk.local {
                        try local.appendPCM16(data)
                        chunk.localProcessedBytes += data.count
                    }
                }
                guard integrity.droppedChunks == 0 else { throw VoiceController.AppError.audioDropped }
                guard chunk.admittedBytes > 0 else { return "" }
                if let cloud = chunk.cloud { try await cloud.endAudio(); return try await cloud.awaitFinal() }
                return try await chunk.local?.endAudioAndAwaitFinal() ?? ""
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
                try await mic.start(onAudio: audio, onDeviceChanged: failure)
            } catch {
                if !(error is CancellationError) { microphoneRecoveryMessage = mic.recoveryDisposition.message }
                throw error
            }
            chunk.startedAt = ProcessInfo.processInfo.systemUptime - Double(mic.totalPCMBytes) / 32_000
        } else {
            let system = SystemAudioCapture(onAudio: audio, onFailure: failure)
            chunk.system = system
            try await system.start()
        }
        try Task.checkCancellation()
        if stopping { chunk.stopRequested = true }
        let deadline = chunk.startedAt + (engine == .local ? 50.0 : 480.0)
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
