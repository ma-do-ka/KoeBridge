#if os(macOS)
import AppKit
import AVFoundation
import Speech
import SwiftUI
import KoeBridgeCore

enum RecognitionMode: String, CaseIterable, Identifiable {
    case gemini, local
    var id: String { rawValue }
    var label: String { self == .gemini ? "Gemini 3.5 Transcribe Live" : "Apple オンデバイス（無料）" }
    /// Human-readable picker label only: keep persisted engine identifiers and history names unchanged.
    var settingsLabel: String { self == .gemini ? "Gemini API（オンライン認識）" : "Apple（Mac内で認識・無料）" }
}

/// All mutable resources belong to one utterance, not to the UI singleton.
/// A completed recording can therefore finalize while another is capturing.
@MainActor private final class DictationTake {
    let id = UUID()
    let requestedAt = Date()
    let preferred: RecognitionMode
    let smart: Bool
    let japaneseHint: Bool
    let vocabulary: [String]
    let shouldPaste: Bool
    var usedMode: String
    var target: InsertionTarget?
    var targetCaptureReason = "not_attempted"
    var mic: MicrophoneCapture?
    var continuation: AsyncStream<Data>.Continuation?
    var worker: Task<Void, Never>?
    var permissionTask: Task<Void, Never>?
    var recordingTimeout: Task<Void, Never>?
    var finalizationTimeout: Task<Void, Never>?
    var cloud: GeminiLiveConnection?
    var local: AppleLocalTranscriber?
    var audioIntegrity = AudioIntegrityState()
    var audioBackup = Data()
    var geminiAttempted = false
    var appleAttempted = false
    var fellBackToApple = false
    var geminiStartedAt: Date?
    var appleStartedAt: Date?
    var appleAudioBytes = 0
    var successfulEngine: RecognitionMode?
    var partialText = ""
    var startedAt: Date?
    var stoppingAt: Date?
    var firstPreviewAt: Date?
    var finished = false
    var automaticDeliverySuppressed = false

    init(preferred: RecognitionMode, smart: Bool, japaneseHint: Bool,
         vocabulary: [String], shouldPaste: Bool) {
        self.preferred = preferred
        self.smart = smart
        self.japaneseHint = japaneseHint
        self.vocabulary = vocabulary
        self.shouldPaste = shouldPaste
        self.usedMode = preferred.label
    }

    var recoverableText: String {
        let remote = cloud?.assembler.recoveryText ?? ""
        if !remote.isEmpty { return remote }
        let offline = local?.transcript ?? ""
        return offline.isEmpty ? partialText : offline
    }

    func releaseResources() {
        permissionTask?.cancel()
        recordingTimeout?.cancel()
        finalizationTimeout?.cancel()
        worker?.cancel()
        // A capture may still be preparing; late callbacks are gated by
        // 'finished', and the original startup task releases its own mic.
        mic?.stop { _ in }
        mic = nil
        continuation?.finish()
        continuation = nil
        cloud?.cancel()
        cloud = nil
        local?.cancel()
        local = nil
        audioBackup.removeAll(keepingCapacity: false)
    }
}

@MainActor final class VoiceController: ObservableObject {
    static let shared = VoiceController()
    typealias Phase = VoiceSessionPhase
    @Published private(set) var phase: Phase = .idle
    @Published var status = "待機中"
    @Published var previewText = ""
    @Published var isRecording = false
    @Published private(set) var overlayFeedback: OverlayFeedback = .hidden
    @Published private(set) var lastStartupSeconds: TimeInterval?
    @Published private(set) var lastStopToInputSeconds: TimeInterval?
    @Published var requestedMode: RecognitionMode {
        didSet { UserDefaults.standard.set(requestedMode.rawValue, forKey: "engine") }
    }
    @Published var smartFormatting: Bool {
        didSet { UserDefaults.standard.set(smartFormatting, forKey: "smart") }
    }
    @Published var japaneseHint: Bool {
        didSet { UserDefaults.standard.set(japaneseHint, forKey: "japanese") }
    }
    @Published var automaticPaste: Bool {
        didSet { UserDefaults.standard.set(automaticPaste, forKey: "autoPaste") }
    }
    @Published var vocabulary: String {
        didSet { UserDefaults.standard.set(vocabulary, forKey: "vocabulary") }
    }
    @Published private(set) var lastMetrics = ""
    @Published private(set) var usedMode = ""
    @Published private(set) var history: [TranscriptRecord] = []
    @Published private(set) var historyProblem = ""
    @Published private(set) var monitorEvents: [EngineUsageSample] = []
    @Published private(set) var monitorTokens: [GeminiTokenSample] = []
    @Published private(set) var monitorProblem = ""
    @Published private(set) var shortcutChoice: RecordingShortcut = .controlOptionSpace
    @Published private(set) var shortcutProblem = ""
    var onShortcutChange: ((RecordingShortcut) -> Bool)?
    var onShortcutRearm: ((RecordingShortcut) -> Bool)?
    var onShowPreview: (() -> Void)?
    var onHidePreview: (() -> Void)?
    var onShowHistory: (() -> Void)?
    var onShowPermissions: (() -> Void)?

