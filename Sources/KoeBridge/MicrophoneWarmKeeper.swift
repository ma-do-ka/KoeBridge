#if os(macOS)
import AVFoundation
import Foundation
import KoeBridgeCore

/// Control stays on the main actor; every engine operation uses capture's lane.
@MainActor final class MicrophoneWarmKeeper {
    var onConfigurationChange: (() -> Void)?
    private let worker = Worker()
    private var pending: MicrophoneStartupGate?

    func resume(enabled: Bool, selectedUID: String, takeActive: Bool, reason: String) {
        pending?.cancelWarmPreparation()
        let gate = MicrophoneStartupGate(configuring: true)
        pending = gate
        let deadline = ProcessInfo.processInfo.systemUptime + MicrophoneStartupRetryPolicy().attemptTimeout
        // Never prompt for permission just to warm an idle route.
        let permitted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.onConfigurationChange?() }
        }
        let worker = worker
        MicrophoneCapture.warmLifecycleQueue.async {
            worker.resume(enabled: enabled && permitted, uid: selectedUID,
                          takeActive: takeActive, reason: reason, gate: gate, deadline: deadline, changed: changed)
        }
    }

    /// Enqueued before capture.start: FIFO on the shared lane completes the
    /// handoff before capture can acquire its lease. No warm lease spans a take.
    func suspend(reason: String = "take") {
        pending?.cancelWarmPreparation()
        pending = nil
        let worker = worker
        MicrophoneCapture.warmLifecycleQueue.async { worker.stop(reason: reason) }
    }

    private final class Worker: @unchecked Sendable {
        // Accessed exclusively on MicrophoneCapture.warmLifecycleQueue.
        private var lease: MicrophoneEngineLifetime<AVAudioEngine>.Lease?
        private var target: MicrophoneSelectionTarget?
        private let tap = MicrophoneTapInstallation()
        private var activeGate: MicrophoneStartupGate?
        private var tapPlan: MicrophoneTapFormatPlan?
        private var observer: NSObjectProtocol?

        func resume(enabled: Bool, uid: String, takeActive: Bool, reason: String,
                    gate: MicrophoneStartupGate, deadline: TimeInterval, changed: @escaping @Sendable () -> Void) {
            guard !gate.isStopped else { return }
            guard enabled, !takeActive, ProcessInfo.processInfo.systemUptime < deadline else {
                stop(reason: "policy")
                return
            }
            let snapshot = MicrophoneDevices.snapshot()
            guard let selected = try? MicrophoneSelectionPolicy.resolve(uid: uid,
                devices: snapshot.devices, systemDefaultID: snapshot.defaultID) else {
                stop(reason: "missing")
                log("mic warm stop reason=missing")
                return
            }
            guard MicWarmPolicy.shouldWarm(enabled: enabled,
                selectedDeviceIsBluetooth: MicrophoneDevices.isBluetooth(deviceID: selected.deviceID),
                takeActive: takeActive) else { stop(reason: "policy"); return }
            if let lease, target == selected, lease.resource.isRunning,
               MicrophoneDevices.isStillSelected(selected, node: lease.resource.inputNode),
               let tapPlan {
                let hardware = lease.resource.inputNode.inputFormat(forBus: 0)
                let applied = lease.resource.inputNode.outputFormat(forBus: 0)
                if tapPlan.matches(sampleRate: hardware.sampleRate, channels: hardware.channelCount),
                   tapPlan.matches(sampleRate: applied.sampleRate, channels: applied.channelCount),
                   applied.commonFormat == .pcmFormatFloat32, !applied.isInterleaved { return }
            }
            stop(reason: "route")
            guard let acquired = MicrophoneCapture.warmEngineLifetime.acquire() else {
                log("mic warm stop reason=leased")
                return
            }
            lease = acquired
            activeGate = gate
            let engine = acquired.resource
            do {
                let node = engine.inputNode
                try MicrophoneDevices.bind(selected, to: node)
                observer = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { _ in
                    if gate.warmConfigurationChanged() { changed() }
                }
                let graph = LeasedMicrophoneTapGraph(lifetime: MicrophoneCapture.warmEngineLifetime,
                                                     lease: acquired, node: node) {
                    MicrophoneDevices.isStillSelected(selected, node: node)
                }
                tapPlan = try tap.installAndPrepare(graph: graph, gate: gate, deadline: deadline,
                                                    sink: .warm)
                try engine.start()
                guard !gate.isStopped, ProcessInfo.processInfo.systemUptime < deadline,
                      MicrophoneDevices.isStillSelected(selected, node: node),
                      gate.finishWarmStart(deadline: deadline) else {
                    stop(reason: "invalidated")
                    return
                }
                target = selected
                log("mic warm start reason=\(reason)")
            } catch {
                stop(reason: (error as? MicrophoneGraphError)?.rawValue ?? "failed")
            }
        }

        func stop(reason: String) {
            guard let lease else { return }
            activeGate?.stop()
            activeGate = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            let engine = lease.resource
            if MicrophoneCapture.warmEngineLifetime.isCurrent(token: lease.token) {
                engine.stop()
                tap.removeIfOwned()
            }
            tapPlan = nil
            target = nil
            self.lease = nil
            MicrophoneCapture.warmEngineLifetime.release(token: lease.token)
            log("mic warm stop reason=\(reason)")
        }

        private func log(_ message: String) {
            Task { @MainActor in DiagnosticLog.record(message) }
        }
    }
}
#endif
