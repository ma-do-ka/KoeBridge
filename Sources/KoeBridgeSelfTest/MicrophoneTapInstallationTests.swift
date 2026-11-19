#if os(macOS)
import AVFAudio
import Foundation
import KoeBridgeAudioTap
import KoeBridgeCore
import KoeBridgeTapFixtures

struct MicrophoneTapInstallationTests {
    private final class Graph: MicrophoneTapGraph {
        let node = KBFakeTapNode()
        let lifetime = MicrophoneEngineLifetime { NSObject() }
        lazy var lease = lifetime.acquire()!
        let bluetooth = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let aggregate = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        var client: AVAudioFormat
        var onInstall: (() -> Void)?
        var onPrepare: (() -> Void)?
        var prepares = 0
        var removals = 0
        var stoppedAndUnconnected = true
        init() {
            client = aggregate
            node.currentDeviceID = 137
            _ = lease
        }
        var hardware: AVAudioFormat { selectionMatches ? bluetooth : aggregate }
        var leaseIsCurrent: Bool { lifetime.isCurrent(token: lease.token) }
        var selectionMatches: Bool { node.currentDeviceID == 137 }
        func install(_ format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) -> KBTapResult {
            let result = KBInstallInputTap(node, format, block)
            if result == .installed { client = format }
            onInstall?()
            return result
        }
        func prepare() { prepares += 1; onPrepare?() }
        func removeOwnedTap() { removals += 1 }
        func quarantine() { lifetime.quarantine(token: lease.token) }
    }

    private enum Scenario: CaseIterable {
        case repair, switched, unknown, late, cancelled, configurationChange
        case wrongAfterInstall, wrongAfterPrepare, alreadyExpired, wrongSelection, changedDuringConversion
    }

    static func leaseAndBudget() {
        let graph = Graph()
        let old = graph.lease
        check(graph.lifetime.release(token: old.token))
        let current = graph.lifetime.acquire()!
        graph.lifetime.quarantine(token: old.token)
        check(!graph.lifetime.isQuarantined)
        check(graph.lifetime.isCurrent(token: current.token))
        check(!graph.lifetime.release(token: old.token))
        graph.lifetime.quarantine(token: current.token)
        check(graph.lifetime.release(token: current.token))
        check(graph.lifetime.acquire() == nil)

        let policy = MicrophoneStartupRetryPolicy()
        var elapsed = 0.0
        for attempt in 1...policy.maximumAttempts {
            let timeout = policy.timeoutForNextAttempt(elapsed: elapsed)
            check(timeout > 0 && timeout <= 2.5 && timeout <= 10 - elapsed)
            elapsed += timeout
            let delay = policy.retryDelay(after: attempt, elapsed: elapsed, failure: .formatChanged)
            if attempt == 4 {
                check(delay == nil)
            } else {
                check(delay == 0.05)
                elapsed += (delay ?? 0) + 0.1 // backoff plus cleanup on the same clock
            }
        }
        check(policy.timeoutForNextAttempt(elapsed: elapsed) == 0)

        let preparing = MicrophoneStartupGate(configuring: true)
        check(!preparing.warmConfigurationChanged())
        check(!preparing.finishWarmStart(deadline: .greatestFiniteMagnitude))
        let cancelled = MicrophoneStartupGate(configuring: true)
        cancelled.cancelWarmPreparation()
        check(!cancelled.finishWarmStart(deadline: .greatestFiniteMagnitude))
        let warm = MicrophoneStartupGate(configuring: true)
        check(!warm.finishWarmStart(deadline: 0))
        check(warm.finishWarmStart(deadline: .greatestFiniteMagnitude))
        warm.cancelWarmPreparation()
        check(warm.warmConfigurationChanged())
        warm.stop()
        check(!warm.warmConfigurationChanged())
    }

