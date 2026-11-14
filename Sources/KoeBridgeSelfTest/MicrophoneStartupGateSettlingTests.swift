import Foundation
import KoeBridgeCore

struct MicrophoneStartupGateTests {
    func testSameFormatChurnRequiresRevalidationAndFreshStability() {
        let gate = MicrophoneStartupGate()
        let token = gate.captureTokenForTap(tapGeneration: 1)!
        gate.observeConvertedBuffer(frames: 800, at: 0)
        gate.observeConvertedBuffer(frames: 800, at: 0.16)
        check(gate.handleConfigurationChange(at: 0.17, deadline: 2.5) == .revalidate(epoch: 2, firstInBurst: true))
        check(!gate.commit(at: 0.18, deadline: 2.5, engineRunning: true, expectedEpoch: 1))
        check(!gate.accepts(token))
        check(gate.captureTokenForTap(tapGeneration: 1) == nil)
        check(gate.revalidationReadiness(at: 0.24, deadline: 2.5) == .readyToRevalidate(epoch: 2))
        check(gate.resumeStabilising(expectedEpoch: 2, at: 0.24))
        check(gate.observeConvertedBuffer(frames: 800, at: 0.25, epoch: 1) == .dropped)
        check(gate.observeConvertedBuffer(frames: 800, at: 0.26, epoch: 2) == .buffered)
        check(gate.observeConvertedBuffer(frames: 800, at: 0.30, epoch: 2) == .buffered)
        check(gate.decision(at: 0.31, deadline: 2.5, engineRunning: true) == .waiting)
        check(gate.observeConvertedBuffer(frames: 800, at: 0.42, epoch: 2) == .buffered)
        check(!gate.commit(at: 0.43, deadline: 2.5, engineRunning: true, expectedEpoch: 1))
        check(gate.commit(at: 0.43, deadline: 2.5, engineRunning: true, expectedEpoch: 2))
        check(gate.settlingSnapshot(at: 0.43).readyViaSettling)
        check(gate.currentTapGeneration == 1)
    }

    func testConfiguringChurnAndCancellationCannotResurrect() {
        let gate = MicrophoneStartupGate(configuring: true)
        check(gate.currentPhase == .configuring(epoch: 1, churnPending: false))
        _ = gate.handleConfigurationChange(at: 0.1, deadline: 2.5)
        check(gate.currentPhase == .configuring(epoch: 2, churnPending: true))
        check(gate.captureTokenForTap(tapGeneration: 1) == nil)
        check(gate.revalidationReadiness(at: 0.2, deadline: 2.5) == .notRevalidating)
        _ = gate.finishConfiguring(at: 0.2)
        check(gate.revalidationReadiness(at: 0.21, deadline: 2.5) == .readyToRevalidate(epoch: 2))
        gate.stop()
        check(!gate.resumeStabilising(expectedEpoch: 2, at: 0.22))
        check(gate.finishConfiguring(at: 0.23) == .stopped)
        check(gate.handleConfigurationChange(at: 0.24, deadline: 2.5) == .ignored)
        check(!gate.commit(at: 0.4, deadline: 2.5, engineRunning: true))
    }

    func testBurstCoalescingAndChecklistRace() {
        let gate = MicrophoneStartupGate()
        _ = gate.handleConfigurationChange(at: 0.1, deadline: 2.5)
        _ = gate.handleConfigurationChange(at: 0.14, deadline: 2.5)
        if case .debouncePending(let remaining) = gate.revalidationReadiness(at: 0.18, deadline: 2.5) {
            check(abs(remaining - 0.02) < 0.0001)
        } else { check(false) }
        check(gate.revalidationReadiness(at: 0.21, deadline: 2.5) == .readyToRevalidate(epoch: 3))
        _ = gate.handleConfigurationChange(at: 0.22, deadline: 2.5)
        check(!gate.resumeStabilising(expectedEpoch: 3, at: 0.23))
        gate.invalidate(.engineStopped, expectedEpoch: 3)
        check(gate.currentPhase == .revalidating(epoch: 4, pendingSince: 0.1, lastChurnAt: 0.22))
        _ = gate.handleConfigurationChange(at: 0.27, deadline: 2.5)
        _ = gate.handleConfigurationChange(at: 0.32, deadline: 2.5)
        check(gate.revalidationReadiness(at: 0.351, deadline: 2.5) == .readyToRevalidate(epoch: 6))
        check(gate.resumeStabilising(expectedEpoch: 6, at: 0.36))
    }

