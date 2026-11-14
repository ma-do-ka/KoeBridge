import Foundation
import KoeBridgeCore

struct MicrophonePreparationDiagnosticsTests {
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
    func testChurnCountsPerStageWithEightEventCapAndSettlingFields() {
        let (trace, records, _) = make()
        trace.begin(.engineStart)
        for i in 2...21 { trace.noteChurn(epoch: UInt64(i)) }
        trace.begin(.awaitPCM)
        for i in 22...41 { trace.noteChurn(epoch: UInt64(i)) }
        trace.discardStartup(duration: 0.25)
        trace.discardStartup(duration: 0.5)
        trace.discardStartup(duration: 0)
        let gate = MicrophoneStartupGate()
        _ = gate.handleConfigurationChange(at: 0, deadline: 2.5)
        _ = gate.revalidationReadiness(at: 0.07, deadline: 2.5)
        _ = gate.resumeStabilising(expectedEpoch: 2, at: 0.125)
        gate.observeConvertedBuffer(frames: 800, at: 0.2)
        gate.observeConvertedBuffer(frames: 800, at: 0.4)
        _ = gate.commit(at: 0.41, deadline: 2.5, engineRunning: true)
        trace.settling(gate.settlingSnapshot(at: 0.42))
        trace.revalidation(.fail(.engineStopped, component: .engine), engineRunning: false)
        trace.poll()
        let entry = records.values.last!
        check(records.values.filter { $0.stage == .configurationChanged }.count == 16)
        check(entry.churnCount == 40)
        check(entry.churnCounts[.engineStart] == 20)
        check(entry.churnCounts[.awaitPCM] == 20)
        check(entry.epoch == 41)
        check(entry.discardedEpochs == 2)
        check(entry.discardedStartupMS == 750)
        check(entry.revalidations == 1)
        check(entry.settlingMS == 125)
        check(entry.readyViaSettling)
        check(entry.rendered.contains("revalidation_outcome=fail"))
        check(entry.rendered.contains("failing_component=engine"))
        check(entry.rendered.contains("engine_running=0"))
        for _ in 0..<500 { trace.poll() }
        check(records.values.count == MicrophonePreparationDiagnostics.maximumEvents)
    }
}
