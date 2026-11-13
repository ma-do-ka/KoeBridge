import Foundation
import XCTest
@testable import KoeBridgeCore

final class MicrophoneStartupGateTests: XCTestCase {
    private func readyGate() -> MicrophoneStartupGate {
        let gate = MicrophoneStartupGate()
        gate.observeConvertedBuffer(frames: 800, at: 1.0)
        gate.observeConvertedBuffer(frames: 800, at: 1.16)
        return gate
    }
    private func decision(_ gate: MicrophoneStartupGate, at time: Double = 1.2,
                          deadline: Double = 3.0, running: Bool = true) -> MicrophoneStartupGate.Decision {
        gate.decision(at: time, deadline: deadline, engineRunning: running)
    }

    func testEngineStartAloneIsNotReady() {
        XCTAssertEqual(decision(MicrophoneStartupGate()), .waiting)
    }
    func testNoPCMHasDistinctFailure() {
        XCTAssertEqual(decision(MicrophoneStartupGate(), at: 3), .failed(.noBuffers))
    }
    func testOneBufferCannotBecomeReadyByWaiting() {
        let gate = MicrophoneStartupGate()
        gate.observeConvertedBuffer(frames: 800, at: 1)
        XCTAssertEqual(decision(gate), .waiting)
    }
    func testMinimumStabilityWindow() {
        let gate = readyGate()
        XCTAssertEqual(decision(gate, at: 1.1), .waiting)
        XCTAssertEqual(decision(gate), .ready)
    }
    func testValidSilentPCMIsReadyWithoutSpeech() {
        // There is deliberately no amplitude/transcript argument to the gate.
        XCTAssertEqual(decision(readyGate()), .ready)
    }
    func testZeroLengthBuffersDoNotCount() {
        let gate = MicrophoneStartupGate()
        gate.observeConvertedBuffer(frames: 0, at: 1)
        gate.observeConvertedBuffer(frames: 0, at: 1.2)
        XCTAssertEqual(decision(gate, at: 3), .failed(.noBuffers))
    }
    func testNegativeLengthIgnored() {
        let gate = MicrophoneStartupGate()
        gate.observeConvertedBuffer(frames: -1, at: 1)
        XCTAssertNil(gate.firstBufferTime)
    }
    func testOldBufferedAudioDoesNotImplyLiveInput() {
        XCTAssertEqual(decision(readyGate(), at: 1.8), .waiting)
    }
    func testLargeGapRestartsStabilityWindow() {
        let gate = readyGate()
        gate.observeConvertedBuffer(frames: 800, at: 2)
        XCTAssertEqual(decision(gate, at: 2.1), .waiting)
        gate.observeConvertedBuffer(frames: 800, at: 2.16)
        XCTAssertEqual(decision(gate, at: 2.2), .ready)
    }
    func testIntermittentInputHasDistinctFailure() {
        XCTAssertEqual(decision(readyGate(), at: 3), .failed(.unstableBuffers))
    }
    func testConfigurationChangeWhilePreparingRequestsRetryNotLiveFailure() {
        let gate = readyGate()
        XCTAssertFalse(gate.invalidate(.configurationChanged))
        XCTAssertEqual(decision(gate), .failed(.configurationChanged))
    }
    func testRouteChangeCannotBeHiddenByMoreBuffers() {
        let gate = readyGate()
        gate.invalidate(.configurationChanged)
        gate.observeConvertedBuffer(frames: 800, at: 1.2)
        XCTAssertFalse(gate.commit(at: 1.3, deadline: 3, engineRunning: true))
    }
    func testStoppedEngineCannotBecomeReady() {
        XCTAssertEqual(decision(readyGate(), running: false), .failed(.engineStopped))
    }
    func testFormatMismatchRejectsBuffers() {
        let gate = readyGate()
        gate.invalidate(.formatChanged)
        XCTAssertFalse(gate.acceptsBuffers)
        XCTAssertEqual(decision(gate), .failed(.formatChanged))
    }
    func testConversionFailureIsNotMistakenForSilence() {
        let gate = readyGate()
        gate.invalidate(.conversionFailed)
        XCTAssertEqual(decision(gate), .failed(.conversionFailed))
    }
    func testPreRollOverflowFailsClosed() {
        let gate = readyGate()
        gate.invalidate(.startupBufferOverflow)
        XCTAssertFalse(gate.commit(at: 1.2, deadline: 3, engineRunning: true))
    }
    func testCommitIsExactlyOnce() {
        let gate = readyGate()
        XCTAssertTrue(gate.commit(at: 1.2, deadline: 3, engineRunning: true))
        XCTAssertTrue(gate.didCommit)
        XCTAssertFalse(gate.commit(at: 1.3, deadline: 3, engineRunning: true))
    }
    func testPostCommitChangeNotifiesExactlyOnce() {
        let gate = readyGate()
        XCTAssertTrue(gate.commit(at: 1.2, deadline: 3, engineRunning: true))
        XCTAssertTrue(gate.invalidate(.configurationChanged))
        XCTAssertFalse(gate.invalidate(.configurationChanged))
        XCTAssertEqual(decision(gate), .failed(.configurationChanged))
    }
    func testCancelledPreparationNeverStarts() {
        let gate = readyGate()
        gate.stop()
        XCTAssertEqual(decision(gate), .stopped)
        XCTAssertFalse(gate.acceptsBuffers)
        XCTAssertFalse(gate.commit(at: 1.2, deadline: 3, engineRunning: true))
    }
    func testStopIsIdempotent() {
        let gate = readyGate()
        gate.stop(); gate.stop()
        XCTAssertTrue(gate.isStopped)
        XCTAssertFalse(gate.invalidate(.configurationChanged))
    }
    func testStoppedRecordingCanDrainAlreadyQueuedPCM() {
        let gate = readyGate()
        XCTAssertTrue(gate.commit(at: 1.2, deadline: 3, engineRunning: true))
        gate.stop()
        XCTAssertTrue(gate.didCommit)
        XCTAssertTrue(gate.acceptsBuffers)
        XCTAssertEqual(decision(gate), .stopped)
    }
    func testLateEventsFromOldAttemptDoNotAffectNewGate() {
        let old = readyGate()
        old.stop()
        let current = readyGate()
        old.invalidate(.configurationChanged)
        old.observeConvertedBuffer(frames: 800, at: 1.3)
        XCTAssertEqual(decision(current), .ready)
    }
    func testFirstBufferTimeSurvivesGapForDiagnostics() {
        let gate = readyGate()
        gate.observeConvertedBuffer(frames: 800, at: 2)
        XCTAssertEqual(gate.firstBufferTime, 1)
    }
    func testBackwardBufferTimestampIgnored() {
        let gate = readyGate()
        gate.observeConvertedBuffer(frames: 800, at: 0)
        XCTAssertEqual(decision(gate), .ready)
        XCTAssertEqual(gate.firstBufferTime, 1)
    }
    func testNonfiniteBufferTimestampIgnored() {
        let gate = MicrophoneStartupGate()
        gate.observeConvertedBuffer(frames: 800, at: .nan)
        XCTAssertNil(gate.firstBufferTime)
        XCTAssertEqual(decision(gate), .waiting)
    }
    func testNonfinitePollingTimeFailsClosed() {
        XCTAssertEqual(decision(readyGate(), at: .nan), .failed(.unstableBuffers))
    }
    func testReadinessDoesNotOutliveDeadline() {
        XCTAssertFalse(readyGate().commit(at: 3, deadline: 3, engineRunning: true))
    }
    func testReadyRecordingNotSubjectToStartupDeadline() {
        let gate = readyGate()
        XCTAssertTrue(gate.commit(at: 1.2, deadline: 3, engineRunning: true))
        XCTAssertEqual(decision(gate, at: 20), .ready)
    }
    func testRetryLimitIsFourTotalNotFourAdditional() {
        let policy = MicrophoneStartupRetryPolicy()
        XCTAssertNotNil(policy.retryDelay(after: 3, elapsed: 1))
        XCTAssertNil(policy.retryDelay(after: 4, elapsed: 1))
        XCTAssertNil(policy.retryDelay(after: 0, elapsed: 1))
    }
    func testRetryDelaysIncreaseAndRemainBounded() {
        let policy = MicrophoneStartupRetryPolicy()
        XCTAssertEqual(policy.retryDelay(after: 1, elapsed: 1)!, 0.2, accuracy: 0.0001)
        XCTAssertEqual(policy.retryDelay(after: 2, elapsed: 1)!, 0.4, accuracy: 0.0001)
        XCTAssertEqual(policy.retryDelay(after: 3, elapsed: 1)!, 0.6, accuracy: 0.0001)
    }
    func testNoRetryBeyondTotalBudget() {
        let policy = MicrophoneStartupRetryPolicy()
        XCTAssertNil(policy.retryDelay(after: 1, elapsed: 9.9))
        XCTAssertNil(policy.retryDelay(after: 2, elapsed: 10))
    }
    func testFinalAttemptUsesRemainingBudget() {
        XCTAssertEqual(MicrophoneStartupRetryPolicy().timeoutForNextAttempt(elapsed: 9), 1)
    }
    func testInvalidElapsedTimeFailsClosed() {
        XCTAssertNil(MicrophoneStartupRetryPolicy().retryDelay(after: 1, elapsed: .nan))
    }
    func testFourthAttemptCanSucceedWithoutAnotherUserAction() {
        let policy = MicrophoneStartupRetryPolicy()
        var successes = 0
        for attempt in 1...4 {
            let gate = readyGate()
            if attempt < 4 {
                gate.invalidate(.configurationChanged)
                XCTAssertEqual(decision(gate), .failed(.configurationChanged))
                XCTAssertNotNil(policy.retryDelay(after: attempt, elapsed: Double(attempt)))
                gate.stop()
            } else if gate.commit(at: 1.2, deadline: 3, engineRunning: true) {
                successes += 1
            }
        }
        XCTAssertEqual(successes, 1)
    }
    private let routeChurnFailures: [MicrophoneStartupGate.Failure] = [
        .configurationChanged, .formatChanged, .inputRouteChanged
    ]
    private func assertLegacyDelays(for failure: MicrophoneStartupGate.Failure?,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        let policy = MicrophoneStartupRetryPolicy()
        for (attempt, expected) in [(1, 0.2), (2, 0.4), (3, 0.6)] {
            let delay = try XCTUnwrap(policy.retryDelay(after: attempt, elapsed: 1, failure: failure),
                                      file: file, line: line)
            XCTAssertEqual(delay, expected, accuracy: 0.0001, file: file, line: line)
        }
    }
    func testRouteChurnCategoriesRetryWithFlatShortDelay() throws {
        let policy = MicrophoneStartupRetryPolicy()
        for failure in routeChurnFailures {
            for attempt in 1...3 {
                let delay = try XCTUnwrap(policy.retryDelay(after: attempt, elapsed: 1, failure: failure))
                XCTAssertEqual(delay, 0.05, accuracy: 0.0001)
            }
        }
    }
    func testNonChurnCategoriesKeepLegacyBackoff() throws {
        let nonChurnFailures: [MicrophoneStartupGate.Failure] = [
            .noBuffers, .unstableBuffers, .engineStopped, .bufferDropped,
            .conversionFailed, .startupBufferOverflow, .buffersInterrupted
        ]
        for failure in nonChurnFailures {
            try assertLegacyDelays(for: failure)
        }
    }
    func testNilFailureKeepsLegacyBackoff() throws {
        try assertLegacyDelays(for: nil)
    }
    func testRouteChurnStillRespectsAttemptLimitAndBudget() throws {
        let policy = MicrophoneStartupRetryPolicy()
        for failure in routeChurnFailures {
            XCTAssertNil(policy.retryDelay(after: 0, elapsed: 1, failure: failure))
            XCTAssertNil(policy.retryDelay(after: 4, elapsed: 1, failure: failure))
            XCTAssertNil(policy.retryDelay(after: 1, elapsed: 9.99, failure: failure))
            XCTAssertNil(policy.retryDelay(after: 1, elapsed: 10, failure: failure))
            XCTAssertNil(policy.retryDelay(after: 1, elapsed: .nan, failure: failure))
            let nearBudgetDelay = try XCTUnwrap(policy.retryDelay(after: 1, elapsed: 9.9, failure: failure))
            XCTAssertEqual(nearBudgetDelay, 0.05, accuracy: 0.0001)
        }
    }
    func testConcurrentStopAndCallbacksCannotResurrectPreparation() {
        let gate = MicrophoneStartupGate()
        DispatchQueue.concurrentPerform(iterations: 1_000) { i in
            if i % 5 == 0 { gate.stop() }
            else if i % 7 == 0 { gate.invalidate(.configurationChanged) }
            else { gate.observeConvertedBuffer(frames: 800, at: Double(i) / 1_000) }
        }
        XCTAssertTrue(gate.isStopped)
        XCTAssertFalse(gate.commit(at: 2, deadline: 3, engineRunning: true))
    }
    func testTwoEarlyPacketsCannotBecomeStableByWaitingWithoutNewAudio() {
        let gate = MicrophoneStartupGate()
        gate.observeConvertedBuffer(frames: 800, at: 1)
        gate.observeConvertedBuffer(frames: 800, at: 1.01)
        XCTAssertEqual(decision(gate, at: 1.25), .waiting)
        gate.observeConvertedBuffer(frames: 800, at: 1.26)
        XCTAssertEqual(decision(gate, at: 1.27), .ready)
    }
    func testInputRouteChangeIsNotMislabelledAsSilence() {
        let gate = readyGate()
        XCTAssertFalse(gate.invalidate(.inputRouteChanged))
        XCTAssertEqual(decision(gate), .failed(.inputRouteChanged))
    }
    func testMediaModeFormatSwitchBeforeReadyNeedsFreshAttempt() {
        let old = readyGate()
        old.invalidate(.formatChanged)
        old.observeConvertedBuffer(frames: 800, at: 1.4)
        XCTAssertFalse(old.commit(at: 1.4, deadline: 3, engineRunning: true))
        let current = readyGate()
        XCTAssertTrue(current.commit(at: 1.2, deadline: 3, engineRunning: true))
    }
    func testMediaModeFormatSwitchAfterReadyRemainsExplicitFailure() {
        let gate = readyGate()
        XCTAssertTrue(gate.commit(at: 1.2, deadline: 3, engineRunning: true))
        XCTAssertTrue(gate.invalidate(.formatChanged))
        XCTAssertFalse(gate.acceptsBuffers)
        XCTAssertEqual(decision(gate), .failed(.formatChanged))
    }
    func testStoppedAttemptCannotCommitAfterRetryDelay() {
        let gate = readyGate()
        gate.stop()
        gate.observeConvertedBuffer(frames: 800, at: 2)
        XCTAssertFalse(gate.commit(at: 2.1, deadline: 3, engineRunning: true))
    }

