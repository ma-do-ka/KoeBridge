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

    private var archive: RecentTranscriptArchive?
    private var usageArchive: UsageMonitorArchive?
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
        do {
            var saved = try RecentTranscriptArchive()
            for record in saved.entries where record.delivery == .pending {
                do {
                    try saved.updateDelivery(id: record.id, to: .interruptedDelivery,
                                             detail: "前回の入力処理が完了する前に終了しました。再送の前に入力先を確認してください。")
                } catch {
                    historyProblem = "履歴の入力状態をディスクへ更新できません：\(error.localizedDescription)"
                }
            }
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
            if let confirmed = take.confirmedText {
                take.review = TranscriptReview(status: .incomplete,
                                               note: "追加チェックが時間内に終わらなかったため、元の確定文を使用しました。")
                self.resolve(take, text: confirmed, reason: nil)
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
            let original = take.preferred == .gemini && take.style == .agent
                ? AgentInstructionFormatting.format(result) : result
            // Only an actually confirmed primary result can survive a review
            // timeout. Pending/interim text never takes this route.
            take.confirmedText = original
            let output = await review(original, take: take)
            guard !take.finished, !Task.isCancelled else { return }
            resolve(take, text: output, reason: nil)
        } catch {
            guard !take.finished, !Task.isCancelled else { return }
            DiagnosticLog.record("recognition failure; category=\(Self.failureCategory(error))")
            resolve(take, text: nil, reason: "認識失敗: \(error.localizedDescription)")
        }
    }

    private func review(_ original: String, take: DictationTake) async -> String {
        let options = take.options
        guard options.textContextCheckEnabled || options.audioRecheckEnabled else { return original }
        guard take.successfulEngine == .gemini else {
            take.review = TranscriptReview(status: .incomplete,
                                           note: "Appleの認識結果にはGemini用の追加チェックを実行していません。")
            return original
        }
        let local = options.textContextCheckEnabled ? TextContextChecking.check(original) : nil
        let locallyChecked = local?.text ?? original
        let textNote = local.map { "文章チェック：句読点を\($0.changes)箇所調整。" } ?? ""
        let shouldRecheck = options.audioRecheckEnabled &&
            (options.audioRecheckPolicy == .always || TextContextChecking.isSuspicious(original))
        guard shouldRecheck else {
            let audioNote = options.audioRecheckEnabled ? "音声照合：疑わしい区切りの検出条件に該当せず、再認識は実行していません。" : ""
            take.review = TranscriptReview(status: .checked, note: textNote + audioNote,
                                           originalText: locallyChecked == original ? nil : original)
            return locallyChecked
        }
        let budget = TranscriptReviewDeadline.available(stoppedAt: take.stoppingAt, now: Date())
        guard budget > 0, !take.audioBackup.isEmpty,
              take.audioBackup.count <= GeminiRecheckWire.maximumPCMBytes,
              let key = KeychainStore.load() else {
            take.review = TranscriptReview(status: .incomplete,
                                           note: "追加チェックの時間・音声サイズ・APIキーの条件を満たさないため、元の確定文を使用しました。")
            return original
        }
        if overlayOwner == take.id, active == nil { overlayFeedback = .checking }
        if active == nil { status = "追加チェック中。次の録音は開始できます" }
        take.recheckStartedAt = Date()
        take.recheckAudioBytes = take.audioBackup.count
        do {
            let checked = try await GeminiAudioRechecker.recognize(
                pcm16LE: take.audioBackup, vocabulary: take.vocabulary, style: take.style,
                japaneseHint: take.japaneseHint, apiKey: key, timeout: budget)
            guard !take.finished, !Task.isCancelled else { return original }
            take.recheckSucceeded = true
            if let usage = checked.usage {
                take.recheckTokens.append(GeminiTokenSample(at: Date(), usage: usage))
            }
            let comparison = TextContextChecking.compare(original: original, candidate: checked.text,
                                                         textCheckEnabled: options.textContextCheckEnabled)
            guard !comparison.requiresReview else {
                take.review = TranscriptReview(status: .needsReview,
                                               note: "元の確定文と再認識結果に文字の違いがあります。自動入力せず、両方を保存しました。",
                                               alternativeText: checked.text)
                return original
            }
            // Audio comparison never enables the independent text-editing
            // checkbox. Keep the primary punctuation except for the selected
            // local check's narrowly defined changes.
            let accepted = comparison.text
            take.review = TranscriptReview(status: .checked,
                                           note: textNote + "音声を1回再認識し、語句の一致を確認しました。認識の正しさを保証するものではありません。",
                                           originalText: accepted == original ? nil : original)
            return accepted
        } catch {
            guard !take.finished, !Task.isCancelled else { return original }
            // Do not log private request/response bodies or credentials, and
            // never silently retry a charged optional API operation.
            take.review = TranscriptReview(status: .incomplete,
                                           note: "追加チェックを完了できなかったため、元の確定文を使用しました。")
            DiagnosticLog.record("audio recheck incomplete; original confirmed result retained")
            return original
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
        if let startedAt = take.recheckStartedAt {
            rows.append(EngineUsageSample(at: startedAt, engine: .gemini,
                                          audioSeconds: Double(take.recheckAudioBytes) / 32_000,
                                          outcome: take.recheckSucceeded ? .success : (cancelled ? .cancelled : .failure),
                                          purpose: .audioRecheck))
        }
        let tokens = (take.cloud?.tokenSamples ?? []) + take.recheckTokens
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
        if result.noInput {
            DiagnosticLog.record("empty rapid recording discarded; id=\(id.uuidString.prefix(8))")
            return
        }
        guard let text = result.text, !text.isEmpty else {
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
        let outcome: TranscriptRecord.Delivery
        let detail: String
        if take.automaticDeliverySuppressed {
            outcome = .blockedFocus
            detail = "システム中断により自動入力しませんでした。"
        } else if take.review?.status == .needsReview {
            outcome = .reviewRequired
            detail = "再認識との違いを確認するため、自動入力せず両方の文章を保存しました。"
        } else if !take.shouldPaste {
            outcome = .automaticPasteDisabled
            detail = "自動入力がOFFのため、履歴へ保存しました。"
        } else {
            deliveringTakeID = id
            let report = await TextInsertion.deliver(text, to: take.target, shouldContinue: { [weak self, weak take] in
                guard let self, let take else { return false }
                return !take.automaticDeliverySuppressed && self.inFlight[take.id] === take
            })
            deliveringTakeID = nil
            // Reconcile before the next sender. Event submission alone cannot
            // authorize a new caret; an unknown receipt blocks concurrent targets.
            for other in inFlight.values where other.id != id {
                if let target = other.target { other.target = report.reconciled(target) }
            }
            switch report.outcome {
            case .verifiedInserted: outcome = .verifiedInserted
            case .inserted: outcome = .attemptedUnconfirmed
            case .focusChanged, .cancelled: outcome = .blockedFocus
            case .notPermitted, .eventPermissionMissing: outcome = .missingPermission
            case .partiallySubmitted: outcome = .partiallyDirect
            case .eventUnavailable: outcome = .insertionUnavailable
            }
            detail = Self.deliveryDescription(outcome, reason: take.target == nil ? take.targetCaptureReason : report.reason)
            DiagnosticLog.record("delivery resolved; id=\(id.uuidString.prefix(8)); outcome=\(outcome.rawValue); reason=\(report.reason)")
        }
        if let recordID { updateRemembered(recordID, delivery: outcome, detail: detail) }
        let submitted = outcome == .verifiedInserted || outcome == .attemptedUnconfirmed
        if submitted, let stoppedAt = take.stoppingAt {
            lastStopToInputSeconds = Date().timeIntervalSince(stoppedAt)
        }
        showCompletionFeedback(submitted ? .sent : .saved, for: id)
        if active == nil {
            status = detail + (take.review?.status == .incomplete ? " 追加チェックは未完了です。" : "")
        }
    }

    private static func deliveryDescription(_ delivery: TranscriptRecord.Delivery, reason: String) -> String {
        switch delivery {
        case .verifiedInserted: return "入力先への反映を確認しました。履歴に保存済みです。"
        case .attemptedUnconfirmed: return "入力イベントを送信しました（受理は未確認）。再送の前に入力先を確認してください。"
        case .missingPermission: return "入力に必要な権限がありません。認識結果は履歴に保存しました。"
        case .partiallyDirect: return "入力が途中で中断しました。履歴を使う前に、入力先に入った範囲を確認してください。"
        case .insertionUnavailable: return "入力イベントを送信できませんでした。認識結果は履歴に保存しました。"
        default: break
        }
        switch reason {
        case "caret_or_selection_changed": return "カーソルまたは選択範囲が変わったため、入力せず履歴に保存しました。"
        case "prior_input_unverified": return "前の文章の反映を確認できないため、続く文章を履歴に保存しました。"
        case "koebridge_window_is_frontmost": return "設定画面を閉じて入力欄を選んでください。認識結果は履歴に保存しました。"
        case "active_app_changed", "focused_field_changed", "focused_window_changed":
            return "録音開始時と入力先が変わったため、入力せず履歴に保存しました。"
        case "accessibility_not_granted": return "アクセシビリティの許可が必要です。認識結果は履歴に保存しました。"
        default: return "入力先の安全確認を完了できなかったため、履歴に保存しました。"
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let record = TranscriptRecord(recordedAt: recordedAt,
                                      engine: engine ?? (usedMode.isEmpty ? requestedMode.label : usedMode),
                                      text: trimmed, isPartial: isPartial, delivery: delivery, review: review)
        guard var store = archive else {
            // Recovery within the running app even if an old archive is corrupt.
            history.insert(record, at: 0)
            history.sort { $0.recordedAt > $1.recordedAt }
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

    private func updateRemembered(_ id: UUID, delivery: TranscriptRecord.Delivery, detail: String? = nil) {
        guard var store = archive else {
            if let index = history.firstIndex(where: { $0.id == id }) {
                history[index].delivery = delivery
                history[index].deliveryDetail = detail
            }
            return
        }
        do { try store.updateDelivery(id: id, to: delivery, detail: detail) }
        catch { historyProblem = "履歴の状態更新に失敗しました：\(error.localizedDescription)" }
        archive = store
        history = store.entries
    }

    @discardableResult func copyRecord(_ record: TranscriptRecord) -> Bool { TextInsertion.copy(record.text) }
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
