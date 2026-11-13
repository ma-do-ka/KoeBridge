import Foundation
import XCTest
@testable import KoeBridgeCore

final class MicrophonePreparationDiagnosticsTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [MicrophonePreparationDiagnostics.Entry] = []
        func append(_ entry: MicrophonePreparationDiagnostics.Entry) {
            lock.lock(); entries.append(entry); lock.unlock()
        }
        var values: [MicrophonePreparationDiagnostics.Entry] {
            lock.lock(); defer { lock.unlock() }; return entries
        }
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now: Double = 100
        func read() -> Double { lock.lock(); defer { lock.unlock() }; return now }
        func set(_ time: Double) { lock.lock(); now = time; lock.unlock() }
    }
    private func make() -> (MicrophonePreparationDiagnostics, Recorder, Clock) {
        let clock = Clock(), records = Recorder()
        let trace = MicrophonePreparationDiagnostics(clock: { clock.read() }, sink: { records.append($0) })
        return (trace, records, clock)
    }
    func testBlockedNativeCallRemainsVisibleToIndependentPoll() {
        let (trace, records, clock) = make()
        trace.begin(.enginePrepare)
        clock.set(103)
        trace.poll()
        let entry = records.values.last!
        XCTAssertEqual(entry.stage, .enginePrepare)
        XCTAssertEqual(entry.kind, .waiting)
        XCTAssertTrue(entry.pending)
        XCTAssertEqual(entry.stageMS, 3_000)
        XCTAssertEqual(entry.inputBuffers, 0)
    }
    func testNotificationDoesNotReplaceBlockingCall() {
        let (trace, records, _) = make()
        trace.begin(.deviceSet)
        trace.note(.configurationChanged)
        trace.poll()
        XCTAssertEqual(records.values.last?.stage, .deviceSet)
        XCTAssertEqual(records.values.last?.pending, true)
    }
    func testCancelRequestDoesNotFalsifyNativeCallCompletion() {
        let (trace, records, _) = make()
        trace.begin(.engineStart)
        trace.note(.stopRequested)
        trace.poll()
        XCTAssertEqual(records.values.last?.stage, .engineStart)
        XCTAssertTrue(records.values.last!.pending)
    }
    func testCompletionClosesOnlyItsOwnStage() {
        let (trace, records, _) = make()
        trace.begin(.deviceAfter)
        trace.end(.deviceBefore)
        trace.poll()
        XCTAssertTrue(records.values.last!.pending)
        trace.end(.deviceAfter, code: 1, matched: false)
        XCTAssertFalse(records.values.last!.pending)
        XCTAssertEqual(records.values.last?.matched, false)
    }
    func testNativeFailureNumberIsPreservedWithoutErrorText() {
        let (trace, records, _) = make()
        trace.begin(.deviceSet)
        trace.end(.deviceSet, code: -10879)
        XCTAssertTrue(records.values.last!.rendered.contains("code=-10879"))
        XCTAssertFalse(records.values.last!.rendered.contains("matches="))
    }
    func testRealtimeCounterDoesNotEmitEvents() {
        let (trace, records, _) = make()
        for _ in 0..<5_000 { trace.observeInput(frames: 1_024, at: 100) }
        XCTAssertEqual(records.values.count, 0)
        trace.poll()
        XCTAssertEqual(records.values.last?.inputBuffers, 5_000)
        XCTAssertEqual(records.values.last?.convertedBuffers, 0)
    }
    func testInputAndConversionAreReportedSeparately() {
        let (trace, records, clock) = make()
        trace.observeInput(frames: 1_024, at: 100.25)
        trace.observeInput(frames: 1_024, at: 100.5)
        trace.observeConverted(frames: 341)
        clock.set(101)
        trace.poll()
        let entry = records.values.last!
        XCTAssertEqual(entry.inputBuffers, 2)
        XCTAssertEqual(entry.convertedBuffers, 1)
        XCTAssertEqual(entry.firstBufferMS, 250)
        XCTAssertEqual(entry.lastBufferAgeMS, 500)
    }
    func testStartupMeasurementsAreCountersUntilNextEvent() {
        let (trace, records, _) = make()
        trace.observeStartupBuffer(isExactlyZero: true)
        trace.observeStartupBuffer(isExactlyZero: false)
        trace.observeStartupBuffer(isExactlyZero: true)
        trace.discardStartup(duration: 0.25)
        XCTAssertTrue(records.values.isEmpty)
        trace.end(.processingDrain)
        let entry = records.values.last!
        XCTAssertEqual(entry.zeroStartupBuffers, 2)
        XCTAssertEqual(entry.discardedStartupMS, 250)
        XCTAssertTrue(entry.rendered.contains("zero_startup_buffers=2"))
        XCTAssertTrue(entry.rendered.contains("discarded_startup_ms=250"))
    }
    func testSuccessfulStartupReportsNoDiscardedAudio() {
        let (trace, records, _) = make()
        trace.observeStartupBuffer(isExactlyZero: true)
        trace.note(.ready)
        XCTAssertEqual(records.values.last?.discardedStartupMS, 0)
        XCTAssertEqual(records.values.last?.zeroStartupBuffers, 1)
    }
    func testFinishedTraceRejectsLateStartupMeasurements() {
        let (trace, records, _) = make()
        trace.finish()
        trace.observeStartupBuffer(isExactlyZero: true)
        trace.discardStartup(duration: 1)
        trace.poll()
        XCTAssertEqual(records.values.count, 1)
        XCTAssertEqual(records.values.last?.zeroStartupBuffers, 0)
        XCTAssertEqual(records.values.last?.discardedStartupMS, 0)
    }
    func testOldBufferDoesNotRefreshFreshness() {
        let (trace, records, clock) = make()
        trace.observeInput(frames: 1, at: 100.5)
        trace.observeInput(frames: 1, at: 100.1)
        clock.set(101)
        trace.poll()
        XCTAssertEqual(records.values.last?.lastBufferAgeMS, 500)
    }
    func testEmptyAndInvalidBufferObservationsAreIgnored() {
        let (trace, records, _) = make()
        trace.observeInput(frames: 0, at: 100)
        trace.observeInput(frames: 1, at: .nan)
        trace.observeConverted(frames: -10)
        trace.poll()
        XCTAssertEqual(records.values.last?.inputBuffers, 0)
        XCTAssertEqual(records.values.last?.convertedBuffers, 0)
        XCTAssertNil(records.values.last?.firstBufferMS)
    }
    func testFormatRecordsNumbersNotDeviceNames() {
        let (trace, records, _) = make()
        trace.format(sampleRate: 16_000, channels: 1)
        trace.poll()
        let line = records.values.last!.rendered
        XCTAssertTrue(line.contains("input_rate=16000"))
        XCTAssertTrue(line.contains("input_channels=1"))
        for forbidden in ["UID", "OpenComm", "password", "transcript", "http", "/Users/"] {
            XCTAssertFalse(line.contains(forbidden))
        }
    }
    func testInvalidFormatAndClockDoNotCrashDiagnosticFormatting() {
        let (trace, records, clock) = make()
        trace.format(sampleRate: .infinity, channels: 0)
        clock.set(.nan)
        trace.poll()
        XCTAssertEqual(records.values.last?.inputRate, -1)
        XCTAssertEqual(records.values.last?.elapsedMS, -1)
        XCTAssertEqual(records.values.last?.stageMS, -1)
    }
    func testNegativeClockDurationClampsToZero() {
        let (trace, records, clock) = make()
        clock.set(0)
        trace.poll()
        XCTAssertEqual(records.values.last?.elapsedMS, 0)
    }
    func testEventBudgetBoundsAsyncWriterBacklog() {
        let (trace, records, _) = make()
        for _ in 0..<5_000 { trace.poll() }
        XCTAssertEqual(records.values.count, MicrophonePreparationDiagnostics.maximumEvents)
        XCTAssertEqual(Set(records.values.map(\.sequence)).count, records.values.count)
    }
    func testRepeatedFailureNotificationIsLoggedOnce() {
        let (trace, records, _) = make()
        for _ in 0..<5_000 { trace.note(.inputRouteChanged) }
        trace.note(.configurationChanged)
        XCTAssertEqual(records.values.count, 2)
    }
    func testFinishIsIdempotentAndRejectsLateObservations() {
        let (trace, records, _) = make()
        trace.finish(); trace.finish()
        trace.observeInput(frames: 1, at: 100)
        trace.observeConverted(frames: 1)
        trace.poll(); trace.begin(.engineStart)
        XCTAssertEqual(records.values.count, 1)
        XCTAssertEqual(records.values.first?.stage, .stopped)
    }
    func testConcurrentEventsHaveUniqueSequenceAndStayBounded() {
        let (trace, records, _) = make()
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            trace.observeInput(frames: 1, at: 100)
            trace.observeConverted(frames: 1)
            if i % 2 == 0 { trace.poll() }
            else { trace.note(.configurationChanged) }
        }
        XCTAssertEqual(records.values.count, MicrophonePreparationDiagnostics.maximumEvents)
        XCTAssertEqual(Set(records.values.map(\.sequence)).count, records.values.count)
    }
    func testFreshnessDistinguishesNoPCMFromStalePCM() {
        let (trace, records, clock) = make()
        trace.begin(.awaitPCM)
        trace.poll()
        XCTAssertNil(records.values.last?.lastBufferAgeMS)
        trace.observeInput(frames: 512, at: 100)
        clock.set(105); trace.poll()
        XCTAssertEqual(records.values.last?.lastBufferAgeMS, 5_000)
        XCTAssertEqual(records.values.last?.inputBuffers, 1)
    }
    func testStageOrderIncludesTeardownInsteadOfEndingAtStartupFailure() {
        let (trace, records, _) = make()
        trace.begin(.enginePrepare)
        trace.note(.startFailed, code: 1)
        trace.begin(.engineStop)
        trace.end(.engineStop)
        trace.begin(.tapRemove)
        trace.end(.tapRemove)
        trace.finish()
        XCTAssertEqual(records.values.map(\.stage), [.enginePrepare, .startFailed,
            .engineStop, .engineStop, .tapRemove, .tapRemove, .stopped])
    }
}
