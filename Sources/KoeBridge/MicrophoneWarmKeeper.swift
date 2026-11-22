#if os(macOS)
import AVFoundation
import Foundation
import KoeBridgeCore

/// Control stays on the main actor; every engine operation uses capture's lane.
@MainActor final class MicrophoneWarmKeeper {
    var onConfigurationChange: (() -> Void)?
    private let worker: Worker
    private let authorized: () -> Bool
    private let hardware: MicrophoneHardware

    init(volumeGuard: OutputVolumeGuard, lifetime: MicrophoneCapture.EngineLifetime = MicrophoneCapture.warmEngineLifetime,
         hardware: MicrophoneHardware = .init(),
         authorized: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }) {
        worker = Worker(volumeGuard: volumeGuard, lifetime: lifetime, hardware: hardware)
        self.authorized = authorized
        self.hardware = hardware
    }
    private var pending: MicrophoneStartupGate?

    func resume(enabled: Bool, selectedUID: String, takeActive: Bool, reason: String) {
        pending?.cancelWarmPreparation()
        let gate = MicrophoneStartupGate(configuring: true)
        pending = gate
        let deadline = hardware.now() + MicrophoneStartupRetryPolicy().attemptTimeout
        // Never prompt for permission just to warm an idle route.
        let permitted = authorized()
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard !gate.isStopped else { return }
                self?.onConfigurationChange?()
            }
        }
        let worker = worker
        let evidence = enabled && UserDefaults.standard.bool(forKey: OutputVolumeGuard.preferenceKey)
            ? DiagnosticLog.microphoneEvidenceWriter() : nil
        MicrophoneCapture.warmLifecycleQueue.async {
            worker.resume(enabled: enabled && permitted, uid: selectedUID,
                          takeActive: takeActive, reason: reason, gate: gate, deadline: deadline, evidence: evidence, changed: changed)
        }
    }

    /// Enqueued before capture.start: FIFO on the shared lane completes the
    /// handoff before capture can acquire its lease. No warm lease spans a take.
    func suspend(reason: String = "take", handingTo take: MicrophoneCapture? = nil) {
        pending?.cancelWarmPreparation()
        pending = nil
        worker.pauseGuard()
        let worker = worker
        MicrophoneCapture.warmLifecycleQueue.async { worker.stop(reason: reason, handingTo: take) }
    }

    final class Worker: @unchecked Sendable {
        // Accessed exclusively on MicrophoneCapture.warmLifecycleQueue.
        private(set) var lease: MicrophoneEngineLifetime<AVAudioEngine>.Lease?
        private var target: MicrophoneSelectionTarget?
        private let tap = MicrophoneTapInstallation()
        private var activeGate: MicrophoneStartupGate?
        private let volumeGuard: OutputVolumeGuard
        private let owner = UUID()
        private let lifetime: MicrophoneCapture.EngineLifetime
        private let hardware: MicrophoneHardware

        init(volumeGuard: OutputVolumeGuard, lifetime: MicrophoneCapture.EngineLifetime, hardware: MicrophoneHardware) {
            self.volumeGuard = volumeGuard
            self.lifetime = lifetime
            self.hardware = hardware
        }
        func pauseGuard() { volumeGuard.pause(owner, attempt: owner) }
        private var observer: NSObjectProtocol?

        func resume(enabled: Bool, uid: String, takeActive: Bool, reason: String,
                    gate: MicrophoneStartupGate, deadline: TimeInterval, evidence: MicrophoneEvidenceWriter?, changed: @escaping @Sendable () -> Void) {
            guard !gate.isStopped else { return }
            guard enabled, !takeActive, hardware.now() < deadline else {
                stop(reason: "policy")
                return
            }
            guard let snapshot = try? hardware.snapshot(),
                  let selected = try? MicrophoneSelectionPolicy.resolve(uid: uid,
                devices: snapshot.devices, systemDefaultID: snapshot.defaultID) else {
                stop(reason: "missing")
                log("mic warm stop reason=missing")
                return
            }
            guard MicWarmPolicy.shouldWarm(enabled: enabled,
                selectedDeviceIsBluetooth: hardware.isBluetooth(selected.deviceID),
                takeActive: takeActive) else { stop(reason: "policy"); return }
            if let lease, lifetime.isCurrent(token: lease.token), target == selected, lease.resource.isRunning {
                let node = hardware.inputNode(lease.resource)
                if hardware.isStillSelected(selected, node),
                   tap.hardwareMatches(node.inputFormat(forBus: 0)),
                   tap.appliedMatches(node.outputFormat(forBus: 0)) {
                    volumeGuard.check()
                    return
                }
            }
            stop(reason: "route")
            guard let acquired = try? lifetime.acquire(for: .warm, canAcquire: !gate.isStopped && hardware.now() < deadline) else {
                log("mic warm stop reason=leased")
                return
            }
            volumeGuard.begin(owner, device: hardware.defaultOutputID, evidence: evidence,
                              startupDeadline: deadline, live: { !gate.isStopped })
            lease = acquired
            activeGate = gate
            let engine = acquired.resource
            do {
                let node = hardware.inputNode(engine)
                try hardware.bind(selected, node, nil)
                observer = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { _ in
                    if gate.warmConfigurationChanged() { changed() }
                }
                let graph = LeasedMicrophoneTapGraph(lifetime: lifetime,
                                                     lease: acquired, node: node) { [hardware] in
                    hardware.isStillSelected(selected, node)
                }
                _ = try tap.installAndPrepare(graph: graph, gate: gate, deadline: deadline,
                                                    now: hardware.now, sink: .warm)
                volumeGuard.check()
                guard !gate.isStopped, hardware.now() < deadline else {
                    stop(reason: "invalidated")
                    return
                }
                try engine.start()
                volumeGuard.check()
                guard !gate.isStopped, hardware.now() < deadline,
                      hardware.isStillSelected(selected, node),
                      gate.finishWarmStart(deadline: deadline, now: hardware.now) else {
                    stop(reason: "invalidated")
                    return
                }
                target = selected
                log("mic warm start reason=\(reason)")
            } catch {
                stop(reason: (error as? MicrophoneGraphError)?.rawValue ?? "failed")
            }
        }

        func stop(reason: String, handingTo take: MicrophoneCapture? = nil) {
            guard let lease else { return }
            let canHandOver = lifetime.isCurrent(token: lease.token)
            let cleanupOwned = lifetime.beginCleanup(lease)
            activeGate?.stop()
            activeGate = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if cleanupOwned && canHandOver { take?.inheritVolumeGuard(from: owner) }
            volumeGuard.end(owner) // also closes a handover rejected by a cancelled take
            let stopped = cleanupOwned && LeasedMicrophoneTapGraph.stopEngine(lease.resource)
            let removed = tap.removeIfOwned()
            target = nil
            self.lease = nil
            if cleanupOwned { lifetime.finishCleanup(lease, succeeded: stopped && removed) }
            log("mic warm stop reason=\(reason)")
        }

        private func log(_ message: String) {
            Task { @MainActor in DiagnosticLog.record(message) }
        }
    }
}
#endif
