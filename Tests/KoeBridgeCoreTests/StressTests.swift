import Foundation
import Testing
@testable import KoeBridgeCore

/// Deterministic stress tests for pure state machines. No Mac-specific APIs.
struct StressTests {
    @Test func tenThousandCarbonCyclesNeverDuplicateARecording() {
        var gate = HotKeyPressGate()
        gate.activate(91)
        var toggles = 0
        for _ in 0..<10_000 {
            if gate.receive(id: 91, pressed: true) { toggles += 1 }
            for _ in 0..<4 {
                if gate.receive(id: 91, pressed: true) { toggles += 1 }
            }
            _ = gate.receive(id: 91, pressed: false)
        }
        #expect(toggles == 10_000)
    }

    @Test func tenThousandRightCommandTapsToggleOncePerTap() {
        var detector = ModifierToggleDetector(targetKeyCode: 54)
        var toggles = 0
        for _ in 0..<10_000 {
            if detector.flagsChanged(keyCode: 54, targetFlagPresent: true,
                                     otherModifierPresent: false) { toggles += 1 }
            if detector.flagsChanged(keyCode: 54, targetFlagPresent: false,
                                     otherModifierPresent: false) { toggles += 1 }
        }
        #expect(toggles == 10_000)
    }

    @Test func finalizationNeverAuthorizesUnacknowledgedPreStopResult() {
        let ended = Date(timeIntervalSince1970: 10_000)
        for seconds in 16...1000 {
            let now = ended.addingTimeInterval(Double(seconds) / 10)
            let early = ended.addingTimeInterval(-Double(seconds) / 10)
            #expect(!FinalizationPolicy.canFinish(endedAt: ended, lastFinalAt: early,
                                                   turnCompleteAt: nil, now: now))
        }
    }

    @Test func aThousandTranscriptWritesRetainTheNewestMaximum() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("KoeBridgeStress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        var store = try RecentTranscriptArchive(fileURL: url)
        for n in 0..<1000 {
            let record = TranscriptRecord(engine: "test", text: "発話\(n)",
                                          isPartial: false, delivery: .attemptedUnconfirmed)
            try store.insert(record)
        }
        #expect(store.entries.count == RecentTranscriptArchive.maximumRecords)
        #expect(store.entries.first?.text == "発話999")
        #expect(store.entries.last?.text == "発話\(1000 - RecentTranscriptArchive.maximumRecords)")
        let reopened = try RecentTranscriptArchive(fileURL: url)
        #expect(reopened.entries == store.entries)
    }
}
