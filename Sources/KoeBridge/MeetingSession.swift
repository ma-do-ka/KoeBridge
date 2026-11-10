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
    private var completed = false
    private var recognitionProblems: [String] = []
    var onStatus: ((String) -> Void)?
    var onFinished: ((String, Bool) -> Void)?

    @MainActor private final class Chunk {
        var mic: MicrophoneCapture?
        var system: SystemAudioCapture?
        var local: LocalTranscribing?
        var cloud: GeminiLiveConnection?
        var stopRequested = false
        var captureEnded = false
        var captureDrain: Task<Void, Never>?
        var failed = false
        var startedAt = ProcessInfo.processInfo.systemUptime
        var admittedBytes = 0
        let emittedAudio = MeetingAudioCount()
        var timer: Task<Void, Never>?
        var continuation: AsyncStream<Data>.Continuation?
        var worker: Task<String, Error>?
        let integrity = AudioIntegrityState()
        var finalText: String?
        var partial: String { finalText ?? local?.transcript ?? cloud?.assembler.recoveryText ?? "" }
    }

    init(engine: RecognitionMode, vocabulary: [String], style: TranscriptionStyle,
         japaneseHint: Bool, apiKey: String?, microphoneUID: String) {
        self.engine = engine; self.vocabulary = vocabulary; self.style = style
        self.japaneseHint = japaneseHint; self.apiKey = apiKey; self.microphoneUID = microphoneUID
    }

    func start() {
        guard tasks.isEmpty, !completed else { return }
        if stopping { finishMeeting(); return }
        tasks = [Task { await self.run(.microphone) }, Task { await self.run(.system) }]
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

    func stop() {
        guard !stopping else { return }
        stopping = true
        for (source, chunk) in chunks {
            chunk.stopRequested = true
            // Stop during model download/connection setup must not wait for
            // preparation to finish. Active captures still drain normally.
            if chunk.mic == nil && chunk.system == nil {
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

    private func run(_ source: MeetingTranscript.Source) async {
        while !stopping && !(source == .system && systemFailed) {
            let chunk = Chunk()
            chunks[source] = chunk
            do { try await runChunk(chunk, source: source) }
            catch {
                chunk.failed = true
                if !stopping {
                    recognitionProblems.append("\(source.label)：認識が中断しました（途中結果を保存）")
                    // End this source rather than silently skipping a failed chunk.
                    if source == .microphone { micFailed = true; stop() }
                    else { systemFailed = true }
                }
            }
            chunk.timer?.cancel()
            await endCapture(chunk)
            if chunk.finalText == nil, let worker = chunk.worker { chunk.finalText = try? await worker.value }
            transcript.append(source: source, offset: segmentOffset(chunk, source: source), text: chunk.partial)
            chunk.cloud?.cancel(); chunk.local?.cancel()
            chunks[source] = nil
            if chunk.failed { break }
        }
    }

    private func runChunk(_ chunk: Chunk, source: MeetingTranscript.Source) async throws {
        if engine == .local {
            let local = LocalTranscriberFactory.make(); chunk.local = local
            try await local.start()
        } else {
            guard let apiKey else { throw VoiceController.AppError.noKey }
            let cloud = GeminiLiveConnection(); chunk.cloud = cloud
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
                    else { try chunk.local?.appendPCM16(data) }
                }
                guard chunk.admittedBytes > 0 else { return "" }
                guard integrity.droppedChunks == 0 else { throw VoiceController.AppError.audioDropped }
                if let cloud = chunk.cloud { try await cloud.endAudio(); return try await cloud.awaitFinal() }
                return try await chunk.local?.endAudioAndAwaitFinal() ?? ""
            } catch {
                chunk.stopRequested = true
                throw error
            }
        }
        chunk.startedAt = ProcessInfo.processInfo.systemUptime
        if source == .microphone {
            let mic = MicrophoneCapture(selectedInputUID: microphoneUID); chunk.mic = mic
            try await mic.start(onAudio: audio, onDeviceChanged: failure)
            chunk.startedAt = ProcessInfo.processInfo.systemUptime - Double(mic.totalPCMBytes) / 32_000
        } else {
            let system = SystemAudioCapture(); chunk.system = system
            try await system.start(onAudio: audio, onFailure: failure)
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
            if let mic = chunk.mic {
                let losses = await withCheckedContinuation { done in mic.stop { done.resume(returning: $0) } }
                if losses > 0 { chunk.integrity.markDropped() }
            }
            if let system = chunk.system { await system.stop() }
            chunk.continuation?.finish(); chunk.continuation = nil
        }
        chunk.captureDrain = drain
        await drain.value
    }
}
#endif
