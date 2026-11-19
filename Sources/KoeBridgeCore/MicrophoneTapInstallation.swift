#if os(macOS)
import AVFAudio
import Foundation
import KoeBridgeAudioTap

/// A native exception has no rollback receipt. Both exception classes end the
/// take, but retain the cause for preparation diagnostics.
package enum MicrophoneGraphError: String, LocalizedError {
    case formatException = "tap_format_mismatch"
    case unknownException = "tap_unknown_exception"
    case unexpectedTopology = "tap_graph_unexpected"
    case quarantined = "tap_graph_quarantined"

    package var errorDescription: String? {
        "マイクの安全な状態を確認できません。アプリを再起動してください"
    }
}

package protocol MicrophoneTapGraph {
    var leaseIsCurrent: Bool { get }
    var stoppedAndUnconnected: Bool { get }
    var selectionMatches: Bool { get }
    var hardware: AVAudioFormat { get }
    var client: AVAudioFormat { get }
    func install(_ format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) -> KBTapResult
    func prepare()
    func quarantine()
    func removeOwnedTap()
}

package struct LeasedMicrophoneTapGraph: MicrophoneTapGraph {
    let lifetime: MicrophoneEngineLifetime<AVAudioEngine>
    let lease: MicrophoneEngineLifetime<AVAudioEngine>.Lease
    let node: AVAudioInputNode
    let selected: () -> Bool

    package init(lifetime: MicrophoneEngineLifetime<AVAudioEngine>,
                 lease: MicrophoneEngineLifetime<AVAudioEngine>.Lease,
                 node: AVAudioInputNode, selected: @escaping () -> Bool) {
        self.lifetime = lifetime
        self.lease = lease
        self.node = node
        self.selected = selected
    }

    package var leaseIsCurrent: Bool { lifetime.isCurrent(token: lease.token) }
    package var stoppedAndUnconnected: Bool {
        let engine = lease.resource
        return node.engine === engine && node.numberOfOutputs > 0
            && !engine.isRunning && engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty
    }
    package var selectionMatches: Bool { selected() }
    package var hardware: AVAudioFormat { node.inputFormat(forBus: 0) }
    package var client: AVAudioFormat { node.outputFormat(forBus: 0) }
    package func install(_ format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) -> KBTapResult {
        KBInstallInputTap(node, format, block)
    }
    package func prepare() { lease.resource.prepare() }
    package func quarantine() { lifetime.quarantine(token: lease.token) }
    package func removeOwnedTap() { node.removeTap(onBus: 0) }
}

/// All methods run on the shared lifecycle lane. An install receipt belongs to
/// exactly this node and lease, including when a later readback fails.
package final class MicrophoneTapInstallation {
    private var owned: (any MicrophoneTapGraph)?
    package var isInstalled: Bool { owned != nil }
    package init() {}

    package enum Sink {
        case capture(output: AVAudioFormat,
                     configure: (AVAudioConverter, AVAudioFormat, AVAudioFormat) -> Void,
                     readback: (AVAudioFormat) -> Void,
                     receive: (AVAudioPCMBuffer, MicrophoneStartupGate.TapCaptureToken) -> Void)
        case warm

        fileprivate func configure(input: AVAudioFormat, hardware: AVAudioFormat, client: AVAudioFormat) throws {
            if case let .capture(output, configure, _, _) = self {
                guard let converter = AVAudioConverter(from: input, to: output) else {
                    throw MicrophoneStartupGate.Failure.conversionFailed
                }
                configure(converter, hardware, client)
            }
        }

        fileprivate func block(gate: MicrophoneStartupGate) -> AVAudioNodeTapBlock {
            guard case let .capture(_, _, _, receive) = self else { return { _, _ in } }
            let generation = gate.currentTapGeneration
            return { buffer, _ in
                guard buffer.frameLength > 0,
                      let token = gate.captureTokenForTap(tapGeneration: generation) else { return }
                receive(buffer, token)
            }
        }
    }

    package func installAndPrepare(graph: any MicrophoneTapGraph, gate: MicrophoneStartupGate,
                                   deadline: TimeInterval,
                                   diagnostics: MicrophonePreparationDiagnostics? = nil,
                                   now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                   sink: Sink) throws -> MicrophoneTapFormatPlan {
        func checkGeneration() throws {
            if gate.isStopped { throw CancellationError() }
            guard gate.configuringWithoutChurn else {
                throw MicrophoneStartupGate.Failure.configurationChanged
            }
            guard now() < deadline else {
                throw MicrophoneStartupGate.Failure.unstableBuffers
            }
        }
        func checkGraph() throws {
            try checkGeneration()
            guard graph.leaseIsCurrent else { throw MicrophoneGraphError.quarantined }
            guard graph.stoppedAndUnconnected else { throw MicrophoneGraphError.unexpectedTopology }
            guard graph.selectionMatches else { throw MicrophoneStartupGate.Failure.inputRouteChanged }
        }
        do {
            try checkGraph()
            guard !isInstalled else { throw MicrophoneStartupGate.Failure.formatChanged }
            diagnostics?.begin(.formats)
            let hardware = graph.hardware
            let client = graph.client
            guard let plan = MicrophoneTapFormatPlan(hardwareSampleRate: hardware.sampleRate,
                                                     hardwareChannels: hardware.channelCount),
                  let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: plan.sampleRate,
                                            channels: plan.channelCount, interleaved: false) else {
                throw MicrophoneStartupGate.Failure.formatChanged
            }
            diagnostics?.format(sampleRate: input.sampleRate, channels: input.channelCount)
            diagnostics?.end(.formats)
            diagnostics?.begin(.converter)
            try sink.configure(input: input, hardware: hardware, client: client)
            diagnostics?.end(.converter)

            try checkGraph()
            let current = graph.hardware
            _ = graph.client // A stale client is repairable by the explicit-format install.
            guard plan.matches(sampleRate: current.sampleRate, channels: current.channelCount) else {
                throw MicrophoneStartupGate.Failure.formatChanged
            }
            diagnostics?.begin(.tapInstall)
            try checkGeneration()
            switch graph.install(input, block: sink.block(gate: gate)) {
            case .installed: owned = graph
            case .formatMismatch: throw MicrophoneGraphError.formatException
            default: throw MicrophoneGraphError.unknownException
            }
            diagnostics?.end(.tapInstall)
            func verifyApplied() throws {
                try checkGraph()
                let hw = graph.hardware
                let applied = graph.client
                if case let .capture(_, _, readback, _) = sink { readback(applied) }
                guard plan.matches(sampleRate: hw.sampleRate, channels: hw.channelCount),
                      applied.isEqual(input) else { throw MicrophoneStartupGate.Failure.formatChanged }
                try checkGeneration()
            }
            try verifyApplied()
            diagnostics?.begin(.enginePrepare)
            graph.prepare()
            diagnostics?.end(.enginePrepare)
            try verifyApplied()
            return plan
        } catch {
            gate.stop(at: now())
            if error is MicrophoneGraphError { graph.quarantine() }
            throw error
        }
    }

    package func removeIfOwned() {
        if let owned, owned.leaseIsCurrent { owned.removeOwnedTap() }
        owned = nil
    }
}
#endif