    private func committedGate() -> MicrophoneStartupGate {
        let gate = readyGate()
        XCTAssertTrue(gate.commit(at: 1.2, deadline: 3, engineRunning: true))
        return gate
    }
    func testRecordingWatchdogDoesNotInterfereWithPreparation() {
        XCTAssertNil(readyGate().recordingFailure(at: 20, engineRunning: false))
    }
    func testRecordingWatchdogDetectsMissingPCMEvenWhenEngineRuns() {
        XCTAssertEqual(committedGate().recordingFailure(at: 2.2, engineRunning: true), .buffersInterrupted)
    }
    func testRecordingWatchdogAcceptsSilentButFreshPCM() {
        let gate = committedGate()
        gate.observeConvertedBuffer(frames: 800, at: 2.2)
        XCTAssertNil(gate.recordingFailure(at: 2.3, engineRunning: true))
    }
    func testRecordingWatchdogAllowsShortSchedulingGap() {
        XCTAssertNil(committedGate().recordingFailure(at: 1.9, engineRunning: true))
    }
    func testRecordingWatchdogDetectsEngineStopped() {
        XCTAssertEqual(committedGate().recordingFailure(at: 1.3, engineRunning: false), .engineStopped)
    }
    func testRecordingWatchdogDoesNotTurnNormalStopIntoError() {
        let gate = committedGate(); gate.stop()
        XCTAssertNil(gate.recordingFailure(at: 20, engineRunning: false))
    }
    func testRecordingWatchdogDoesNotRepeatKnownFailure() {
        let gate = committedGate(); gate.invalidate(.buffersInterrupted)
        XCTAssertNil(gate.recordingFailure(at: 20, engineRunning: true))
    }
    func testRecordingWatchdogInvalidClockFailsClosed() {
        XCTAssertEqual(committedGate().recordingFailure(at: .nan, engineRunning: true), .unstableBuffers)
    }
    func testRecordingWatchdogAcceptsBufferNewerThanSampledClock() {
        let gate = committedGate()
        gate.observeConvertedBuffer(frames: 800, at: 10.0)
        XCTAssertNil(gate.recordingFailure(at: 9.9, engineRunning: true))
        XCTAssertEqual(gate.recordingFailure(at: 9.9, engineRunning: false), .engineStopped)
    }
    func testRecordingWatchdogGapBoundaryStillFailsClosed() {
        let gate = committedGate()
        gate.observeConvertedBuffer(frames: 800, at: 10.0)
        XCTAssertEqual(gate.recordingFailure(at: 11.0, engineRunning: true), .buffersInterrupted)
    }
    func testRecordingWatchdogInvalidInputsFailClosedEvenWithNewerBuffer() {
        let gate = committedGate()
        gate.observeConvertedBuffer(frames: 800, at: 10.0)
        for time in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(gate.recordingFailure(at: time, engineRunning: true), .unstableBuffers)
        }
        for gap in [Double.nan, Double.infinity, -Double.infinity, 0, -1] {
            XCTAssertEqual(gate.recordingFailure(at: 9.9, engineRunning: true, maximumGap: gap),
                           .unstableBuffers)
        }
    }
    func testRecordingWatchdogCannotResurrectStoppedSession() {
        let gate = committedGate(); gate.stop()
        gate.observeConvertedBuffer(frames: 800, at: 20)
        XCTAssertEqual(decision(gate, at: 21), .stopped)
        XCTAssertNil(gate.recordingFailure(at: 21, engineRunning: true))
    }

}