    private var archive: RecentTranscriptArchive?
    private var usageArchive: UsageMonitorArchive?
    private var active: DictationTake?
    private var inFlight: [UUID: DictationTake] = [:]
    private var finished = OrderedResultBuffer<Completion>(maximumPending: 8)
    private var localRecoveryBusy = false
    private var overlayOwner: UUID?
    private var overlayDismissal: Task<Void, Never>?

    private struct Completion {
        let text: String?
        let reason: String?
        let partial: String
        let noInput: Bool
    }

    private init() {
        let d = UserDefaults.standard
        requestedMode = RecognitionMode(rawValue: d.string(forKey: "engine") ?? "gemini") ?? .gemini
        smartFormatting = d.bool(forKey: "smart")
        japaneseHint = d.object(forKey: "japanese") == nil ? true : d.bool(forKey: "japanese")
        automaticPaste = d.object(forKey: "autoPaste") == nil ? true : d.bool(forKey: "autoPaste")
        vocabulary = d.string(forKey: "vocabulary") ?? "GitHub\nn8n\nPython\nDeepSeek\nGemini\nCodex"
        shortcutChoice = RecordingShortcut(rawValue: d.string(forKey: "recordingShortcut") ?? "") ?? .controlOptionSpace
        do {
            let saved = try RecentTranscriptArchive()
            archive = saved
            history = saved.entries
        } catch {
            historyProblem = "履歴を読み込めません（元のファイルは保持しています）：\(error.localizedDescription)"
        }
        do {
            let stored = try UsageMonitorArchive()
            usageArchive = stored
            monitorEvents = stored.engineEvents
            monitorTokens = stored.tokenEvents
        } catch {
            monitorProblem = "利用統計を読み込めません。元のデータは保持しています：\(error.localizedDescription)"
        }
    }

    var hasKey: Bool { KeychainStore.load() != nil }
    var busy: Bool { active != nil }

    /// Recording STOP frees the shortcut synchronously. Recognition and
    /// paste continue on the take that just ended; the next F8 can start NOW.
    func toggle() {
        switch phase {
        case .idle: beginRecording()
        case .preparing:
            DiagnosticLog.record("shortcut cancel preparing; no deferred restart")
            discard()
        case .recording: stop()
        case .finalizing:
            // No take owns this global phase in v0.3.9. Defensive recovery.
            phase = .idle
            beginRecording()
        }
    }

