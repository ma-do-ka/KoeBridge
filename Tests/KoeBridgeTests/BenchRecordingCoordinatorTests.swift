#if os(macOS)
import Foundation
import Testing
import KoeBridgeCore
@testable import KoeBridge

@MainActor struct BenchRecordingCoordinatorTests {
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