final class MicrophoneStartupRaceTests: XCTestCase {
    private func committedGate() -> MicrophoneStartupGate {
        let gate = MicrophoneStartupGate()
        gate.observeConvertedBuffer(frames: 800, at: 1)
        gate.observeConvertedBuffer(frames: 800, at: 1.2)
        XCTAssertTrue(gate.commit(at: 1.21, deadline: 3, engineRunning: true))
        return gate
    }

    func testInterruptionSurvivesUserStopBeforeUICallback() {
        let gate = committedGate()
        XCTAssertTrue(gate.invalidate(.configurationChanged))
        gate.stop()
        XCTAssertTrue(gate.recordingWasInterrupted)
        XCTAssertFalse(gate.acceptsBuffers)
    }

    func testPreparationFailureIsNotARecordedInterruption() {
        let gate = MicrophoneStartupGate()
        gate.invalidate(.noBuffers)
        gate.stop()
        XCTAssertFalse(gate.recordingWasInterrupted)
    }

    func testNormalStopIsNotFalselyReportedAsAudioLoss() {
        let gate = committedGate()
        gate.stop()
        XCTAssertFalse(gate.recordingWasInterrupted)
        XCTAssertTrue(gate.acceptsBuffers)
    }

    func testTeardownNotificationDoesNotPoisonNormalStop() {
        let gate = committedGate()
        gate.stop()
        XCTAssertFalse(gate.invalidate(.configurationChanged))
        XCTAssertFalse(gate.recordingWasInterrupted)
    }