    func testEverySettlingBudgetTerminatesInsideAttempt() {
        let churn = MicrophoneStartupGate()
        for i in 0..<16 { _ = churn.handleConfigurationChange(at: Double(i) * 0.001, deadline: 2.5) }
        check(churn.handleConfigurationChange(at: 0.017, deadline: 2.5) == .budgetExhausted(.configurationChanged))
        let count = MicrophoneStartupGate()
        for i in 0..<4 {
            let start = Double(i) * 0.2
            _ = count.handleConfigurationChange(at: start, deadline: 2.5)
            check(count.revalidationReadiness(at: start + 0.07, deadline: 2.5) == .readyToRevalidate(epoch: UInt64(i + 2)))
            check(count.resumeStabilising(expectedEpoch: UInt64(i + 2), at: start + 0.08))
        }
        _ = count.handleConfigurationChange(at: 0.9, deadline: 2.5)
        check(count.revalidationReadiness(at: 0.97, deadline: 2.5) == .budgetExhausted(.configurationChanged))
        let duration = MicrophoneStartupGate()
        _ = duration.handleConfigurationChange(at: 0, deadline: 2.5)
        _ = duration.revalidationReadiness(at: 0.07, deadline: 2.5)
        check(duration.resumeStabilising(expectedEpoch: 2, at: 0.7))
        _ = duration.handleConfigurationChange(at: 0.8, deadline: 2.5)
        check(duration.revalidationReadiness(at: 1.36, deadline: 2.5) == .budgetExhausted(.configurationChanged))
        let runway = MicrophoneStartupGate()
        _ = runway.handleConfigurationChange(at: 2.25, deadline: 2.5)
        check(runway.revalidationReadiness(at: 2.25, deadline: 2.5) == .budgetExhausted(.configurationChanged))
        let slow = MicrophoneStartupGate()
        _ = slow.handleConfigurationChange(at: 2.1, deadline: 2.5)
        _ = slow.revalidationReadiness(at: 2.17, deadline: 2.5)
        check(!slow.resumeStabilising(expectedEpoch: 2, at: 2.31))
        let expired = MicrophoneStartupGate()
        _ = expired.handleConfigurationChange(at: 0, deadline: 1)
        check(expired.decision(at: 1, deadline: 1, engineRunning: false) == .failed(.configurationChanged))
        check(MicrophoneStartupRetryPolicy().maximumAttempts == 4)
        check(MicrophoneStartupRetryPolicy().totalTimeout == 10)
        check(MicrophoneStartupRetryPolicy().attemptTimeout == 2.5)
    }

    func testNotificationCommitRaceNeverReleasesInvalidEpoch() {
        for _ in 0..<100 {
            let gate = MicrophoneStartupGate()
            gate.observeConvertedBuffer(frames: 800, at: 0)
            gate.observeConvertedBuffer(frames: 800, at: 0.16)
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                if i == 0 { _ = gate.commit(at: 0.17, deadline: 2.5, engineRunning: true, expectedEpoch: 1) }
                else { _ = gate.handleConfigurationChange(at: 0.17, deadline: 2.5) }
            }
            check(!gate.acceptsBuffers)
            check(!gate.commit(at: 0.18, deadline: 2.5, engineRunning: true, expectedEpoch: 1))
            check(!gate.didCommit || gate.recordingWasInterrupted)
        }
    }

    func testPostCommitNotificationInterruptsOnceAndStaysSticky() {
        let gate = MicrophoneStartupGate()
        gate.observeConvertedBuffer(frames: 800, at: 0)
        gate.observeConvertedBuffer(frames: 800, at: 0.16)
        check(gate.commit(at: 0.17, deadline: 2.5, engineRunning: true))
        check(gate.handleConfigurationChange(at: 0.18, deadline: 2.5) == .committedInterrupted)
        check(gate.handleConfigurationChange(at: 0.19, deadline: 2.5) == .ignored)
        gate.stop()
        check(gate.recordingWasInterrupted)
        check(!gate.acceptsBuffers)
    }
}
