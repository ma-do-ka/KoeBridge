#if os(macOS)
import AVFoundation
import Foundation
import KoeBridgeCore

/// Control stays on the main actor; every engine operation uses capture's lane.
@MainActor final class MicrophoneWarmKeeper {
    var onConfigurationChange: (() -> Void)?
    private let worker = Worker()

    func resume(enabled: Bool, selectedUID: String, takeActive: Bool, reason: String) {
        // Never prompt for permission just to warm an idle route.
        let permitted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let changed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.onConfigurationChange?() }
        }
        let worker = worker
        MicrophoneCapture.warmLifecycleQueue.async {
            worker.resume(enabled: enabled && permitted, uid: selectedUID,
                          takeActive: takeActive, reason: reason, changed: changed)
        }
    }

    /// Enqueued before capture.start: FIFO on the shared lane completes the
    /// handoff before capture can acquire its lease. No warm lease spans a take.
    func suspend(reason: String = "take") {
        let worker = worker
        MicrophoneCapture.warmLifecycleQueue.async { worker.stop(reason: reason) }
    }

    private final class Worker: @unchecked Sendable {
        // Accessed exclusively on MicrophoneCapture.warmLifecycleQueue.
        private var lease: MicrophoneEngineLifetime<AVAudioEngine>.Lease?
        private var target: MicrophoneSelectionTarget?
        private var tapInstalled = false
        private var tapPlan: MicrophoneTapFormatPlan?
        private var observer: NSObjectProtocol?

        func resume(enabled: Bool, uid: String, takeActive: Bool, reason: String,
                    changed: @escaping @Sendable () -> Void) {
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
                if tapPlan.matches(sampleRate: hardware.sampleRate, channels: hardware.channelCount) { return }
            }
            stop(reason: "route")
            guard let acquired = MicrophoneCapture.warmEngineLifetime.acquire() else {
                log("mic warm stop reason=leased")
                return
            }
            lease = acquired
            let engine = acquired.resource
            do {
                let node = engine.inputNode
                try MicrophoneDevices.bind(selected, to: node)
                let hardware = node.inputFormat(forBus: 0)
                guard let plan = MicrophoneTapFormatPlan(hardwareSampleRate: hardware.sampleRate,
                                                        hardwareChannels: hardware.channelCount),
                      let input = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: plan.sampleRate, channels: plan.channelCount,
                                                interleaved: false) else {
                    stop(reason: "format-invalid")
                    return
                }
                guard engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty else {
                    stop(reason: "format")
                    return
                }
                observer = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
                ) { _ in changed() }
                // Deliberately no buffer access, conversion, storage or analysis.
                node.installTap(onBus: 0, bufferSize: 1024, format: input) { _, _ in }
                tapInstalled = true
                tapPlan = plan
                engine.prepare()
                if !engine.isRunning { try engine.start() }
                target = selected
                log("mic warm start reason=\(reason)")
            } catch {
                stop(reason: "failed")
            }
        }

        func stop(reason: String) {
            guard let lease else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            let engine = lease.resource
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            tapInstalled = false
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