    func testMissingPCMFailureSurvivesStop() {
        let gate = committedGate()
        let failure = gate.recordingFailure(at: 2.3, engineRunning: true)
        XCTAssertEqual(failure, .buffersInterrupted)
        XCTAssertTrue(gate.invalidate(failure!))
        gate.stop()
        XCTAssertTrue(gate.recordingWasInterrupted)
    }

    func testStaleTapTimestampsCannotBecomeReadyDuringDelayedConversion() {
        let gate = MicrophoneStartupGate()
        // Both packets were captured before a processing backlog. Polling at
        // 2s must not treat the conversion time as a new microphone arrival.
        gate.observeConvertedBuffer(frames: 800, at: 1)
        gate.observeConvertedBuffer(frames: 800, at: 1.2)
        XCTAssertEqual(gate.decision(at: 2, deadline: 3, engineRunning: true), .waiting)
        XCTAssertFalse(gate.commit(at: 2, deadline: 3, engineRunning: true))
    }

    func testOutOfOrderOldBufferDoesNotRefreshRecordingWatchdog() {
        let gate = committedGate()
        gate.observeConvertedBuffer(frames: 800, at: 1.1)
        XCTAssertEqual(gate.recordingFailure(at: 2.3, engineRunning: true), .buffersInterrupted)
    }

