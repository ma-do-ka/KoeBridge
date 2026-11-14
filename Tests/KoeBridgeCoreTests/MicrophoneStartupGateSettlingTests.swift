import Foundation
import XCTest
@testable import KoeBridgeCore

extension MicrophoneStartupGateTests {
    func testSameFormatChurnRequiresRevalidationAndFreshStability() {
        let gate = MicrophoneStartupGate()
        let token = gate.captureTokenForTap(tapGeneration: 1)!
        gate.observeConvertedBuffer(frames: 800, at: 0)
        gate.observeConvertedBuffer(frames: 800, at: 0.16)
        XCTAssertTrue(gate.handleConfigurationChange(at: 0.17, deadline: 2.5) == .revalidate(epoch: 2, firstInBurst: true))
        XCTAssertTrue(!gate.commit(at: 0.18, deadline: 2.5, engineRunning: true, expectedEpoch: 1))
        XCTAssertTrue(!gate.accepts(token))
        XCTAssertTrue(gate.captureTokenForTap(tapGeneration: 1) == nil)
        XCTAssertTrue(gate.revalidationReadiness(at: 0.24, deadline: 2.5) == .readyToRevalidate(epoch: 2))
        XCTAssertTrue(gate.resumeStabilising(expectedEpoch: 2, at: 0.24))
        XCTAssertTrue(gate.observeConvertedBuffer(frames: 800, at: 0.25, epoch: 1) == .dropped)
        XCTAssertTrue(gate.observeConvertedBuffer(frames: 800, at: 0.26, epoch: 2) == .buffered)
        XCTAssertTrue(gate.observeConvertedBuffer(frames: 800, at: 0.30, epoch: 2) == .buffered)
        XCTAssertTrue(gate.decision(at: 0.31, deadline: 2.5, engineRunning: true) == .waiting)
        XCTAssertTrue(gate.observeConvertedBuffer(frames: 800, at: 0.42, epoch: 2) == .buffered)
        XCTAssertTrue(!gate.commit(at: 0.43, deadline: 2.5, engineRunning: true, expectedEpoch: 1))
        XCTAssertTrue(gate.commit(at: 0.43, deadline: 2.5, engineRunning: true, expectedEpoch: 2))
        XCTAssertTrue(gate.settlingSnapshot(at: 0.43).readyViaSettling)
        XCTAssertTrue(gate.currentTapGeneration == 1)
    }

    func testConfiguringChurnAndCancellationCannotResurrect() {
        let gate = MicrophoneStartupGate(configuring: true)
        XCTAssertTrue(gate.currentPhase == .configuring(epoch: 1, churnPending: false))
        _ = gate.handleConfigurationChange(at: 0.1, deadline: 2.5)
        XCTAssertTrue(gate.currentPhase == .configuring(epoch: 2, churnPending: true))
        XCTAssertTrue(gate.captureTokenForTap(tapGeneration: 1) == nil)
        XCTAssertTrue(gate.revalidationReadiness(at: 0.2, deadline: 2.5) == .notRevalidating)
        _ = gate.finishConfiguring(at: 0.2)
        XCTAssertTrue(gate.revalidationReadiness(at: 0.21, deadline: 2.5) == .readyToRevalidate(epoch: 2))
        gate.stop()
        XCTAssertTrue(!gate.resumeStabilising(expectedEpoch: 2, at: 0.22))
        XCTAssertTrue(gate.finishConfiguring(at: 0.23) == .stopped)
        XCTAssertTrue(gate.handleConfigurationChange(at: 0.24, deadline: 2.5) == .ignored)
        XCTAssertTrue(!gate.commit(at: 0.4, deadline: 2.5, engineRunning: true))
    }

    func testBurstCoalescingAndChecklistRace() {
        let gate = MicrophoneStartupGate()
        _ = gate.handleConfigurationChange(at: 0.1, deadline: 2.5)
        _ = gate.handleConfigurationChange(at: 0.14, deadline: 2.5)
        if case .debouncePending(let remaining) = gate.revalidationReadiness(at: 0.18, deadline: 2.5) {
            XCTAssertTrue(abs(remaining - 0.02) < 0.0001)
        } else { XCTAssertTrue(false) }
        XCTAssertTrue(gate.revalidationReadiness(at: 0.21, deadline: 2.5) == .readyToRevalidate(epoch: 3))
        _ = gate.handleConfigurationChange(at: 0.22, deadline: 2.5)
        XCTAssertTrue(!gate.resumeStabilising(expectedEpoch: 3, at: 0.23))
        gate.invalidate(.engineStopped, expectedEpoch: 3)
        XCTAssertTrue(gate.currentPhase == .revalidating(epoch: 4, pendingSince: 0.1, lastChurnAt: 0.22))
        _ = gate.handleConfigurationChange(at: 0.27, deadline: 2.5)
        _ = gate.handleConfigurationChange(at: 0.32, deadline: 2.5)
        XCTAssertTrue(gate.revalidationReadiness(at: 0.351, deadline: 2.5) == .readyToRevalidate(epoch: 6))
        XCTAssertTrue(gate.resumeStabilising(expectedEpoch: 6, at: 0.36))
    }

