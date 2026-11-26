#if os(macOS)
import AVFoundation
import Foundation
import KoeBridgeCore

/// Thread-safe accumulator for PCM16LE chunks emitted on MicrophoneCapture's conversion queue.
private final class BenchPCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func drain() -> Data {
        lock.lock()
        let result = data
        data = Data()
        lock.unlock()
        return result
    }
}

/// Capture surface the coordinator drives. `MicrophoneCapture` conforms in
/// production; tests substitute a capture that never touches real hardware.
@MainActor
protocol BenchRecordingCapture: AnyObject {
    var recoveryDisposition: MicrophoneCapture.EngineLifetime.Disposition { get }

    func start(deadline: TimeInterval?,
               onAudio: @escaping (Data) -> Void,
               onDeviceChanged: @escaping (MicrophoneInputInterruption) -> Void) async throws
    func stop(_ end: CaptureEnd, completion: @escaping (Int) -> Void)
    func cancelAndWait() async
}

extension MicrophoneCapture: BenchRecordingCapture {}

/// Coordinates local-only benchmark corpus recording through MicrophoneCapture
/// without starting any speech engine, history record, usage accounting, or insertion.
@MainActor final class BenchRecordingCoordinator: ObservableObject {
    enum RecordingState: Equatable {
        case idle
        case preparing
        case recording
        case stopping
    }

    @Published private(set) var progressStore: BenchRecordingProgressStore
    @Published var selectedClipID: String
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?

    private let controller: VoiceController
    private let selectedInputUID: @MainActor () -> String
    private let requestMicPermission: () async -> Bool
    private let makeCapture: (String, Bool) -> any BenchRecordingCapture

    /// One token per recording session. An async stop/save task captures its
    /// session's token and skips shared-state mutations once a newer session
    /// owns the coordinator (I1).
    private var sessionGeneration: UUID?
    private var activeCapture: (any BenchRecordingCapture)?
    private var activePCMBuffer: BenchPCMBuffer?
    private var recordingTask: Task<Void, Never>?
    private var elapsedTimerTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?