    func testDroppedPreparationBufferCannotCommit() {
        let gate = MicrophoneStartupGate()
        gate.observeConvertedBuffer(frames: 800, at: 1)
        gate.observeConvertedBuffer(frames: 800, at: 1.2)
        gate.invalidate(.bufferDropped)
        XCTAssertFalse(gate.commit(at: 1.21, deadline: 3, engineRunning: true))
        XCTAssertEqual(gate.decision(at: 1.21, deadline: 3, engineRunning: true), .failed(.bufferDropped))
    }

    func testFirstInterruptionReasonIsPreserved() {
        let gate = committedGate()
        XCTAssertTrue(gate.invalidate(.inputRouteChanged))
        XCTAssertFalse(gate.invalidate(.conversionFailed))
        XCTAssertEqual(gate.decision(at: 1.3, deadline: 3, engineRunning: true), .failed(.inputRouteChanged))
    }
}

final class MicrophoneStopLatchTests: XCTestCase {
    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var owners = 0
        private var values: [Int] = []
        func own() { lock.lock(); owners += 1; lock.unlock() }
        func receive(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
        var snapshot: (Int, [Int]) {
            lock.lock(); defer { lock.unlock() }
            return (owners, values)
        }
    }

    func testFirstStopOwnsTeardownButDoesNotCompleteEarly() {
        let latch = MicrophoneStopLatch()
        var results: [Int] = []
        XCTAssertTrue(latch.begin { results.append($0) })
        XCTAssertEqual(results, [])
        latch.finish(losses: 2)
        XCTAssertEqual(results, [2])
    }

