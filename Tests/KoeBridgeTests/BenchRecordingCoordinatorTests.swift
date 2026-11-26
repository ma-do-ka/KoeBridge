#if os(macOS)
import Foundation
import Testing
import KoeBridgeCore
@testable import KoeBridge

@MainActor struct BenchRecordingCoordinatorTests {
    /// Deterministic capture: emits fixed PCM on start and lets the test decide
    /// when the stop flush completes.
    @MainActor
    private final class FakeBenchCapture: BenchRecordingCapture {
        var recoveryDisposition: MicrophoneCapture.EngineLifetime.Disposition { .normal }
        private let initialAudio: Data
        private(set) var stopRequested = false
        private(set) var cancelled = false
        private var stopCompletion: ((Int) -> Void)?
        private var pendingLosses: Int?
        var onDeviceChanged: ((MicrophoneInputInterruption) -> Void)?

        init(initialAudio: Data = Data()) {
            self.initialAudio = initialAudio
        }

        func start(deadline: TimeInterval?,
                   onAudio: @escaping (Data) -> Void,
                   onDeviceChanged: @escaping (MicrophoneInputInterruption) -> Void) async throws {
            self.onDeviceChanged = onDeviceChanged
            if !initialAudio.isEmpty { onAudio(initialAudio) }
        }

        func stop(_ end: CaptureEnd, completion: @escaping (Int) -> Void) {
            stopRequested = true
            if let losses = pendingLosses {
                pendingLosses = nil
                completion(losses)
            } else {
                stopCompletion = completion
            }
        }

        func finishStop(losses: Int = 0) {
            if let completion = stopCompletion {
                stopCompletion = nil
                completion(losses)
            } else {
                pendingLosses = losses
            }
        }

        func cancelAndWait() async {
            cancelled = true
        }
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let capture: FakeBenchCapture
        let controller: VoiceController
        let coordinator: BenchRecordingCoordinator

        init(audio: Data) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("BenchCoord-\(UUID().uuidString)", isDirectory: true)
            let audioDir = root.appendingPathComponent("audio", isDirectory: true)
            let capture = FakeBenchCapture(initialAudio: audio)
            let controller = VoiceController(storageDirectory: root)
            self.root = root
            self.capture = capture
            self.controller = controller
            self.coordinator = BenchRecordingCoordinator(
                controller: controller,
                progressStore: BenchRecordingProgressStore(
                    audioDirectory: audioDir,
                    progressFileURL: audioDir.appendingPathComponent("recording-progress.json")
                ),
                selectedInputUID: { "" },
                requestMicPermission: { true },
                makeCapture: { _, _ in capture }
            )
        }

        var audioDirectory: URL { root.appendingPathComponent("audio", isDirectory: true) }