    private func beginRecording() {
        guard active == nil, phase == .idle else { return }
        guard finished.canBegin else {
            status = "確定待ちが8件あります。前の認識が終わるまで追加できません（録音内容は履歴へ保存）"
            DiagnosticLog.record("shortcut capacity reached; pending=\(finished.count)")
            return
        }
        let take = DictationTake(preferred: requestedMode,
                                smart: smartFormatting,
                                japaneseHint: japaneseHint,
                                vocabulary: vocabulary.components(separatedBy: .newlines),
                                shouldPaste: automaticPaste)
        guard finished.begin(take.id) else { return }
        inFlight[take.id] = take
        active = take
        overlayDismissal?.cancel()
        overlayDismissal = nil
        overlayOwner = take.id
        overlayFeedback = .preparing
        phase = .preparing
        previewText = ""
        lastMetrics = ""
        usedMode = take.usedMode
        status = "マイクを準備しています…"
        DiagnosticLog.record("session requested; id=\(take.id.uuidString.prefix(8)); pending=\(finished.count)")
        let focusStartedAt = Date()
        let targetResult = InsertionTarget.capture() // BEFORE the overlay is shown
        take.target = targetResult.target
        take.targetCaptureReason = targetResult.reason
        DiagnosticLog.record("session preparing; accessibility=\(TextInsertion.isTrusted); target captured=\(take.target != nil); reason=\(targetResult.reason); duration=\(String(format: "%.2f", Date().timeIntervalSince(focusStartedAt)))s")
        onShowPreview?()
        take.permissionTask = Task { [weak self, weak take] in
            do { try await Task.sleep(for: .seconds(40)) } catch { return }
            guard let self, let take, self.active === take, self.phase == .preparing else { return }
            self.resolve(take, text: nil, reason: "マイクの準備が40秒以内に終わりませんでした")
        }
        Task { [weak self, weak take] in
            guard let self, let take else { return }
            await self.startPrepared(take)
        }
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func startPrepared(_ take: DictationTake) async {
        guard active === take, !take.finished else { return }
        let beforePermission = Date()
        guard await microphoneAllowed() else {
            if active === take { resolve(take, text: nil, reason: "マイクへのアクセスが許可されていません") }
            return
        }
        DiagnosticLog.record("mic permission ready; elapsed=\(String(format: "%.3f", Date().timeIntervalSince(beforePermission)))s")
        guard active === take, phase == .preparing, !take.finished else { return }

        let (stream, continuation) = AsyncStream<Data>.makeStream(
            of: Data.self, bufferingPolicy: .bufferingOldest(480))
        take.continuation = continuation
        take.worker = Task { [weak self, weak take] in
            guard let self, let take else { return }
            await self.transmit(stream, take: take)
        }
        let capture = MicrophoneCapture()
        let integrity = take.audioIntegrity // thread-safe; do not cross actor isolation in audio callback
        do {
            try await capture.start(onAudio: { [weak self, weak take] data in
                let delivery = continuation.yield(data)
                if case .dropped = delivery {
                    integrity.markDropped()
                    Task { @MainActor [weak self, weak take] in
                        guard let self, let take, !take.finished else { return }
                        self.resolve(take, text: nil, reason: "音声送信キューから音声が欠落しました")
                    }
                }
            }, onDeviceChanged: { [weak self, weak take] in
                Task { @MainActor [weak self, weak take] in
                    guard let self, let take, !take.finished,
                          self.active === take, self.phase == .recording else { return }
                    self.resolve(take, text: nil, reason: "録音中にマイク構成が変わりました")
                }
            })
            guard active === take, phase == .preparing, !take.finished else {
                capture.stop { _ in }
                continuation.finish()
                return
            }
            take.mic = capture
            take.startedAt = Date()
            lastStartupSeconds = take.startedAt?.timeIntervalSince(take.requestedAt)
            phase = .recording
            isRecording = true
            if overlayOwner == take.id { overlayFeedback = .recording }
            take.permissionTask?.cancel()
            take.permissionTask = nil
            if let t = capture.startTimings {
                DiagnosticLog.record("mic startup; total=\(String(format: "%.3f", t.total))s prepare=\(String(format: "%.3f", t.microphonePreparation))s engineStart=\(String(format: "%.3f", t.engineStart))s")
            }
            DiagnosticLog.record("session recording; recognizer=pending; pending=\(finished.count)")
            status = "録音中。\(shortcutChoice.label) でもう一度押すと確定"
            let maxSeconds = take.preferred == .gemini ? 480 : 50
            take.recordingTimeout = Task { [weak self, weak take] in
                do { try await Task.sleep(for: .seconds(maxSeconds)) } catch { return }
                guard let self, let take, self.active === take, self.phase == .recording else { return }
                self.stop()
            }
        } catch {
            if active === take, !take.finished {
                resolve(take, text: nil, reason: "マイク開始失敗: \(error.localizedDescription)")
            }
        }
    }

    private func prepareRecognizer(_ take: DictationTake) async throws -> RecognitionMode {
        var actual = take.preferred
        if actual == .gemini {
            if let key = KeychainStore.load() {
                let candidate = GeminiLiveConnection()
                take.geminiAttempted = true
                take.geminiStartedAt = Date()
                take.cloud = candidate
                do {
                    try await candidate.connect(apiKey: key,
                                                vocabulary: take.vocabulary,
                                                smart: take.smart,
                                                japaneseHint: take.japaneseHint)
                    guard !take.finished, !Task.isCancelled else {
                        candidate.cancel()
                        throw CancellationError()
                    }
                    take.cloud = candidate
                    candidate.onEvent = { [weak self, weak take, weak candidate] event in
                        guard let self, let take, !take.finished else { return }
                        switch event {
                        case .interim, .final:
                            take.partialText = candidate?.assembler.displayText ?? ""
                            if take.firstPreviewAt == nil, !take.partialText.isEmpty {
                                take.firstPreviewAt = Date()
                            }
                            if self.active === take { self.previewText = take.partialText }
                        case .error:
                            DiagnosticLog.record("gemini receiver failure during take")
                        default: break
                        }
                    }
                } catch is CancellationError {
                    candidate.cancel()
                    throw CancellationError()
                } catch {
                    candidate.cancel()
                    DiagnosticLog.record("gemini setup failed; using local for THIS take")
                    take.fellBackToApple = true
                    actual = .local
                }
            } else {
                DiagnosticLog.record("gemini key unavailable; using local for THIS take")
                take.fellBackToApple = true
                actual = .local
            }
        }
        if actual == .local {
            let recognizer = AppleLocalTranscriber()
            take.appleAttempted = true
            take.appleStartedAt = Date()
            try await recognizer.start()
            guard !take.finished, !Task.isCancelled else {
                recognizer.cancel()
                throw CancellationError()
            }
            take.local = recognizer
            recognizer.onUpdate = { [weak self, weak take] text in
                guard let self, let take, !take.finished else { return }
                take.partialText = text
                if take.firstPreviewAt == nil, !text.isEmpty { take.firstPreviewAt = Date() }
                if self.active === take { self.previewText = text }
            }
        }
        guard !take.finished, !Task.isCancelled else { throw CancellationError() }
        take.usedMode = actual.label
        if active === take {
            usedMode = take.usedMode
            if phase == .recording { status = "録音中。\(shortcutChoice.label) でもう一度押すと確定" }
        }
        if let start = take.startedAt {
            DiagnosticLog.record("recognizer ready; mode=\(actual.rawValue); sinceMic=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
        } else {
            DiagnosticLog.record("recognizer ready during microphone initialization; mode=\(actual.rawValue)")
        }
        return actual
    }

    /// STOP transitions the UI to idle before any network await or slow
    /// microphone teardown. Each recording's worker owns its own ASR state.
    func stop() {
        guard phase == .recording, let take = active else { return }
        active = nil
        phase = .idle
        isRecording = false
        let stoppedAt = Date()
        take.stoppingAt = stoppedAt
        take.recordingTimeout?.cancel()
        // Rapid stop does not imply a transcription failure. Wait for the
        // microphone's final PCM/peak measurement before classifying a quiet tap.
        // Real speech still enters the normal finalization path.
        let recordedSeconds = take.startedAt.map {
            stoppedAt.timeIntervalSince($0)
        } ?? .infinity
        let quickExitCandidate = QuickNoInputPolicy.mayBeQuickExit(seconds: recordedSeconds)
        if overlayOwner == take.id {
            overlayFeedback = quickExitCandidate ? .ending : .processing
            previewText = ""
        }
        status = quickExitCandidate ? "録音を終了しています…" :
            "文字起こしを確定中。録音キーでもう一度押すと次の録音を開始できます"
        DiagnosticLog.record("session stopped; UI idle immediately; background finalization; pending=\(finished.count)")
        take.finalizationTimeout = Task { [weak self, weak take] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, let take, !take.finished else { return }
            DiagnosticLog.record("background finalization watchdog; id=\(take.id.uuidString.prefix(8))")
            self.resolve(take, text: nil, reason: "認識処理が15秒以内に完了しませんでした")
        }
        let capture = take.mic
        take.mic = nil
        if let capture {
            capture.stop { [weak self, weak take] losses in
                Task { @MainActor [weak self, weak take] in
                    guard let self, let take, !take.finished else { return }
                    let pcmBytes = capture.totalPCMBytes
                    let seconds = Double(pcmBytes) / 32_000
                    let peak = capture.sessionPeakAmplitude
                    DiagnosticLog.record("mic stopped; pcmBytes=\(pcmBytes) audioSeconds=\(String(format: "%.2f", seconds)) peak=\(String(format: "%.4f", peak)) losses=\(losses)")
                    let lostAudio = losses > 0 || take.audioIntegrity.droppedChunks > 0
                    // Audio-loss errors and real transcribed text are never
                    // hidden by the accidental-tap UX.
                    if lostAudio {
                        self.resolve(take, text: nil, reason: "マイクの音声チャンクが欠落しました")
                    } else if QuickNoInputPolicy.shouldSkipRecognition(
                        seconds: seconds, pcmBytes: pcmBytes, peak: peak,
                        hasText: !take.recoverableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        audioDropped: lostAudio
                    ) {
                        self.resolve(take, text: nil, reason: "音声入力なし", noInput: true)
                    } else if !AudioDurationPolicy.hasEnoughAudio(pcmBytes: pcmBytes) {
                        self.resolve(take, text: nil, reason: "録音が短すぎます（0.1秒未満）")
                    } else {
                        if self.overlayOwner == take.id && self.overlayFeedback == .ending {
                            self.overlayFeedback = .processing
                        }
                        take.continuation?.finish()
                    }
                }
            }
        } else {
            take.continuation?.finish()
        }
    }

    /// A failed cloud transcription with NO server text may be retried with
    /// Apple's on-device recognizer using the SAME audio data. This does not
    /// block the next recording; the result still waits for its delivery slot.
    private func retryLocally(_ take: DictationTake) async throws -> String {
        guard !take.audioBackup.isEmpty else { throw AppError.connectionLost }
        // Only one fallback recognizer at a time. A wave of failed Gemini
        // sessions must not launch eight heavyweight local ASR tasks at once.
        let waitBegan = Date()
        while localRecoveryBusy {
            try Task.checkCancellation()
            guard !take.finished, Date().timeIntervalSince(waitBegan) < 7 else {
                throw AppError.localRecoveryBusy
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        localRecoveryBusy = true
        defer { localRecoveryBusy = false }
        // Never bring up a permission prompt during a following dictation.
        // Recovery is only allowed when Speech Recognition was authorized.
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            DiagnosticLog.record("local recovery unavailable; speech permission not granted")
            throw AppleLocalTranscriber.LocalError.permission
        }
        let local = AppleLocalTranscriber()
        take.local = local
        take.fellBackToApple = true
        take.appleAttempted = true
        take.appleStartedAt = Date()
        try await local.start()
        try Task.checkCancellation()
        let length = take.audioBackup.count
        var offset = 0
        while offset < length {
            try Task.checkCancellation()
            let end = min(offset + 3_200, length)
            try local.appendPCM16(take.audioBackup.subdata(in: offset..<end))
            take.appleAudioBytes += end - offset
            offset = end
        }
        let result = try await local.endAudioAndAwaitFinal()
        take.usedMode = "Appleオンデバイス（Gemini失敗時の救済）"
        DiagnosticLog.record("local recovery succeeded; chars=\(result.count)")
        return result
    }

    private func transmit(_ stream: AsyncStream<Data>, take: DictationTake) async {
        do {
            let mode = try await prepareRecognizer(take)
            for await chunk in stream {
                guard !take.finished, !Task.isCancelled else { return }
                // 16kHz PCM is at most ~15 MB for a complete eight-minute take.
                // Keep it only in RAM for on-device recovery, never in history.
                take.audioBackup.append(chunk)
                if mode == .gemini {
                    guard let remote = take.cloud else { throw AppError.connectionLost }
                    try await remote.sendAudio(chunk)
                } else {
                    guard let recognizer = take.local else { throw AppError.connectionLost }
                    try recognizer.appendPCM16(chunk)
                    take.appleAudioBytes += chunk.count
                }
            }
            guard !take.finished, !Task.isCancelled else { return }
            guard take.audioIntegrity.droppedChunks == 0 else { throw AppError.audioDropped }
            let result: String
            if mode == .gemini {
                guard let remote = take.cloud else { throw AppError.connectionLost }
                try await remote.endAudio()
                do {
                    result = try await remote.awaitFinal()
                    take.successfulEngine = .gemini
                } catch {
                    // No transcript despite valid audio: local ASR may recover
                    // the text. A failed local attempt stays an explicit error.
                    DiagnosticLog.record("gemini final failed; attempting Apple on-device recovery")
                    result = try await retryLocally(take)
                    take.successfulEngine = .local
                }
            } else {
                guard let recognizer = take.local else { throw AppError.connectionLost }
                result = try await recognizer.endAudioAndAwaitFinal()
                take.successfulEngine = .local
            }
            guard !take.finished, !Task.isCancelled else { return }
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppleLocalTranscriber.LocalError.empty(nil)
            }
            resolve(take, text: result, reason: nil)
        } catch {
            guard !take.finished, !Task.isCancelled else { return }
            DiagnosticLog.record("recognition failure; category=\(Self.failureCategory(error))")
            resolve(take, text: nil, reason: "認識失敗: \(error.localizedDescription)")
        }
    }

    /// Finish only this take. This MUST NOT reset a newer active recording.
    private func resolve(_ take: DictationTake, text: String?, reason: String?,
                         noInput: Bool = false) {
        guard !take.finished else { return }
        let partial = take.recoverableText
        take.finished = true
        if let start = take.startedAt, let stop = take.stoppingAt, text != nil {
            let first = take.firstPreviewAt.map { String(format: "%.2f", $0.timeIntervalSince(start)) } ?? "未取得"
            lastMetrics = "初回表示 \(first)秒 / 停止→確定 \(String(format: "%.2f", Date().timeIntervalSince(stop)))秒"
        }
        if active === take {
            active = nil
            phase = .idle
            isRecording = false
            // Preparing was cancelled or capture failed; no pending processing.
            if overlayOwner == take.id && !noInput { hideOverlay() }
            previewText = ""
        }
        let accepted = finished.finish(take.id, result: Completion(
            text: text, reason: reason, partial: partial, noInput: noInput))
        DiagnosticLog.record("session resolved; success=\(text?.isEmpty == false) accepted=\(accepted) noInput=\(noInput) pending=\(finished.count)")
        // Show a brief, neutral acknowledgement immediately, even if an
        // older take is still finalizing in the ordered delivery buffer.
        if noInput { showCompletionFeedback(.noInput, for: take.id) }
        // Safety first: persist recoverable text before posting input events.
        // Usage telemetry is secondary and must not delay those key events.
        deliverOrderedResults()
        if noInput && active == nil && overlayOwner == take.id { status = "音声入力なし" }
        recordUsage(take, succeeded: text?.isEmpty == false,
                    cancelled: noInput || reason == "録音をキャンセルしました")
        take.releaseResources()
    }

    /// Called exactly once per take, including failures and fallback.
    /// No transcript, audio, credentials, or platform error messages are stored.
    private func recordUsage(_ take: DictationTake, succeeded: Bool, cancelled: Bool) {
        let fallbackTime = take.startedAt ?? Date()
        func outcome(for mode: RecognitionMode) -> UsageOutcome {
            if succeeded && take.successfulEngine == mode { return .success }
            return cancelled ? .cancelled : .failure
        }
        var rows: [EngineUsageSample] = []
        if take.geminiAttempted {
            rows.append(EngineUsageSample(
                at: take.geminiStartedAt ?? fallbackTime, engine: .gemini,
                audioSeconds: Double(take.cloud?.sentAudioBytes ?? 0) / 32_000,
                outcome: outcome(for: .gemini)))
        }
        if take.appleAttempted {
            rows.append(EngineUsageSample(
                at: take.appleStartedAt ?? fallbackTime, engine: .apple,
                audioSeconds: Double(take.appleAudioBytes) / 32_000,
                outcome: outcome(for: .local), fallback: take.fellBackToApple))
        }
        let tokens = take.cloud?.tokenSamples ?? []
        guard !rows.isEmpty || !tokens.isEmpty else { return }
        if var store = usageArchive {
            do {
                try store.append(engineEvents: rows, tokenEvents: tokens)
                usageArchive = store
                monitorEvents = store.engineEvents
                monitorTokens = store.tokenEvents
                monitorProblem = ""
            } catch {
                monitorProblem = "利用統計を保存できません。元のファイルは保持しています：\(error.localizedDescription)"
                monitorEvents.append(contentsOf: rows)
                monitorTokens.append(contentsOf: tokens)
            }
        } else {
            monitorEvents.append(contentsOf: rows)
            monitorTokens.append(contentsOf: tokens)
        }
        if monitorEvents.count > UsageMonitorArchive.maximumEngineEvents {
            monitorEvents = Array(monitorEvents.suffix(UsageMonitorArchive.maximumEngineEvents))
        }
        if monitorTokens.count > UsageMonitorArchive.maximumTokenEvents {
            monitorTokens = Array(monitorTokens.suffix(UsageMonitorArchive.maximumTokenEvents))
        }
    }

    private func deliverOrderedResults() {
        for (id, result) in finished.drain() {
            guard let take = inFlight.removeValue(forKey: id) else { continue }
            if result.noInput {
                // No paste, no error toast, no transcript history. The overlay
                // was already acknowledged by resolve() for this take only.
                DiagnosticLog.record("empty rapid recording discarded; id=\(id.uuidString.prefix(8))")
                continue
            }
            if let text = result.text, !text.isEmpty {
                let recordID = remember(text, isPartial: false, delivery: .pending, engine: take.usedMode)
                let outcome: TranscriptRecord.Delivery
                if take.automaticDeliverySuppressed {
                    outcome = .blockedFocus
                } else if take.shouldPaste {
                    switch TextInsertion.deliver(text, to: take.target) {
                    case .inserted:
                        outcome = .attemptedUnconfirmed
                        DiagnosticLog.record("direct typing submitted; id=\(id.uuidString.prefix(8)); not verified; clipboard untouched")
                    case .focusChanged:
                        outcome = .blockedFocus
                        DiagnosticLog.record("delivery blocked: focus_changed_or_unavailable; targetCapture=\(take.targetCaptureReason)")
                    case .notPermitted:
                        outcome = .missingPermission
                        DiagnosticLog.record("delivery blocked: accessibility missing")
                    case .eventPermissionMissing:
                        outcome = .missingPermission
                        DiagnosticLog.record("delivery blocked: post_event_permission_missing")
                    case .partiallySubmitted:
                        outcome = .partiallyDirect
                        DiagnosticLog.record("direct typing interrupted; partial characters may have entered; history available")
                    case .eventUnavailable:
                        outcome = .insertionUnavailable
                        DiagnosticLog.record("direct typing event unavailable; clipboard untouched")
                    }
                } else {
                    outcome = .automaticPasteDisabled
                }
                if let recordID { updateRemembered(recordID, delivery: outcome) }
                if outcome == .attemptedUnconfirmed, let stoppedAt = take.stoppingAt {
                    lastStopToInputSeconds = Date().timeIntervalSince(stoppedAt)
                }
                showCompletionFeedback(outcome == .attemptedUnconfirmed ? .sent : .saved, for: id)
                if active == nil {
                    if outcome == .attemptedUnconfirmed {
                        status = "直接入力を送信しました（受理は未確認）。履歴に保存済み"
                    } else if take.automaticDeliverySuppressed {
                        status = "システム中断により自動入力しませんでした。文字起こしは履歴に保存済み"
                    } else if take.targetCaptureReason == "koebridge_window_is_frontmost" {
                        status = "設定画面を閉じて入力欄をクリックし、再度録音してください。認識結果は履歴に保存済み"
                    } else {
                        status = "自動入力できませんでした（入力先=\(take.targetCaptureReason)）。履歴に保存済み"
                    }
                }
            } else {
                let recovered = result.partial.trimmingCharacters(in: .whitespacesAndNewlines)
                if !recovered.isEmpty {
                    _ = remember(recovered, isPartial: true, delivery: .recognitionInterrupted, engine: take.usedMode)
                }
                DiagnosticLog.record("session failure; id=\(id.uuidString.prefix(8)); reason=\(Self.safeFailureCode(result.reason))")
                showCompletionFeedback(.failed, for: id)
                if active == nil { status = result.reason ?? "文字起こしに失敗しました（履歴を確認）" }
            }
        }
    }

    /// Feedback never claims that the receiving app accepted synthetic key events.
    /// Completion from an older take cannot replace a newer recording overlay.
    private func showCompletionFeedback(_ feedback: OverlayFeedback, for id: UUID) {
        guard OverlayFeedback.mayUpdate(owner: overlayOwner, resolved: id,
                                        newRecordingActive: active != nil) else { return }
        overlayFeedback = feedback
        overlayDismissal?.cancel()
        overlayDismissal = Task { [weak self] in
            let hold: Int = feedback == .noInput ? 330 : (feedback == .failed ? 1_000 : 520)
            do { try await Task.sleep(for: .milliseconds(hold)) } catch { return }
            guard let self, self.overlayOwner == id, self.active == nil else { return }
            self.hideOverlay()
        }
    }

    private func hideOverlay() {
        overlayDismissal?.cancel()
        overlayDismissal = nil
        overlayOwner = nil
        overlayFeedback = .hidden
        onHidePreview?()
    }

    private static func safeFailureCode(_ reason: String?) -> String {
        // Failure strings can carry a platform error; never log user speech.
        reason == nil ? "none" : "recognition_or_capture"
    }

    func discard() {
        guard let take = active else { return }
        DiagnosticLog.record("session discarded by user")
        resolve(take, text: nil, reason: "音声入力なし", noInput: true)
    }

    /// Never paste delayed transcripts after sleep, user switch or shutdown.
    func interruptForSystemEvent(_ reason: String) {
        let outstanding = Array(inFlight.values)
        // Also suppress already-finalized results waiting behind an older take.
        // Mark ALL before resolving any: resolve() drains the completion queue.
        for take in outstanding { take.automaticDeliverySuppressed = true }
        // Mark failed without performing automatic paste or blocking on ASR.
        for take in outstanding where !take.finished {
            resolve(take, text: nil, reason: reason)
        }
        hideOverlay()
        status = reason
    }

    private static func failureCategory(_ error: Error) -> String {
        if let e = error as? GeminiLiveConnection.ConnectionError {
            switch e {
            case .badURL: return "gemini.bad_url"
            case .setup: return "gemini.setup"
            case .disconnected: return "gemini.disconnected"
            case .noFinal: return "gemini.no_final"
            case .stalled: return "gemini.stalled"
            case .finalizationTimeout: return "gemini.finalization_timeout"
            }
        }
        if let e = error as? AppleLocalTranscriber.LocalError {
            switch e {
            case .permission: return "apple.permission"
            case .unavailable: return "apple.unavailable"
            case .empty: return "apple.empty"
            case .finalizationTimeout: return "apple.finalization_timeout"
            case .recognitionFailure: return "apple.recognition_failure"
            }
        }
        if error is CancellationError { return "cancelled" }
        return "other"
    }

    func selectShortcut(_ choice: RecordingShortcut) {
        guard choice != shortcutChoice || !shortcutProblem.isEmpty else { return }
        guard onShortcutChange?(choice) == true else {
            shortcutProblem = "このショートカットは登録できません（macOS側の割当・競合の可能性）。現在のキーを維持します"
            return
        }
        shortcutChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "recordingShortcut")
        shortcutProblem = ""
    }

    func shortcutRegistrationFailed() {
        shortcutProblem = "ショートカットを登録できません。権限・競合を確認してください"
        status = "録音キー未登録。設定から再登録してください"
    }

    func retryShortcutRegistration() {
        if onShortcutRearm?(shortcutChoice) == true {
            shortcutProblem = ""
            status = "録音キーを登録しました"
            DiagnosticLog.record("shortcut registration retried successfully")
        } else {
            shortcutRegistrationFailed()
            DiagnosticLog.record("shortcut registration retry failed")
        }
    }

    @discardableResult private func remember(_ text: String, isPartial: Bool,
                                              delivery: TranscriptRecord.Delivery,
                                              engine: String? = nil) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let record = TranscriptRecord(engine: engine ?? (usedMode.isEmpty ? requestedMode.label : usedMode),
                                      text: trimmed, isPartial: isPartial, delivery: delivery)
        guard var store = archive else {
            // Recovery within the running app even if an old archive is corrupt.
            history.insert(record, at: 0)
            history = Array(history.prefix(RecentTranscriptArchive.maximumRecords))
            return record.id
        }
        do {
            try store.insert(record)
            historyProblem = ""
        } catch {
            historyProblem = "履歴をディスクへ保存できません（起動中のみ保持）：\(error.localizedDescription)"
        }
        archive = store
        history = store.entries
        return record.id
    }