    func testRepeatedStopWaitsForTheSameFinalization() {
        let latch = MicrophoneStopLatch()
        var results: [Int] = []
        XCTAssertTrue(latch.begin { results.append($0) })
        XCTAssertFalse(latch.begin { results.append($0) })
        XCTAssertEqual(results, [])
        latch.finish(losses: 7)
        XCTAssertEqual(results, [7, 7])
    }

    func testRepeatedFinishCannotChangeFinalReceipt() {
        let latch = MicrophoneStopLatch()
        var results: [Int] = []
        XCTAssertTrue(latch.begin { results.append($0) })
        latch.finish(losses: 2)
        latch.finish(losses: 0)
        XCTAssertFalse(latch.begin { results.append($0) })
        XCTAssertEqual(results, [2, 2])
    }

    func testLateStopReceivesStoredResultImmediately() {
        let latch = MicrophoneStopLatch()
        XCTAssertTrue(latch.begin(completion: nil))
        latch.finish(losses: 3)
        var value: Int?
        XCTAssertFalse(latch.begin { value = $0 })
        XCTAssertEqual(value, 3)
    }

    func testCompletionCanReenterWithoutDeadlock() {
        let latch = MicrophoneStopLatch()
        var values: [Int] = []
        XCTAssertTrue(latch.begin { value in
            values.append(value)
            XCTAssertFalse(latch.begin { values.append($0) })
        })
        latch.finish(losses: 4)
        XCTAssertEqual(values, [4, 4])
    }

    func testFinishWithoutStartDoesNotFabricateAReceipt() {
        let latch = MicrophoneStopLatch()
        latch.finish(losses: 9)
        var values: [Int] = []
        XCTAssertTrue(latch.begin { values.append($0) })
        XCTAssertEqual(values, [])
        latch.finish(losses: 1)
        XCTAssertEqual(values, [1])
    }

