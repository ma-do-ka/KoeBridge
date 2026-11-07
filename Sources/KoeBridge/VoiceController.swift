#if os(macOS)
import AppKit
import AVFoundation
import Speech
import SwiftUI
import KoeBridgeCore

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
    @Published var transcriptionStyle: TranscriptionStyle {
        didSet {
            UserDefaults.standard.set(transcriptionStyle.rawValue, forKey: "transcriptionStyle")
            // Continue maintaining the legacy setting for a safe downgrade.
            UserDefaults.standard.set(transcriptionStyle == .readable, forKey: "smart")
        }
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
    @Published var registeredVocabularyEnabled: Bool {
        didSet { UserDefaults.standard.set(registeredVocabularyEnabled, forKey: "registeredVocabularyEnabled") }
    }
    @Published var topicVocabularyEnabled: Bool {
        didSet { UserDefaults.standard.set(topicVocabularyEnabled, forKey: "topicVocabularyEnabled") }
    }
    @Published var textContextCheckEnabled: Bool {
        didSet { UserDefaults.standard.set(textContextCheckEnabled, forKey: "textContextCheckEnabled") }
    }
    @Published var audioRecheckEnabled: Bool {
        didSet { UserDefaults.standard.set(audioRecheckEnabled, forKey: "audioRecheckEnabled") }
    }
    @Published var audioRecheckPolicy: AudioRecheckPolicy {
        didSet { UserDefaults.standard.set(audioRecheckPolicy.rawValue, forKey: "audioRecheckPolicy") }
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

    private var historyStore: TranscriptHistoryStore {
        didSet {
            history = historyStore.entries
            historyProblem = historyStore.problem
        }
    }
    private var usageStore: UsageMonitorStore {
        didSet {
            monitorEvents = usageStore.engineEvents
            monitorTokens = usageStore.tokenEvents
            monitorProblem = usageStore.problem
        }
    }
    private var active: DictationTake?
    private var inFlight: [UUID: DictationTake] = [:]
    private var finished = OrderedResultBuffer<Completion>(maximumPending: 8)
    private var localRecoveryBusy = false
    private var overlayOwner: UUID?
    private var overlayDismissal: Task<Void, Never>?
    private var deliveryWorker: Task<Void, Never>?
    private var deliveringTakeID: UUID?

    private var transcriptionOptions: TranscriptionOptions {
        TranscriptionOptions(registeredVocabularyEnabled: registeredVocabularyEnabled,
                             topicVocabularyEnabled: topicVocabularyEnabled,
                             textContextCheckEnabled: textContextCheckEnabled,
                             audioRecheckEnabled: audioRecheckEnabled,
                             audioRecheckPolicy: audioRecheckPolicy)
    }

    private struct Completion {
        let text: String?
        let reason: String?
        let partial: String
        let noInput: Bool
    }

    private init() {
        let d = UserDefaults.standard
        requestedMode = RecognitionMode(rawValue: d.string(forKey: "engine") ?? "gemini") ?? .gemini
        transcriptionStyle = TranscriptionStyle.restoring(
            storedStyle: d.string(forKey: "transcriptionStyle"),
            legacySmart: d.bool(forKey: "smart")
        )
        japaneseHint = d.object(forKey: "japanese") == nil ? true : d.bool(forKey: "japanese")
        automaticPaste = d.object(forKey: "autoPaste") == nil ? true : d.bool(forKey: "autoPaste")
        vocabulary = d.string(forKey: "vocabulary") ?? "GitHub\nn8n\nPython\nDeepSeek\nGemini\nCodex"
        let options = TranscriptionOptions.load(
            from: d,
            hasLegacyUsage: FileManager.default.fileExists(atPath: RecentTranscriptArchive.defaultFileURL.path))
        registeredVocabularyEnabled = options.registeredVocabularyEnabled
        topicVocabularyEnabled = options.topicVocabularyEnabled
        textContextCheckEnabled = options.textContextCheckEnabled
        audioRecheckEnabled = options.audioRecheckEnabled
        audioRecheckPolicy = options.audioRecheckPolicy
        shortcutChoice = RecordingShortcut(rawValue: d.string(forKey: "recordingShortcut") ?? "") ?? .controlOptionSpace
        historyStore = TranscriptHistoryStore()
        usageStore = UsageMonitorStore()
        history = historyStore.entries
        historyProblem = historyStore.problem
        monitorEvents = usageStore.engineEvents
        monitorTokens = usageStore.tokenEvents
        monitorProblem = usageStore.problem
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
        guard finished.canBegin, inFlight.count < 8 else {
            status = "確定待ちが8件あります。前の認識が終わるまで追加できません（録音内容は履歴へ保存）"
            DiagnosticLog.record("shortcut capacity reached; pending=\(finished.count)")
            return
        }
        let options = transcriptionOptions
        let selectedVocabulary = AgentVocabulary.terms(user: vocabulary.components(separatedBy: .newlines),
                                                       registeredEnabled: options.registeredVocabularyEnabled,
                                                       topicEnabled: options.topicVocabularyEnabled)
        let take = DictationTake(preferred: requestedMode,
                                style: transcriptionStyle,
                                japaneseHint: japaneseHint,
                                vocabulary: selectedVocabulary,
                                shouldPaste: automaticPaste, options: options)
        guard finished.begin(take.id) else { return }
        take.inputDiagnostics = DiagnosticLog.inputTrace(takeID: take.id)
        take.inputDiagnostics?.record(.session, stage: .requested, [
            .pending: .integer(finished.count),
            .shouldPaste: .flag(take.shouldPaste),
            .textCheck: .flag(take.options.textContextCheckEnabled),
            .audioRecheck: .flag(take.options.audioRecheckEnabled),
            .engine: .token(take.preferred == .gemini ? .gemini : .apple),
            .style: .token(take.style == .agent ? .agent : (take.style == .readable ? .readable : .verbatim)),
            .build: .integer(Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0),
            .osMajor: .integer(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            .osMinor: .integer(ProcessInfo.processInfo.operatingSystemVersion.minorVersion),
            .osPatch: .integer(ProcessInfo.processInfo.operatingSystemVersion.patchVersion)
        ])
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
        let focusStartedAt = ProcessInfo.processInfo.systemUptime
        let targetResult = InsertionTarget.capture(diagnostics: take.inputDiagnostics) // BEFORE the overlay is shown
        take.target = targetResult.target
        take.targetCaptureReason = targetResult.reason
        take.inputDiagnostics?.record(.target, stage: .capture, [
            .element: .token(take.target != nil ? .ok : .unavailable),
            .reason: .reason(targetResult.reason),
            .elapsedMS: .integer(InputDiagnosticTrace.milliseconds(since: focusStartedAt))
        ])
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
                                                style: take.style,
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
            do { try await Task.sleep(for: .seconds(TranscriptReviewDeadline.totalSeconds)) } catch { return }
            guard let self, let take, !take.finished else { return }
            DiagnosticLog.record("background finalization watchdog; id=\(take.id.uuidString.prefix(8))")
            if let review = take.reviewSession {
                self.resolve(take, text: review.expire(), reason: nil)
            } else {
                self.resolve(take, text: nil, reason: "認識処理が15秒以内に完了しませんでした")
            }
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
                        seconds: recordedSeconds, pcmBytes: pcmBytes, peak: peak,
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

    /// A failed cloud transcription may be retried with
    /// Apple's on-device recognizer using the SAME audio data. This does not
    /// block the next recording; the result still waits for its delivery slot.
    private func retryLocally(_ take: DictationTake) async throws -> String {
        try Task.checkCancellation()
        guard !take.finished else { throw CancellationError() }
        guard !take.audioBackup.isEmpty else { throw AppError.connectionLost }
        guard take.audioBackup.count <= 50 * 32_000 else { throw AppError.localRecoveryTooLong }
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
        try Task.checkCancellation()
        guard !take.finished else { throw CancellationError() }
        localRecoveryBusy = true
        defer { localRecoveryBusy = false }
        // Never bring up a permission prompt during a following dictation.
        // Recovery is only allowed when Speech Recognition was authorized.
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            DiagnosticLog.record("local recovery unavailable; speech permission not granted")
            throw AppleLocalTranscriber.LocalError.permission
        }
        let local = AppleLocalTranscriber()
        // If a deadline cancels this worker while start() awaits macOS, the
        // take may already have released its resources. Always close this
        // local owner as well, including recognizers that finish starting late.
        defer { local.cancel() }
        take.local = local
        take.fellBackToApple = true
        take.appleAttempted = true
        take.appleStartedAt = Date()
        take.usedMode = "Appleオンデバイス（Gemini失敗時の救済）"
        try await local.start()
        try Task.checkCancellation()
        guard !take.finished else { throw CancellationError() }
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
                do {
                    try await remote.endAudio()
                    result = try await remote.awaitFinal()
                    take.successfulEngine = .gemini
                } catch {
                    try Task.checkCancellation()
                    guard !take.finished else { throw CancellationError() }
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
            let original = take.preferred == .gemini && take.style == .agent
                ? AgentInstructionFormatting.format(result) : result
            // Only an actually confirmed primary result can survive a review
            // timeout. Pending/interim text never takes this route.
            let review = DictationReviewSession(
                originalText: original, engine: take.successfulEngine, options: take.options,
                stoppedAt: take.stoppingAt, audio: take.audioBackup,
                vocabulary: take.vocabulary, style: take.style, japaneseHint: take.japaneseHint)
            take.reviewSession = review
            let output = await review.run { [weak self, weak take] in
                guard let self, let take, !take.finished else { return }
                if self.overlayOwner == take.id, self.active == nil { self.overlayFeedback = .checking }
                if self.active == nil { self.status = "追加チェック中。次の録音は開始できます" }
            }
            guard !take.finished, !Task.isCancelled else { return }
            resolve(take, text: output, reason: nil)
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
        if take.inputDiagnostics != nil {
            take.resolvedAtUptime = ProcessInfo.processInfo.systemUptime
        }
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
        // Persist now, even if an older delivery is awaiting its receipt. An
        // app exit must not discard a completed result waiting in the sender.
        if accepted, !noInput {
            if let text, !text.isEmpty {
                take.historyRecordID = remember(text, isPartial: false, delivery: .pending,
                                                engine: take.usedMode, review: take.review,
                                                recordedAt: take.requestedAt)
            } else if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                take.historyRecordID = remember(partial, isPartial: true, delivery: .recognitionInterrupted,
                                                engine: take.usedMode, review: take.review,
                                                recordedAt: take.requestedAt)
            }
        }
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
        let samples = take.usageSamples(succeeded: succeeded, cancelled: cancelled)
        usageStore.append(engineEvents: samples.engines, tokenEvents: samples.tokens)
    }

    private func deliverOrderedResults() {
        guard deliveryWorker == nil else { return }
        deliveryWorker = Task { [weak self] in
            guard let self else { return }
            defer { self.deliveryWorker = nil }
            while true {
                let ready = self.finished.drain()
                guard !ready.isEmpty else { return }
                for (id, result) in ready {
                    guard let take = self.inFlight[id] else { continue }
                    // Retain the whole ready prefix in inFlight while awaiting
                    // receipts, so rebasing reaches finished and recording takes.
                    await self.deliver(result, take: take)
                    self.inFlight.removeValue(forKey: id)
                }
            }
        }
    }

    private func deliver(_ result: Completion, take: DictationTake) async {
        let id = take.id
        // AX reads and receipt polling only collect bounded in-memory evidence.
        // Write it once, after input and all dependent-target decisions finish.
        defer { take.inputDiagnostics?.finish() }
        take.inputDiagnostics?.record(.session, stage: .preflight, [
            .queueWaitMS: .integer(take.resolvedAtUptime.map { InputDiagnosticTrace.milliseconds(since: $0) } ?? 0),
            .shouldPaste: .flag(take.shouldPaste),
            .suppressed: .flag(take.automaticDeliverySuppressed),
            .requiresReview: .flag(take.review?.status == .needsReview)
        ])
        if result.noInput {
            take.inputDiagnostics?.record(.result, stage: .result, [
                .outcome: .token(.skipped), .reason: .reason("no_input"), .eventsPosted: .flag(false)
            ])
            DiagnosticLog.record("empty rapid recording discarded; id=\(id.uuidString.prefix(8))")
            return
        }
        guard let text = result.text, !text.isEmpty else {
            take.inputDiagnostics?.record(.result, stage: .result, [
                .outcome: .token(.skipped), .reason: .reason("recognition_failed"), .eventsPosted: .flag(false)
            ])
            let recovered = result.partial.trimmingCharacters(in: .whitespacesAndNewlines)
            if !recovered.isEmpty, take.historyRecordID == nil {
                _ = remember(recovered, isPartial: true, delivery: .recognitionInterrupted,
                             engine: take.usedMode, review: take.review)
            }
            DiagnosticLog.record("session failure; id=\(id.uuidString.prefix(8)); reason=\(Self.safeFailureCode(result.reason))")
            showCompletionFeedback(.failed, for: id)
            if active == nil { status = result.reason ?? "文字起こしに失敗しました（履歴を確認）" }
            return
        }
        let recordID = take.historyRecordID ?? remember(text, isPartial: false, delivery: .pending,
                                                        engine: take.usedMode, review: take.review,
                                                        recordedAt: take.requestedAt)
        let outcome: DictationDelivery.Outcome
        if let skipped = DictationDelivery.skipped(suppressed: take.automaticDeliverySuppressed,
                                                  requiresReview: take.review?.status == .needsReview,
                                                  shouldPaste: take.shouldPaste) {
            outcome = skipped
            take.inputDiagnostics?.record(.result, stage: .result, [
                .outcome: .token(.skipped),
                .reason: .reason(take.automaticDeliverySuppressed ? "system_suppressed"
                    : (take.review?.status == .needsReview ? "review_required" : "automatic_input_disabled")),
                .eventsPosted: .flag(false)
            ])
        } else {
            deliveringTakeID = id
            outcome = await DictationDelivery.send(text, to: take.target,
                                                  captureReason: take.targetCaptureReason,
                                                  diagnostics: take.inputDiagnostics) { [weak self, weak take] in
                guard let self, let take else { return false }
                return !take.automaticDeliverySuppressed && self.inFlight[take.id] === take
            }
            deliveringTakeID = nil
            // Reconcile before the next sender. Event submission alone cannot
            // authorize a new caret; an unknown receipt blocks concurrent targets.
            if let report = outcome.report {
                for other in inFlight.values where other.id != id {
                    if let target = other.target {
                        other.target = report.reconciled(target, sourceTakeID: id, candidateTakeID: other.id,
                                                        diagnostics: other.inputDiagnostics)
                    }
                }
                DiagnosticLog.record("delivery resolved; id=\(id.uuidString.prefix(8)); outcome=\(outcome.delivery.rawValue); reason=\(report.reason)")
            }
        }
        if let recordID { updateRemembered(recordID, delivery: outcome.delivery, detail: outcome.detail) }
        if outcome.submitted, let stoppedAt = take.stoppingAt {
            lastStopToInputSeconds = Date().timeIntervalSince(stoppedAt)
        }
        showCompletionFeedback(outcome.submitted ? .sent : .saved, for: id)
        if active == nil {
            status = outcome.detail + (take.review?.status == .incomplete ? " 追加チェックは未完了です。" : "")
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
        for take in outstanding {
            take.automaticDeliverySuppressed = true
            if take.finished, let recordID = take.historyRecordID {
                updateRemembered(recordID,
                                 delivery: take.id == deliveringTakeID ? .interruptedDelivery : .blockedFocus,
                                 detail: take.id == deliveringTakeID
                                    ? "システム中断が発生しました。再送の前に入力先を確認してください。"
                                    : "システム中断により、待機中の自動入力を中止しました。")
            }
        }
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
            case .endedBeforeAudio: return "apple.ended_before_audio"
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
                                              engine: String? = nil,
                                              review: TranscriptReview? = nil,
                                              recordedAt: Date = Date()) -> UUID? {
        historyStore.remember(text, isPartial: isPartial, delivery: delivery,
                              engine: engine ?? (usedMode.isEmpty ? requestedMode.label : usedMode),
                              review: review, recordedAt: recordedAt)
    }

    private func updateRemembered(_ id: UUID, delivery: TranscriptRecord.Delivery, detail: String? = nil) {
        historyStore.updateDelivery(id, to: delivery, detail: detail)
    }

    @discardableResult func copyRecord(_ record: TranscriptRecord) -> Bool { TextInsertion.copy(record.text) }
    func deleteRecord(_ id: UUID) { historyStore.delete(id) }
    func clearHistory() { historyStore.deleteAll() }
    func clearUsageMonitor() { usageStore.deleteAll() }

    func saveKey(_ key: String) throws {
        try KeychainStore.save(key)
        objectWillChange.send()
    }
    func deleteKey() throws {
        try KeychainStore.delete()
        objectWillChange.send()
    }
    func copyLastText() { TextInsertion.copy(history.first?.text ?? previewText) }

    enum AppError: Error, LocalizedError {
        case noKey, connectionLost, audioDropped, localRecoveryBusy, localRecoveryTooLong
        var errorDescription: String? {
            switch self {
            case .noKey: return "Gemini APIキーが未登録です。設定画面でキーチェーンへ保存してください"
            case .connectionLost: return "音声認識エンジンが終了しました"
            case .audioDropped: return "音声チャンクが欠落したため認識結果を破棄しました"
            case .localRecoveryBusy: return "別の録音のローカル復旧処理が実行中です。多重起動を避けるため認識を中止しました"
            case .localRecoveryTooLong: return "50秒を超える音声はAppleの一括救済対象外です。途中結果を履歴に保存します"
            }
        }
    }
}
#endif
