#if os(macOS)
import AudioToolbox
import Foundation
import Testing
@testable import KoeBridge
import KoeBridgeCore

struct OutputVolumeGuardTests {
    /// Each fixture and its guard are used exclusively on the lifecycle queue.
    private final class Fixture: @unchecked Sendable {
        var device: UInt32? = 41
        var volumes: [OutputVolumeElement: Float] = [.scalar(1): 0.5, .scalar(2): 0.4]
        var muted = false
        var fixed = false
        var refuseListeners = false
        var reads = 0
        var snapshots = 0
        var additions = 0
        var removals = 0
        var callback: AudioObjectPropertyListenerBlock?
        var writes: [Float] = []

        func hardware() -> OutputVolumeGuard.Hardware {
            var hal = OutputVolumeGuard.Hardware()
            hal.defaultDevice = { self.reads += 1; return self.device }
            hal.sample = { device, snapshot in
                self.reads += 1
                if snapshot { self.snapshots += 1 }
                guard self.device == device else { return nil }
                return .init(reading: .init(uid: String(device), device: device, muted: self.muted,
                    volumes: self.volumes), settable: self.fixed ? [] : Set(self.volumes.keys))
            }
            hal.lower = { reading, element, ceiling in
                #expect(reading.device == self.device && !self.muted && !self.fixed)
                let before = self.volumes[element]
                self.volumes[element] = ceiling
                self.writes.append(ceiling)
                return before
            }
            hal.add = { _, _, _, block in
                self.additions += 1
                guard !self.refuseListeners else { return kAudioHardwareUnsupportedOperationError }
                self.callback = block
                return noErr
            }
            hal.remove = { _, _, _, _ in self.removals += 1; return noErr }
            return hal
        }

        func notify() {
            var address = OutputVolumeHAL.address(kAudioDevicePropertyVolumeScalar)
            callback?(1, &address)
        }
    }

    @Test func idleAndDisabledNeverProbeOrInstallListeners() {
        MicrophoneCapture.warmLifecycleQueue.sync {
            for enabled in [false, true] {
                let f = Fixture(), owner = UUID()
                let guardController = OutputVolumeGuard(enabled: enabled, hardware: f.hardware())
                guardController.check()
                if !enabled {
                    guardController.begin(owner, device: { f.reads += 1; return f.device }(), evidence: nil)
                    guardController.check()
                    guardController.end(owner)
                }
                #expect(f.reads == 0 && f.additions == 0 && f.writes.isEmpty)
            }
        }
    }

    @Test func listenerHandoverRouteChangeAndQueuedCallbackAfterStop() {
        MicrophoneCapture.warmLifecycleQueue.sync {
            let f = Fixture(), warm = UUID(), take = UUID()
            let controller = OutputVolumeGuard(enabled: true, hardware: f.hardware())
            controller.begin(warm, device: f.device, evidence: nil)
            #expect(f.additions > 0)
            f.volumes = [.scalar(0): 0.6]
            controller.handover(from: warm, to: take)
            controller.end(warm)
            controller.begin(take, device: f.device, evidence: nil)
            #expect(f.snapshots == 1 && f.writes == [0.5])
            f.device = nil // transient read error
            f.notify()
            f.device = UInt32(kAudioObjectUnknown) // HAL explicitly reports disconnection
            f.notify()
            #expect(f.writes == [0.5])
            f.device = 44
            f.volumes = [.scalar(2): 0.8]
            f.fixed = true
            f.notify()
            f.fixed = false
            f.muted = true
            f.notify()
            #expect(f.writes == [0.5])
            f.muted = false
            f.notify()
            #expect(f.writes == [0.5, 0.5])
            controller.end(take)
            #expect(f.additions == f.removals)
            let reads = f.reads
            f.notify()
            #expect(f.reads == reads && f.writes.count == 2)
        }
    }

    @Test func unsupportedListenersStillAllowCheckpointCorrections() {
        MicrophoneCapture.warmLifecycleQueue.sync {
            let f = Fixture(), owner = UUID()
            f.refuseListeners = true
            let controller = OutputVolumeGuard(enabled: true, hardware: f.hardware())
            controller.begin(owner, device: f.device, evidence: nil)
            f.volumes = [.scalar(0): 0.7]
            controller.check()
            controller.end(owner)
            #expect(f.callback == nil && f.writes == [0.5])
        }
    }

    @Test func debounceRechecksTheLatestValue() async throws {
        let queue = MicrophoneCapture.warmLifecycleQueue
        let f = Fixture(), owner = UUID()
        let controller = OutputVolumeGuard(enabled: true, hardware: f.hardware())
        queue.sync {
            controller.begin(owner, device: f.device, evidence: nil)
            f.volumes = [.scalar(1): 0.9, .scalar(2): 0.8]
            f.notify()
            f.volumes = [.scalar(1): 0.8, .scalar(2): 0.9]
            f.notify()
            #expect(f.writes == [0.5, 0.4])
            f.volumes[.scalar(1)] = 0.1
        }
        try await Task.sleep(for: .milliseconds(350))
        queue.sync {
            #expect(f.writes == [0.5, 0.4, 0.4])
            #expect(f.volumes[.scalar(1)] == 0.1)
            controller.end(owner)
        }
    }
}
#endif