    init(
        controller: VoiceController,
        progressStore: BenchRecordingProgressStore = BenchRecordingProgressStore(),
        selectedInputUID: @MainActor @escaping () -> String = { MicrophoneDeviceStore.shared.selectedUID },
        requestMicPermission: @escaping () async -> Bool = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            default: return false
            }
        },
        makeCapture: @escaping (String, Bool) -> any BenchRecordingCapture = { uid, explicitStart in
            MicrophoneCapture(selectedInputUID: uid, explicitStart: explicitStart)
        }
    ) {
        self.controller = controller
        self.progressStore = progressStore
        self.selectedInputUID = selectedInputUID
        self.requestMicPermission = requestMicPermission
        self.makeCapture = makeCapture
        self.selectedClipID = progressStore.nextUnrecordedItem()?.clipID
            ?? BenchRecordingItem.all[0].clipID
    }

    var currentItem: BenchRecordingItem {
        BenchRecordingItem.item(forClipID: selectedClipID) ?? BenchRecordingItem.all[0]
    }

    var recordedCount: Int {
        progressStore.recordedCount
    }

    var totalCount: Int {
        BenchRecordingItem.all.count
    }

    var canSelectItem: Bool {
        state == .idle
    }

    var nextUnrecordedItem: BenchRecordingItem? {
        progressStore.nextUnrecordedItem(after: selectedClipID)
    }

    func reloadProgress() {
        guard state == .idle else { return }
        let wasEmptySelection = progressStore.entries.isEmpty
        progressStore.reload()
        if wasEmptySelection, let next = progressStore.nextUnrecordedItem() {
            selectedClipID = next.clipID
        }
    }

    func select(_ item: BenchRecordingItem) {
        guard state == .idle else { return }
        selectedClipID = item.clipID
        errorMessage = nil
    }

    func selectNextUnrecorded() {
        guard state == .idle, let next = progressStore.nextUnrecordedItem(after: selectedClipID) else { return }
        selectedClipID = next.clipID
        errorMessage = nil
    }

    func toggleRecording() {
        switch state {
        case .idle:
            startRecording()
        case .preparing:
            cancelRecording(reason: nil)
        case .recording:
            stopRecording(autoStopped: false)
        case .stopping:
            break
        }
    }

    func startRecording() {
        guard state == .idle else { return }
        errorMessage = nil
        statusMessage = nil
        guard controller.beginBenchRecordingSession(onInterrupt: { [weak self] in
            self?.cancelRecording(reason: "システムイベントによりベンチ録音を中断しました")
        }) else {
            errorMessage = "音声入力・会議モード・更新中はベンチ録音を開始できません"
            return
        }
        state = .preparing
        elapsedSeconds = 0
        let sessionToken = UUID()
        sessionGeneration = sessionToken

        recordingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareAndStartCapture(sessionToken: sessionToken)
        }
    }

    /// Test-only seam for the I1 race: simulates a new recording session
    /// replacing this coordinator's session while an async stop/save task from
    /// the previous session is still running, without a second capture stack.
    func replaceActiveSessionForTesting() {
        sessionGeneration = UUID()
    }

    private func isCurrentSession(_ token: UUID) -> Bool {
        sessionGeneration == token
    }

    private func prepareAndStartCapture(sessionToken: UUID) async {
        let allowed = await requestMicPermission()
        guard !Task.isCancelled, state == .preparing, isCurrentSession(sessionToken) else {
            finishCancelledPreparation(sessionToken: sessionToken)
            return
        }
        guard allowed else {
            controller.endBenchRecordingSession()
            sessionGeneration = nil
            state = .idle
            errorMessage = "マイクへのアクセスが許可されていません。設定の「権限」からマイクを許可してください。"
            return
        }

        let inputUID = selectedInputUID()
        let retryPolicy = MicrophoneStartupRetryPolicy()
        let preparationBegan = ProcessInfo.processInfo.systemUptime
        var attempts = 0
        var readyCapture: (any BenchRecordingCapture)?
        var readyBuffer: BenchPCMBuffer?

        do {
            while readyCapture == nil {
                try Task.checkCancellation()
                guard state == .preparing, isCurrentSession(sessionToken) else { throw CancellationError() }
                let attemptBegan = ProcessInfo.processInfo.systemUptime
                let elapsed = attemptBegan - preparationBegan
                let timeout = retryPolicy.timeoutForNextAttempt(elapsed: elapsed)
                guard timeout > 0 else { throw MicrophoneCapture.CaptureError.notReady(.noBuffers) }
                attempts += 1
                let pcmBuffer = BenchPCMBuffer()
                let candidate = makeCapture(inputUID, attempts == 1)
                activeCapture = candidate
                activePCMBuffer = pcmBuffer
                do {
                    let deadline = min(attemptBegan + timeout, preparationBegan + retryPolicy.totalTimeout)
                    try await candidate.start(
                        deadline: deadline,
                        onAudio: { chunk in
                            pcmBuffer.append(chunk)
                        },
                        onDeviceChanged: { [weak self, weak candidate] _ in
                            Task { @MainActor [weak self, weak candidate] in
                                guard let self, let candidate,
                                      self.activeCapture === candidate,
                                      self.state == .recording else { return }
                                self.cancelRecording(reason: "マイク入力が変更または中断されたため録音を中止しました")
                            }
                        }
                    )
                    readyCapture = candidate
                    readyBuffer = pcmBuffer
                } catch {
                    await candidate.cancelAndWait()
                    if activeCapture === candidate {
                        activeCapture = nil
                        activePCMBuffer = nil
                    }
                    guard !Task.isCancelled, state == .preparing, isCurrentSession(sessionToken) else {
                        throw CancellationError()
                    }
                    if error is CancellationError { throw error }
                    if error is MicrophoneSelectionError { throw error }
                    let totalElapsed = ProcessInfo.processInfo.systemUptime - preparationBegan
                    guard let delay = MicrophoneCapture.retryDelay(
                        for: error,
                        policy: retryPolicy,
                        attempts: attempts,
                        elapsed: totalElapsed,
                        disposition: candidate.recoveryDisposition
                    ) else {
                        throw error
                    }
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        } catch is CancellationError {
            finishCancelledPreparation(sessionToken: sessionToken)
            return
        } catch {
            guard isCurrentSession(sessionToken) else { return }
            controller.endBenchRecordingSession()
            sessionGeneration = nil
            state = .idle
            errorMessage = error.localizedDescription
            return
        }

        guard let capture = readyCapture, let buffer = readyBuffer,
              !Task.isCancelled, state == .preparing, isCurrentSession(sessionToken) else {
            if let capture = readyCapture {
                await capture.cancelAndWait()
            }
            finishCancelledPreparation(sessionToken: sessionToken)
            return
        }

        activeCapture = capture
        activePCMBuffer = buffer
        state = .recording
        elapsedSeconds = 0

        let startedAt = ContinuousClock.now
        elapsedTimerTask?.cancel()
        elapsedTimerTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.state == .recording {
                let elapsed = startedAt.duration(to: ContinuousClock.now)
                self.elapsedSeconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000.0
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }

        autoStopTask?.cancel()
        autoStopTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(BenchRecordingProgressStore.maximumRecordingDuration))
            } catch { return }
            guard let self, !Task.isCancelled, self.state == .recording else { return }
            self.stopRecording(autoStopped: true)
        }
    }

    private func finishCancelledPreparation(sessionToken: UUID) {
        guard isCurrentSession(sessionToken) else { return }
        let capture = activeCapture
        activeCapture = nil
        activePCMBuffer = nil
        sessionGeneration = nil
        if let capture {
            Task { @MainActor [weak self] in
                await capture.cancelAndWait()
                self?.controller.endBenchRecordingSession()
            }
        } else {
            controller.endBenchRecordingSession()
        }
        if state == .preparing {
            state = .idle
            elapsedSeconds = 0
        }
    }

    func stopRecording(autoStopped: Bool) {
        guard state == .recording,
              let capture = activeCapture,
              let pcmBuffer = activePCMBuffer,
              let sessionToken = sessionGeneration else {
            return
        }
        let item = currentItem
        state = .stopping
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        activeCapture = nil
        activePCMBuffer = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let losses = await withCheckedContinuation { continuation in
                capture.stop(.normal) { losses in
                    continuation.resume(returning: losses)
                }
            }
            // The only suspension point is above: a new session may now own the
            // coordinator (I1). On a mismatch this task must not touch shared
            // state, but the old clip's WAV/progress write is session-independent.
            guard self.isCurrentSession(sessionToken) else {
                self.persistOrphanedClip(item: item, pcmBuffer: pcmBuffer, losses: losses)
                return
            }
            self.controller.endBenchRecordingSession()
            self.elapsedSeconds = 0

            guard losses == 0 else {
                self.state = .idle
                self.sessionGeneration = nil
                self.errorMessage = "マイクの音声データが欠落したため保存しませんでした"
                return
            }

            let pcm = pcmBuffer.drain()
            guard !pcm.isEmpty else {
                self.state = .idle
                self.sessionGeneration = nil
                self.errorMessage = "音声が検出されなかったため保存しませんでした（0秒）"
                return
            }

            do {
                let saved = try self.progressStore.saveRecording(for: item, pcm16LE: pcm)
                let durationText = String(format: "%.2f", saved.duration)
                if saved.isTooShort {
                    self.statusMessage = "\(item.sentence.id) を保存しましたが、0.3秒未満（\(durationText)秒）のため再録音をおすすめします"
                } else if saved.isTooLong {
                    let prefix = autoStopped
                        ? "\(item.sentence.id)（\(item.voice.label) \(item.repetition)回目）を60秒上限で自動停止し、保存しました（\(durationText)秒）"
                        : "\(item.sentence.id)（\(item.voice.label) \(item.repetition)回目）を保存しました（\(durationText)秒）"
                    self.statusMessage = "\(prefix)。45秒を超えているためベンチマークCLIでは扱えません。再録音してください"
                } else if autoStopped {
                    self.statusMessage = "\(item.sentence.id)（\(item.voice.label) \(item.repetition)回目）を60秒上限で自動停止し、保存しました（\(durationText)秒）"
                } else {
                    self.statusMessage = "\(item.sentence.id)（\(item.voice.label) \(item.repetition)回目）を保存しました（\(durationText)秒）"
                }
                if let next = self.progressStore.nextUnrecordedItem(after: item.clipID) {
                    self.selectedClipID = next.clipID
                }
            } catch {
                self.errorMessage = "WAVファイルの保存に失敗しました: \(error.localizedDescription)"
            }
            self.state = .idle
            self.sessionGeneration = nil
        }
    }

    /// Persists a clip whose stop task outlived its session without touching any
    /// session-owned UI state.
    private func persistOrphanedClip(item: BenchRecordingItem, pcmBuffer: BenchPCMBuffer, losses: Int) {
        guard losses == 0 else { return }
        let pcm = pcmBuffer.drain()
        guard !pcm.isEmpty else { return }
        try? progressStore.saveRecording(for: item, pcm16LE: pcm)
    }

    func cancelRecording(reason: String?) {
        // While saving, the stop task owns completion: resetting here would let a
        // new session start while the old task still writes shared state (I1).
        guard state != .stopping else { return }
        recordingTask?.cancel()
        recordingTask = nil
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil
        autoStopTask?.cancel()
        autoStopTask = nil

        let capture = activeCapture
        activeCapture = nil
        activePCMBuffer = nil
        state = .idle
        elapsedSeconds = 0
        sessionGeneration = nil
        if let reason {
            errorMessage = reason
        }
        if let capture {
            Task { @MainActor [weak self] in
                await capture.cancelAndWait()
                self?.controller.endBenchRecordingSession()
            }
        } else {
            controller.endBenchRecordingSession()
        }
    }
}
#endif
