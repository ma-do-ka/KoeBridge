import Foundation
import KoeBridgeTestSupport
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
        let ended = ContinuousClock.now
        for seconds in 16...1000 {
            let now = ended.advanced(by: .seconds(Double(seconds) / 10))
            let early = ended.advanced(by: .seconds(-Double(seconds) / 10))
            #expect(!FinalizationPolicy.canFinish(endedAt: ended, lastFinalAt: early,
                                                   endAcknowledgedAt: nil, now: now))
        }
    }

    @Test func aThousandTranscriptWritesRetainTheNewestMaximum() throws {
        let result = try HistoryStressFixture.run()
        #expect(result.correctCount)
        #expect(result.newest)
        #expect(result.oldest)
        #expect(result.persisted)
    }
}
