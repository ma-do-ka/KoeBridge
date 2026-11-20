import Foundation
import KoeBridgeTestSupport

import KoeBridgeCore

/// Deterministic stress tests for pure state machines. No Mac-specific APIs.
struct StressTests {
    func tenThousandCarbonCyclesNeverDuplicateARecording() {
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
        check(toggles == 10_000)
    }

    func tenThousandRightCommandTapsToggleOncePerTap() {
        var detector = ModifierToggleDetector(targetKeyCode: 54)
        var toggles = 0
        for _ in 0..<10_000 {
            if detector.flagsChanged(keyCode: 54, targetFlagPresent: true,
                                     otherModifierPresent: false) { toggles += 1 }
            if detector.flagsChanged(keyCode: 54, targetFlagPresent: false,
                                     otherModifierPresent: false) { toggles += 1 }
        }
        check(toggles == 10_000)
    }

    func finalizationNeverAuthorizesUnacknowledgedPreStopResult() {
        let ended = ContinuousClock.now
        for seconds in 16...1000 {
            let now = ended.advanced(by: .seconds(Double(seconds) / 10))
            let early = ended.advanced(by: .seconds(-Double(seconds) / 10))
            check(!FinalizationPolicy.canFinish(endedAt: ended, lastFinalAt: early,
                                                   endAcknowledgedAt: nil, now: now))
        }
    }

    func aThousandTranscriptWritesRetainTheNewestMaximum() throws {
        let result = try HistoryStressFixture.run()
        check(result.correctCount)
        check(result.newest)
        check(result.oldest)
        check(result.persisted)
    }
}
