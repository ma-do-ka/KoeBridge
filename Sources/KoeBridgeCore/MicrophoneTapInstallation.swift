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
        MicrophoneEngineLifetime<AVAudioEngine>.Disposition.terminal.message
    }
}

package protocol MicrophoneTapGraph {
    var leaseIsCurrent: Bool { get }
    var stoppedAndUnconnected: Bool { get }
    var selectionMatches: Bool { get }
    func recordPreflightStopped(_ stopped: Bool)
    var hardware: AVAudioFormat { get }
    var client: AVAudioFormat { get }
    func install(_ format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) -> KBTapResult
    func prepare() throws
    func retire(preCommitFormatException: Bool)
    var cleanupIsOwned: Bool { get }
    func removeOwnedTap() -> Bool
}

package struct LeasedMicrophoneTapGraph: MicrophoneTapGraph {
    let lifetime: MicrophoneEngineLifetime<AVAudioEngine>
    let lease: MicrophoneEngineLifetime<AVAudioEngine>.Lease
    let node: AVAudioNode
    let selected: () -> Bool

    package init(lifetime: MicrophoneEngineLifetime<AVAudioEngine>,
                 lease: MicrophoneEngineLifetime<AVAudioEngine>.Lease,
                 node: AVAudioNode, selected: @escaping () -> Bool) {
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
    package func recordPreflightStopped(_ stopped: Bool) {
        lifetime.recordPreflightStopped(stopped, for: lease)
    }
    package func start() throws {
        guard leaseIsCurrent else { throw MicrophoneGraphError.quarantined }
        lifetime.recordStart(.calling, for: lease)
        try lease.resource.start()
        lifetime.recordStart(.started, for: lease)
    }
    package var hardware: AVAudioFormat { node.inputFormat(forBus: 0) }
    package var client: AVAudioFormat { node.outputFormat(forBus: 0) }
    package func install(_ format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) -> KBTapResult {
        lifetime.recordInstall(for: lease)
        return KBInstallInputTap(node, format, block)
    }
    package func prepare() throws {
        guard KBPrepareMicrophoneEngine(lease.resource) else { throw PreparationError.nativeException }
    }
    private enum PreparationError: Error { case nativeException }

    package func retire(preCommitFormatException: Bool) {
        lifetime.retire(lease, preCommitFormatException: preCommitFormatException)
    }
    package var cleanupIsOwned: Bool { lifetime.ownsCleanup(lease) }
    package func removeOwnedTap() -> Bool { KBRemoveInputTap(node) }

    package static func makeEngine() -> AVAudioEngine? { KBCreateMicrophoneEngine() }
    package static func stopEngine(_ engine: AVAudioEngine) -> Bool { KBStopMicrophoneEngine(engine) }
    package static func readEngineRunning(_ engine: AVAudioEngine) -> Bool? {
        KBReadMicrophoneEngineRunning(engine)?.boolValue
    }
}

/// All methods run on the shared lifecycle lane. An install receipt belongs to
/// exactly this node and lease, including when a later readback fails.
package final class MicrophoneTapInstallation {
    private var owned: (any MicrophoneTapGraph)?
    private var hardwareFormat: AVAudioFormat?
    private var appliedFormat: AVAudioFormat?
    package var isInstalled: Bool { owned != nil }
    package init() {}

    // AVAudioFormat.isEqual treats mono interleaved and planar formats as equal.
    package static func sameFormat(_ current: AVAudioFormat, _ expected: AVAudioFormat) -> Bool {
        current.isInterleaved == expected.isInterleaved && current.commonFormat == expected.commonFormat
            && current.channelCount == expected.channelCount && current.sampleRate == expected.sampleRate
            && current.isEqual(expected)
    }

    package func hardwareMatches(_ current: AVAudioFormat) -> Bool { hardwareFormat.map { Self.sameFormat(current, $0) } ?? false }
    package func appliedMatches(_ current: AVAudioFormat) -> Bool { appliedFormat.map { Self.sameFormat(current, $0) } ?? false }

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
                                   sink: Sink,
                                   selectionFailed: () -> Void = {}) throws -> MicrophoneTapFormatPlan {
        func checkGeneration() throws {
            if gate.isStopped { throw CancellationError() }
            guard gate.configuringWithoutChurn else {
                throw MicrophoneStartupGate.Failure.configurationChanged
            }
            guard now() < deadline else {
                throw MicrophoneStartupGate.Failure.unstableBuffers
            }
        }
        func checkGraph(recordPreflight: Bool = false) throws {
            try checkGeneration()
            guard graph.leaseIsCurrent else { throw MicrophoneGraphError.quarantined }
            let stopped = graph.stoppedAndUnconnected
            if recordPreflight { graph.recordPreflightStopped(stopped) }
            guard stopped else { throw MicrophoneGraphError.unexpectedTopology }
            guard graph.selectionMatches else {
                selectionFailed()
                throw MicrophoneStartupGate.Failure.inputRouteChanged
            }
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

            try checkGraph(recordPreflight: true)
            let current = graph.hardware
            _ = graph.client // A stale client is repairable by the explicit-format install.
            guard Self.sameFormat(current, hardware) else {
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
                guard Self.sameFormat(hw, hardware),
                      Self.sameFormat(applied, input) else { throw MicrophoneStartupGate.Failure.formatChanged }
                try checkGeneration()
            }
            try verifyApplied()
            diagnostics?.begin(.enginePrepare)
            try graph.prepare()
            diagnostics?.end(.enginePrepare)
            try verifyApplied()
            hardwareFormat = hardware
            appliedFormat = input
            return plan
        } catch {
            gate.stop(at: now())
            if let graphError = error as? MicrophoneGraphError {
                graph.retire(preCommitFormatException: graphError == .formatException && !gate.didCommit)
            }
            throw error
        }
    }

    /// A nil result means the native remove was skipped.
    @discardableResult package func removeIfOwned() -> Bool? {
        let receipt = owned
        owned = nil
        hardwareFormat = nil
        appliedFormat = nil
        guard let receipt, receipt.cleanupIsOwned else { return nil }
        return receipt.removeOwnedTap()
    }
}
#endif