    func testConcurrentStopsHaveOneOwnerAndEveryCallbackRunsOnce() {
        let latch = MicrophoneStopLatch()
        let counts = Counts()
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            if latch.begin(completion: { counts.receive($0) }) { counts.own() }
        }
        XCTAssertEqual(counts.snapshot.0, 1)
        XCTAssertEqual(counts.snapshot.1.count, 0)
        latch.finish(losses: 5)
        XCTAssertEqual(counts.snapshot.1.count, 1_000)
        XCTAssertTrue(counts.snapshot.1.allSatisfy { $0 == 5 })
    }

    func testConcurrentFinishesDeliverExactlyOneConsistentResult() {
        let latch = MicrophoneStopLatch()
        let counts = Counts()
        for _ in 0..<100 { _ = latch.begin { counts.receive($0) } }
        DispatchQueue.concurrentPerform(iterations: 100) { latch.finish(losses: $0) }
        let results = counts.snapshot.1
        XCTAssertEqual(results.count, 100)
        XCTAssertEqual(Set(results).count, 1)
    }

    func testCallbackMayRequestFinishAgain() {
        let latch = MicrophoneStopLatch()
        var count = 0
        XCTAssertTrue(latch.begin { _ in
            count += 1
            latch.finish(losses: 999)
        })
        latch.finish(losses: 0)
        XCTAssertEqual(count, 1)
    }
}