    func testEverySettlingBudgetTerminatesInsideAttempt() {
        let churn = MicrophoneStartupGate()
        for i in 0..<16 { _ = churn.handleConfigurationChange(at: Double(i) * 0.001, deadline: 2.5) }
        XCTAssertTrue(churn.handleConfigurationChange(at: 0.017, deadline: 2.5) == .budgetExhausted(.configurationChanged))
        let count = MicrophoneStartupGate()
        for i in 0..<4 {
            let start = Double(i) * 0.2
            _ = count.handleConfigurationChange(at: start, deadline: 2.5)
            XCTAssertTrue(count.revalidationReadiness(at: start + 0.07, deadline: 2.5) == .readyToRevalidate(epoch: UInt64(i + 2)))
            XCTAssertTrue(count.resumeStabilising(expectedEpoch: UInt64(i + 2), at: start + 0.08))
        }
        _ = count.handleConfigurationChange(at: 0.9, deadline: 2.5)
        XCTAssertTrue(count.revalidationReadiness(at: 0.97, deadline: 2.5) == .budgetExhausted(.configurationChanged))
        let duration = MicrophoneStartupGate()
        _ = duration.handleConfigurationChange(at: 0, deadline: 2.5)
        _ = duration.revalidationReadiness(at: 0.07, deadline: 2.5)
        XCTAssertTrue(duration.resumeStabilising(expectedEpoch: 2, at: 0.7))
        _ = duration.handleConfigurationChange(at: 0.8, deadline: 2.5)
        XCTAssertTrue(duration.revalidationReadiness(at: 1.36, deadline: 2.5) == .budgetExhausted(.configurationChanged))
        let runway = MicrophoneStartupGate()
        _ = runway.handleConfigurationChange(at: 2.25, deadline: 2.5)
        XCTAssertTrue(runway.revalidationReadiness(at: 2.25, deadline: 2.5) == .budgetExhausted(.configurationChanged))
        let slow = MicrophoneStartupGate()
        _ = slow.handleConfigurationChange(at: 2.1, deadline: 2.5)
        _ = slow.revalidationReadiness(at: 2.17, deadline: 2.5)
        XCTAssertTrue(!slow.resumeStabilising(expectedEpoch: 2, at: 2.31))
        let expired = MicrophoneStartupGate()
        _ = expired.handleConfigurationChange(at: 0, deadline: 1)
        XCTAssertTrue(expired.decision(at: 1, deadline: 1, engineRunning: false) == .failed(.configurationChanged))
        XCTAssertTrue(MicrophoneStartupRetryPolicy().maximumAttempts == 4)
        XCTAssertTrue(MicrophoneStartupRetryPolicy().totalTimeout == 10)
        XCTAssertTrue(MicrophoneStartupRetryPolicy().attemptTimeout == 2.5)
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
            XCTAssertTrue(!gate.acceptsBuffers)
            XCTAssertTrue(!gate.commit(at: 0.18, deadline: 2.5, engineRunning: true, expectedEpoch: 1))
            XCTAssertTrue(!gate.didCommit || gate.recordingWasInterrupted)
        }
    }

    func testRevalidationCancellationRaceAndStoppedTiming() {
        for _ in 0..<100 {
            let gate = MicrophoneStartupGate()
            _ = gate.handleConfigurationChange(at: 0, deadline: 2.5)
            _ = gate.revalidationReadiness(at: 0.07, deadline: 2.5)
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                if i == 0 { _ = gate.resumeStabilising(expectedEpoch: 2, at: 0.08) }
                else { gate.stop(at: 0.08) }
            }
            XCTAssertTrue(gate.currentPhase == .stopped)
            XCTAssertTrue(gate.captureTokenForTap(tapGeneration: 1) == nil)
            XCTAssertTrue(gate.observeConvertedBuffer(frames: 800, at: 0.1, epoch: 2) == .dropped)
            XCTAssertTrue(!gate.commit(at: 0.3, deadline: 2.5, engineRunning: true))
            XCTAssertTrue(abs(gate.settlingSnapshot(at: 10).duration - 0.08) < 0.0001)
        }
    }

    func testOldEpochCannotRefreshReadyStreamAndTapGenerationMustMatch() {
        let gate = MicrophoneStartupGate()
        XCTAssertTrue(gate.captureTokenForTap(tapGeneration: 0) == nil)
        _ = gate.handleConfigurationChange(at: 0, deadline: 2.5)
        _ = gate.revalidationReadiness(at: 0.07, deadline: 2.5)
        _ = gate.revalidationReadiness(at: 0.071, deadline: 2.5)
        XCTAssertTrue(gate.settlingSnapshot(at: 0.072).revalidations == 1)
        _ = gate.resumeStabilising(expectedEpoch: 2, at: 0.08)
        _ = gate.observeConvertedBuffer(frames: 800, at: 0.1, epoch: 2)
        _ = gate.observeConvertedBuffer(frames: 800, at: 0.3, epoch: 2)
        XCTAssertTrue(gate.decision(at: 0.31, deadline: 2.5, engineRunning: true) == .ready)
        XCTAssertTrue(gate.observeConvertedBuffer(frames: 800, at: 0.7, epoch: 1) == .dropped)
        XCTAssertTrue(gate.decision(at: 0.71, deadline: 2.5, engineRunning: true) == .waiting)
    }

    func testPostCommitNotificationInterruptsOnceAndStaysSticky() {
        let gate = MicrophoneStartupGate()
        gate.observeConvertedBuffer(frames: 800, at: 0)
        gate.observeConvertedBuffer(frames: 800, at: 0.16)
        XCTAssertTrue(gate.commit(at: 0.17, deadline: 2.5, engineRunning: true))
        XCTAssertTrue(gate.handleConfigurationChange(at: 0.18, deadline: 2.5) == .committedInterrupted)
        XCTAssertTrue(gate.handleConfigurationChange(at: 0.19, deadline: 2.5) == .ignored)
        gate.stop()
        XCTAssertTrue(gate.recordingWasInterrupted)
        XCTAssertTrue(!gate.acceptsBuffers)
    }
}