        func clean() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func awaitState(_ coordinator: BenchRecordingCoordinator,
                            _ expected: BenchRecordingCoordinator.RecordingState) async {
        for _ in 0..<400 {
            if coordinator.state == expected { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("coordinator did not reach \(expected); got \(coordinator.state)")
    }

    private func awaitCondition(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func mutualExclusionPreventsSimultaneousDictationAndBenchRecording() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BenchCoord-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = VoiceController(storageDirectory: root)

        #expect(controller.canStartBenchRecording)
        #expect(!controller.benchRecordingActive)

        var interrupted = false
        let started = controller.beginBenchRecordingSession {
            interrupted = true
        }
        #expect(started)
        #expect(controller.benchRecordingActive)
        #expect(!controller.beginBenchRecordingSession(onInterrupt: {}))

        // Dictation and meeting mode must not start while bench recording is active.
        controller.toggle()
        #expect(!controller.busy)
        #expect(controller.phase == .idle)
        #expect(controller.status == "ベンチ録音中は通常の音声入力を開始できません")

        controller.toggleMeeting()
        #expect(!controller.meetingRunning)

        // System interruption cancels active bench recording.
        controller.interruptForSystemEvent("test")
        #expect(interrupted)

        controller.endBenchRecordingSession()
        #expect(!controller.benchRecordingActive)
        #expect(controller.canStartBenchRecording)
    }

    @Test func benchRecordingRefusedWhileDictationTakeIsActive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BenchCoordTake-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var env = VoiceController.PreparationEnvironment()
        env.permission = { false }
        env.makeInputTrace = { _ in nil }
        env.recordSession = { _ in }
        env.recordMicrophone = { _ in }
        env.shouldPaste = false
        env.captureTarget = { _ in (nil, "target_not_captured") }
        var launched: Task<Void, Never>?
        env.preparationLaunched = { launched = $0 }
        let controller = VoiceController(preparation: env, storageDirectory: root)

        controller.toggle()
        #expect(controller.busy)
        #expect(!controller.canStartBenchRecording)
        #expect(!controller.beginBenchRecordingSession(onInterrupt: {}))
        #expect(!controller.benchRecordingActive)

        await launched?.value
    }

    @Test func benchRecordingRefusedWhileMeetingIsRunning() {
        // meetingRunning cannot be driven in tests, so exercise the exact guard
        // used by canStartBenchRecording both ways.
        #expect(!VoiceController.benchRecordingAdmission(
            busy: false, phase: .idle, meetingRunning: true, updateBlocksRecording: false))
        #expect(!VoiceController.benchRecordingAdmission(
            busy: true, phase: .idle, meetingRunning: false, updateBlocksRecording: false))
        #expect(!VoiceController.benchRecordingAdmission(
            busy: false, phase: .preparing, meetingRunning: false, updateBlocksRecording: false))
        #expect(!VoiceController.benchRecordingAdmission(
            busy: false, phase: .idle, meetingRunning: false, updateBlocksRecording: true))
        #expect(VoiceController.benchRecordingAdmission(
            busy: false, phase: .idle, meetingRunning: false, updateBlocksRecording: false))
    }

    @Test func inputDeviceChangeCancelsActiveBenchRecording() async throws {
        let fixture = Fixture(audio: Data(repeating: 1, count: 16_000))
        defer { fixture.clean() }

        fixture.coordinator.startRecording()
        await awaitState(fixture.coordinator, .recording)
        #expect(fixture.controller.benchRecordingActive)

        fixture.capture.onDeviceChanged?(.inputChange)
        let reachedIdle = await awaitCondition { fixture.coordinator.state == .idle }
        #expect(reachedIdle)
        #expect(fixture.coordinator.errorMessage == "マイク入力が変更または中断されたため録音を中止しました")
        let sessionEnded = await awaitCondition { !fixture.controller.benchRecordingActive }
        #expect(sessionEnded)
        #expect(fixture.coordinator.recordedCount == 0)
    }

    @Test func zeroByteCaptureIsNotSaved() async throws {
        let fixture = Fixture(audio: Data())
        defer { fixture.clean() }
        let item = fixture.coordinator.currentItem

        fixture.coordinator.startRecording()
        await awaitState(fixture.coordinator, .recording)
        fixture.coordinator.stopRecording(autoStopped: false)
        await awaitState(fixture.coordinator, .stopping)
        fixture.capture.finishStop()

        let reachedIdle = await awaitCondition { fixture.coordinator.state == .idle }
        #expect(reachedIdle)
        #expect(fixture.coordinator.errorMessage == "音声が検出されなかったため保存しませんでした（0秒）")
        #expect(fixture.coordinator.recordedCount == 0)
        #expect(fixture.coordinator.progressStore.progress(for: item.clipID) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.audioDirectory.appendingPathComponent(item.fileName).path))
    }

    @Test func shortClipIsSavedWithWarning() async throws {
        let fixture = Fixture(audio: Data(repeating: 1, count: 6_400)) // 0.2 s
        defer { fixture.clean() }
        let item = fixture.coordinator.currentItem

        fixture.coordinator.startRecording()
        await awaitState(fixture.coordinator, .recording)
        fixture.coordinator.stopRecording(autoStopped: false)
        fixture.capture.finishStop()

        let reachedIdle = await awaitCondition { fixture.coordinator.state == .idle }
        #expect(reachedIdle)
        let saved = try #require(fixture.coordinator.progressStore.progress(for: item.clipID))
        #expect(saved.duration == 0.2)
        #expect(saved.isTooShort)
        #expect(fixture.coordinator.statusMessage?.contains("0.3秒未満") == true)
        #expect(fixture.coordinator.selectedClipID == "p1-d2-normal-1")
    }

    @Test func clipOverFortyFiveSecondsIsSavedWithWarning() async throws {
        let fixture = Fixture(audio: Data(repeating: 1, count: 46 * 32_000)) // 46 s
        defer { fixture.clean() }
        let item = fixture.coordinator.currentItem

        fixture.coordinator.startRecording()
        await awaitState(fixture.coordinator, .recording)
        fixture.coordinator.stopRecording(autoStopped: false)
        fixture.capture.finishStop()

        let reachedIdle = await awaitCondition { fixture.coordinator.state == .idle }
        #expect(reachedIdle)
        let saved = try #require(fixture.coordinator.progressStore.progress(for: item.clipID))
        #expect(saved.duration == 46.0)
        #expect(saved.isTooLong)
        #expect(fixture.coordinator.statusMessage?.contains("45秒を超えている") == true)
        #expect(fixture.coordinator.selectedClipID == "p1-d2-normal-1")
    }

    @Test func staleStopTaskDoesNotClobberANewSession() async throws {
        let fixture = Fixture(audio: Data(repeating: 1, count: 16_000)) // 0.5 s
        defer { fixture.clean() }
        let oldItem = fixture.coordinator.currentItem
        let oldSelection = fixture.coordinator.selectedClipID

        fixture.coordinator.startRecording()
        await awaitState(fixture.coordinator, .recording)
        fixture.coordinator.stopRecording(autoStopped: false)
        await awaitState(fixture.coordinator, .stopping)

        // A system interrupt during .stopping must not reset state or selection;
        // the in-flight stop/save task owns completion.
        fixture.coordinator.cancelRecording(reason: "システムイベントによりベンチ録音を中断しました")
        #expect(fixture.coordinator.state == .stopping)
        #expect(fixture.coordinator.selectedClipID == oldSelection)
        #expect(fixture.coordinator.errorMessage == nil)

        // Simulate a new session replacing the old one while the stop task is
        // still waiting on the capture flush.
        fixture.controller.endBenchRecordingSession()
        #expect(fixture.controller.beginBenchRecordingSession(onInterrupt: {}))
        fixture.coordinator.replaceActiveSessionForTesting()
        #expect(fixture.controller.benchRecordingActive)

        fixture.capture.finishStop()
        let savedOldClip = await awaitCondition { fixture.coordinator.progressStore.isRecorded(oldItem.clipID) }
        #expect(savedOldClip)

        // The new session's controller flag, coordinator state and selection survive.
        #expect(fixture.controller.benchRecordingActive)
        #expect(fixture.coordinator.state == .stopping)
        #expect(fixture.coordinator.selectedClipID == oldSelection)
        // The old clip's WAV and progress entry were still saved.
        #expect(fixture.coordinator.progressStore.progress(for: oldItem.clipID)?.recorded == true)
        #expect(FileManager.default.fileExists(
            atPath: fixture.coordinator.progressStore.audioFileURL(for: oldItem).path))

        fixture.controller.endBenchRecordingSession()
    }

    @Test func coordinatorSelectionAndProgressReloadDoNotLoseWAVs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BenchCoordPage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = VoiceController(storageDirectory: root)
        let audioDir = root.appendingPathComponent("audio", isDirectory: true)
        let progressURL = root.appendingPathComponent("recording-progress.json")

        var seeded = BenchRecordingProgressStore(audioDirectory: audioDir, progressFileURL: progressURL)
        let first = try #require(BenchRecordingItem.item(forClipID: "p1-d1-normal-1"))
        try seeded.saveRecording(for: first, pcm16LE: Data(repeating: 1, count: 16_000))

        let coordinator = BenchRecordingCoordinator(
            controller: controller,
            progressStore: BenchRecordingProgressStore(audioDirectory: audioDir, progressFileURL: progressURL),
            selectedInputUID: { "" },
            requestMicPermission: { true }
        )
        #expect(coordinator.recordedCount == 1)
        #expect(coordinator.currentItem.clipID == "p1-d2-normal-1")

        // Selecting a recorded item allows targeting it for re-record.
        coordinator.select(first)
        #expect(coordinator.currentItem.clipID == first.clipID)
        coordinator.selectNextUnrecorded()
        #expect(coordinator.currentItem.clipID == "p1-d2-normal-1")
    }
}
#endif