    static func exercise(warm: Bool) {
        for scenario in Scenario.allCases {
            // The warm sink has no converter setup to interrupt.
            if warm && scenario == .changedDuringConversion { continue }
            let graph = Graph()
            let gate = MicrophoneStartupGate(configuring: true)
            let tap = MicrophoneTapInstallation()
            var clock = 1.0
            let deadline = 3.5
            var converterFormat: AVAudioFormat?
            var deliveries = 0
            switch scenario {
            case .repair, .changedDuringConversion: break
            case .switched: graph.node.switchDeviceDuringInstall = true
            case .unknown: graph.node.raiseUnknown = true
            case .late: graph.onInstall = { clock = deadline }
            case .cancelled: graph.onInstall = { gate.stop() }
            case .configurationChange:
                graph.onInstall = { _ = gate.handleConfigurationChange(at: clock, deadline: deadline) }
            case .wrongAfterInstall: graph.onInstall = { [unowned graph] in graph.client = graph.aggregate }
            case .wrongAfterPrepare: graph.onPrepare = { [unowned graph] in graph.client = graph.aggregate }
            case .alreadyExpired: clock = deadline
            case .wrongSelection: graph.node.currentDeviceID = 173
            }
            let sink: MicrophoneTapInstallation.Sink = warm ? .warm : .capture(output: graph.bluetooth,
                configure: { converter, hardware, client in
                    converterFormat = converter.inputFormat
                    check(client == graph.aggregate)
                    check(hardware == graph.bluetooth)
                    if scenario == .changedDuringConversion { graph.node.currentDeviceID = 173 }
                }, readback: { _ in }, receive: { _, _ in
                    deliveries += 1
                })
            var failure: Error?
            do {
                let plan = try tap.installAndPrepare(graph: graph, gate: gate, deadline: deadline,
                                                     now: { clock }, sink: sink)
                check(plan.matches(sampleRate: 16_000, channels: 1))
            } catch { failure = error }
            let partial = scenario == .switched || scenario == .unknown
            let beforeInstall = [.alreadyExpired, .wrongSelection, .changedDuringConversion].contains(scenario)
            check(graph.node.installs == (beforeInstall ? 0 : 1))
            check(tap.isInstalled == (!beforeInstall && !partial))
            check(gate.isStopped == (scenario != .repair))
            check(graph.prepares == ([.repair, .wrongAfterPrepare].contains(scenario) ? 1 : 0))
            switch scenario {
            case .repair:
                check(failure == nil)
                check(graph.node.requested == graph.bluetooth)
                check(warm || converterFormat == graph.node.requested)
            case .switched:
                check(graph.node.currentDeviceID == 173 && graph.hardware == graph.aggregate)
                check(failure as? MicrophoneGraphError == .formatException)
            case .unknown: check(failure as? MicrophoneGraphError == .unknownException)
            case .late, .alreadyExpired: check(failure as? MicrophoneStartupGate.Failure == .unstableBuffers)
            case .cancelled: check(failure is CancellationError)
            case .configurationChange: check(failure as? MicrophoneStartupGate.Failure == .configurationChanged)
            case .wrongSelection, .changedDuringConversion:
                check(failure as? MicrophoneStartupGate.Failure == .inputRouteChanged)
            case .wrongAfterInstall, .wrongAfterPrepare:
                check(failure as? MicrophoneStartupGate.Failure == .formatChanged)
            }

            let buffer = AVAudioPCMBuffer(pcmFormat: graph.bluetooth, frameCapacity: 16)!
            buffer.frameLength = 16
            graph.node.partialTap?(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
            check(deliveries == (!warm && scenario == .repair ? 1 : 0))
            if scenario != .repair {
                check(gate.observeConvertedBuffer(frames: 16, at: clock, epoch: gate.currentEpoch) == .dropped)
                check(!gate.commit(at: clock, deadline: deadline, engineRunning: true))
            }

            tap.removeIfOwned()
            tap.removeIfOwned()
            check(graph.removals == (!beforeInstall && !partial ? 1 : 0))
            check(graph.lifetime.release(token: graph.lease.token))
            check(graph.lifetime.isQuarantined == partial)
            check((graph.lifetime.acquire() == nil) == partial)
        }
    }
}
#endif