    private func updateRemembered(_ id: UUID, delivery: TranscriptRecord.Delivery) {
        guard var store = archive else {
            if let index = history.firstIndex(where: { $0.id == id }) {
                history[index].delivery = delivery
            }
            return
        }
        do { try store.updateDelivery(id: id, to: delivery) }
        catch { historyProblem = "履歴の状態更新に失敗しました：\(error.localizedDescription)" }
        archive = store
        history = store.entries
    }

    func copyRecord(_ record: TranscriptRecord) { TextInsertion.copy(record.text) }
    func deleteRecord(_ id: UUID) {
        guard var store = archive else {
            history.removeAll { $0.id == id }
            return
        }
        do { try store.delete(id: id) }
        catch { historyProblem = "履歴の削除に失敗しました：\(error.localizedDescription)" }
        archive = store
        history = store.entries
    }
    func clearHistory() {
        guard var store = archive else { history = []; return }
        do { try store.deleteAll() }
        catch { historyProblem = "履歴の全削除に失敗しました：\(error.localizedDescription)" }
        archive = store
        history = store.entries
    }

    func clearUsageMonitor() {
        guard var store = usageArchive else {
            monitorProblem = "統計ファイルを読み込めないため、既存ファイルを安全に削除できません"
            return
        }
        do {
            try store.deleteAll()
            usageArchive = store
            monitorEvents = []
            monitorTokens = []
            monitorProblem = ""
        } catch {
            monitorProblem = "利用統計を削除できません：\(error.localizedDescription)"
        }
    }

    func saveKey(_ key: String) throws {
        try KeychainStore.save(key)
        objectWillChange.send()
    }
    func deleteKey() {
        KeychainStore.delete()
        objectWillChange.send()
    }
    func copyLastText() { TextInsertion.copy(history.first?.text ?? previewText) }

    enum AppError: Error, LocalizedError {
        case noKey, connectionLost, audioDropped, localRecoveryBusy
        var errorDescription: String? {
            switch self {
            case .noKey: return "Gemini APIキーが未登録です。設定画面でキーチェーンへ保存してください"
            case .connectionLost: return "音声認識エンジンが終了しました"
            case .audioDropped: return "音声チャンクが欠落したため認識結果を破棄しました"
            case .localRecoveryBusy: return "別の録音のローカル復旧処理が実行中です。多重起動を避けるため認識を中止しました"
            }
        }
    }
}
#endif