final class MicrophoneEngineLifetimeTests: XCTestCase {
    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0
        private var destroyed = 0
        func created() { lock.lock(); made += 1; lock.unlock() }
        func deallocated() { lock.lock(); destroyed += 1; lock.unlock() }
        var snapshot: (made: Int, destroyed: Int) {
            lock.lock(); defer { lock.unlock() }
            return (made, destroyed)
        }
    }
    private final class Engine {
        let counters: Counters
        init(_ counters: Counters) { self.counters = counters; counters.created() }
        deinit { counters.deallocated() }
    }
    private func owner(_ counters: Counters) -> MicrophoneEngineLifetime<Engine> {
        MicrophoneEngineLifetime { Engine(counters) }
    }

    func testOwnerDoesNotCreateAnIdleMicrophone() {
        let counts = Counters()
        let lifetime = owner(counts)
        XCTAssertEqual(counts.snapshot.made, 0)
        withExtendedLifetime(lifetime) {}
    }

    func testFirstLeaseCreatesOneEngine() throws {
        let counts = Counters()
        let lifetime = owner(counts)
        let lease = try XCTUnwrap(lifetime.acquire())
        XCTAssertEqual(counts.snapshot.made, 1)
        XCTAssertTrue(lifetime.release(token: lease.token))
    }

    func testConcurrentAttemptCannotStealOwnedEngine() throws {
        let lifetime = owner(Counters())
        let lease = try XCTUnwrap(lifetime.acquire())
        XCTAssertNil(lifetime.acquire())
        XCTAssertTrue(lifetime.release(token: lease.token))
        XCTAssertNotNil(lifetime.acquire())
    }

    func testLeaseReturnDoesNotDeallocateStoppedEngine() throws {
        let counts = Counters()
        let lifetime = owner(counts)
        weak var watched: Engine?
        do {
            let lease = try XCTUnwrap(lifetime.acquire())
            watched = lease.resource
            XCTAssertTrue(lifetime.release(token: lease.token))
        }
        XCTAssertNotNil(watched)
        XCTAssertEqual(counts.snapshot.destroyed, 0)
        withExtendedLifetime(lifetime) {}
    }

    func testRetryUsesSameEngineAndDifferentToken() throws {
        let counts = Counters()
        let lifetime = owner(counts)
        let first = try XCTUnwrap(lifetime.acquire())
        XCTAssertTrue(lifetime.release(token: first.token))
        let second = try XCTUnwrap(lifetime.acquire())
        XCTAssertTrue(first.resource === second.resource)
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertEqual(counts.snapshot.made, 1)
    }

    func testStaleStopCannotReleaseNewRecording() throws {
        let lifetime = owner(Counters())
        let first = try XCTUnwrap(lifetime.acquire())
        XCTAssertTrue(lifetime.release(token: first.token))
        let next = try XCTUnwrap(lifetime.acquire())
        XCTAssertFalse(lifetime.release(token: first.token))
        XCTAssertNil(lifetime.acquire())
        XCTAssertTrue(lifetime.release(token: next.token))
    }

    func testUnknownTokenCannotReleaseActiveRecording() throws {
        let lifetime = owner(Counters())
        let lease = try XCTUnwrap(lifetime.acquire())
        XCTAssertFalse(lifetime.release(token: UUID()))
        XCTAssertNil(lifetime.acquire())
        XCTAssertTrue(lifetime.release(token: lease.token))
    }

    func testDuplicateLeaseReturnIsIdempotent() throws {
        let lifetime = owner(Counters())
        let lease = try XCTUnwrap(lifetime.acquire())
        XCTAssertTrue(lifetime.release(token: lease.token))
        XCTAssertFalse(lifetime.release(token: lease.token))
    }

    func testFailedPreparationRetryDoesNotAccumulateEngines() throws {
        let counts = Counters()
        let lifetime = owner(counts)
        for _ in 0..<4 {
            let lease = try XCTUnwrap(lifetime.acquire())
            // A failed capture drops its per-attempt ownership after teardown.
            XCTAssertTrue(lifetime.release(token: lease.token))
        }
        XCTAssertEqual(counts.snapshot.made, 1)
        XCTAssertEqual(counts.snapshot.destroyed, 0)
        withExtendedLifetime(lifetime) {}
    }

    func testManyRecordingsStillRetainOnlyOneEngine() throws {
        let counts = Counters()
        let lifetime = owner(counts)
        for _ in 0..<2_000 {
            let lease = try XCTUnwrap(lifetime.acquire())
            XCTAssertTrue(lifetime.release(token: lease.token))
        }
        XCTAssertEqual(counts.snapshot.made, 1)
        XCTAssertEqual(counts.snapshot.destroyed, 0)
        withExtendedLifetime(lifetime) {}
    }

    func testDelayedPropertyObserverStillHasLiveEngineAfterCaptureDropsLease() throws {
        let counts = Counters()
        let lifetime = owner(counts)
        var callback: (() -> Bool)?
        do {
            let lease = try XCTUnwrap(lifetime.acquire())
            callback = { [weak engine = lease.resource] in engine != nil }
            XCTAssertTrue(lifetime.release(token: lease.token))
        }
        // A lifetime simulation only, not execution of Apple's AVAudioIOUnit.
        XCTAssertEqual(callback?(), true)
        XCTAssertEqual(counts.snapshot.destroyed, 0)
        withExtendedLifetime(lifetime) {}
    }

    func testResourceLifetimeEndsOnlyWhenOwnerAndLeasesEnd() throws {
        let counts = Counters()
        weak var watched: Engine?
        do {
            let lifetime = owner(counts)
            let lease = try XCTUnwrap(lifetime.acquire())
            watched = lease.resource
            XCTAssertTrue(lifetime.release(token: lease.token))
        }
        XCTAssertNil(watched)
        XCTAssertEqual(counts.snapshot.destroyed, 1)
    }

    func testOneWinnerUnderConcurrentAcquire() {
        let counts = Counters()
        let lifetime = owner(counts)
        // No winner releases until after all attempts, so exactly one can win.
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var tokens: [UUID] = []
            func add(_ token: UUID) { lock.lock(); tokens.append(token); lock.unlock() }
        }
        let result = Results()
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            if let lease = lifetime.acquire() { result.add(lease.token) }
        }
        XCTAssertEqual(result.tokens.count, 1)
        XCTAssertEqual(counts.snapshot.made, 1)
        XCTAssertEqual(counts.snapshot.destroyed, 0)
        if let token = result.tokens.first { XCTAssertTrue(lifetime.release(token: token)) }
    }

    func testConcurrentStaleReleasesCannotUnblockCurrentLease() throws {
        let lifetime = owner(Counters())
        let previous = try XCTUnwrap(lifetime.acquire())
        XCTAssertTrue(lifetime.release(token: previous.token))
        let active = try XCTUnwrap(lifetime.acquire())
        let staleToken = previous.token
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            XCTAssertFalse(lifetime.release(token: staleToken))
        }
        XCTAssertNil(lifetime.acquire())
        XCTAssertTrue(lifetime.release(token: active.token))
    }
}
