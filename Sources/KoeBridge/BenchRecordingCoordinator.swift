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
    private let selectedInputUID: () -> String
    private let requestMicPermission: () async -> Bool
    private let makeCapture: (String, Bool) -> MicrophoneCapture

    private var activeCapture: MicrophoneCapture?
    private var activePCMBuffer: BenchPCMBuffer?
    private var recordingTask: Task<Void, Never>?
    private var elapsedTimerTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?

    init(
        controller: VoiceController,
        progressStore: BenchRecordingProgressStore = BenchRecordingProgressStore(),
        selectedInputUID: @escaping () -> String = { MicrophoneDeviceStore.shared.selectedUID },
        requestMicPermission: @escaping () async -> Bool = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            default: return false
            }
        },
        makeCapture: @escaping (String, Bool) -> MicrophoneCapture = { uid, explicitStart in
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

        recordingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareAndStartCapture()
        }
    }

    private func prepareAndStartCapture() async {
        let allowed = await requestMicPermission()
        guard !Task.isCancelled, state == .preparing else {
            finishCancelledPreparation()
            return
        }
        guard allowed else {
            controller.endBenchRecordingSession()
            state = .idle
            errorMessage = "マイクへのアクセスが許可されていません。設定の「権限」からマイクを許可してください。"
            return
        }

        let inputUID = selectedInputUID()
        let retryPolicy = MicrophoneStartupRetryPolicy()
        let preparationBegan = ProcessInfo.processInfo.systemUptime
        var attempts = 0
        var readyCapture: MicrophoneCapture?
        var readyBuffer: BenchPCMBuffer?

        do {
            while readyCapture == nil {
                try Task.checkCancellation()
                guard state == .preparing else { throw CancellationError() }
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
                    guard !Task.isCancelled, state == .preparing else { throw CancellationError() }
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
            finishCancelledPreparation()
            return
        } catch {
            controller.endBenchRecordingSession()
            state = .idle
            errorMessage = error.localizedDescription
            return
        }

        guard let capture = readyCapture, let buffer = readyBuffer,
              !Task.isCancelled, state == .preparing else {
            if let capture = readyCapture {
                await capture.cancelAndWait()
            }
            finishCancelledPreparation()
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

    private func finishCancelledPreparation() {
        let capture = activeCapture
        activeCapture = nil
        activePCMBuffer = nil
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
              let pcmBuffer = activePCMBuffer else {
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
            self.controller.endBenchRecordingSession()
            self.elapsedSeconds = 0

            guard losses == 0 else {
                self.state = .idle
                self.errorMessage = "マイクの音声データが欠落したため保存しませんでした"
                return
            }

            let pcm = pcmBuffer.drain()
            guard !pcm.isEmpty else {
                self.state = .idle
                self.errorMessage = "音声が検出されなかったため保存しませんでした（0秒）"
                return
            }

            do {
                let saved = try self.progressStore.saveRecording(for: item, pcm16LE: pcm)
                let durationText = String(format: "%.2f", saved.duration)
                if autoStopped {
                    self.statusMessage = "\(item.sentence.id)（\(item.voice.label) \(item.repetition)回目）を60秒上限で自動停止し、保存しました（\(durationText)秒）"
                } else if saved.isTooShort {
                    self.statusMessage = "\(item.sentence.id) を保存しましたが、0.3秒未満（\(durationText)秒）のため再録音をおすすめします"
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
        }
    }

    func cancelRecording(reason: String?) {
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
