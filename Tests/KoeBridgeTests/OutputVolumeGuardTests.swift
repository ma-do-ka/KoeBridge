#if os(macOS)
import AudioToolbox
import Foundation
import Testing
@testable import KoeBridge
import KoeBridgeCore

struct OutputVolumeGuardTests {
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
        var nativeStarts = 0
        var writes: [Float] = []
        var failedSets = 0
        var failFirstSet = false
        var failRemovals = false
        var failedReads = 0
        var beforeVerification: (() -> Void)?
        var afterVerificationRead: (() -> Void)?
        var beforeAdmission: (() -> Void)?
        var duringSet: (() -> Void)?
        var afterSet: (() -> Void)?
        var snapshotHook: (() -> Void)?
        var didReadSnapshot: ((OutputVolumeReading) -> Void)?
        private var callbacks: [String: (DispatchQueue, AudioObjectPropertyListenerBlock)] = [:]
        let owner = UUID()
        let enabled: Bool
        init(enabled: Bool = true) { self.enabled = enabled }
        lazy var controller = OutputVolumeGuard(enabled: enabled, hardware: hardware())

        private func key(_ device: UInt32, _ p: AudioObjectPropertyAddress) -> String {
            "\(device)/\(p.mSelector)/\(p.mScope)/\(p.mElement)"
        }
        private func element(_ p: AudioObjectPropertyAddress) -> OutputVolumeElement {
            p.mSelector == kAudioDevicePropertyVolumeScalar ? .scalar(p.mElement) : .virtualMain
        }

        private func hardware() -> OutputVolumeGuard.Hardware {
            var hal = OutputVolumeGuard.Hardware()
            hal.defaultDevice = { self.reads += 1; return self.device }
            hal.sample = { device, snapshot in
                self.reads += 1
                if snapshot {
                    self.snapshots += 1
                    self.snapshotHook?()
                    if self.failedReads > 0 { self.failedReads -= 1; return nil }
                }
                guard self.device == device else { return nil }
                let reading = OutputVolumeReading(uid: String(device), device: device, muted: self.muted,
                                                  volumes: self.volumes)
                if snapshot { self.didReadSnapshot?(reading) }
                return .init(reading: reading, settable: self.fixed ? [] : Set(self.volumes.keys))
            }
            hal.finalReads.defaultDevice = {
                let hook = self.beforeVerification
                self.beforeVerification = nil
                hook?()
                return self.device
            }
            hal.finalReads.uid = { String($0) }
            hal.finalReads.alive = { _ in true }
            hal.finalReads.muted = { _ in self.muted }
            hal.finalReads.settable = { _, _ in !self.fixed }
            hal.scalar = { _, property in try #require(self.volumes[self.element(property)]) }
            let scalar = hal.scalar
            hal.finalReads.scalar = { device, property in
                let value = try scalar(device, property)
                let hook = self.afterVerificationRead
                self.afterVerificationRead = nil
                hook?()
                return value
            }
            hal.set = { device, p, value, submit in
                let admissionHook = self.beforeAdmission
                self.beforeAdmission = nil
                admissionHook?()
                return try submit {
                    self.nativeStarts += 1
                    if self.failFirstSet {
                        self.failFirstSet = false
                        self.failedSets += 1
                        throw CocoaError(.fileWriteUnknown)
                    }
                    #expect(device == self.device && !self.muted && !self.fixed)
                    let during = self.duringSet
                    self.duringSet = nil
                    during?()
                    self.volumes[self.element(p)] = value
                    self.writes.append(value)
                    let after = self.afterSet
                    self.afterSet = nil
                    after?()
                }
            }
            hal.add = { device, p, queue, block in
                self.additions += 1
                guard !self.refuseListeners else { return kAudioHardwareUnsupportedOperationError }
                let key = self.key(device, p)
                #expect(self.callbacks[key] == nil)
                self.callbacks[key] = (queue, block)
                return noErr
            }
            hal.remove = { device, p, _, _ in
                guard !self.failRemovals else { return kAudioHardwareUnspecifiedError }
                self.removals += 1
                self.callbacks.removeValue(forKey: self.key(device, p))
                return noErr
            }
            return hal
        }

        func begin(_ id: UUID? = nil, attempt: UUID? = nil) {
            controller.begin(id ?? owner, attempt: attempt, device: { self.reads += 1; return self.device }, evidence: nil)
            drain()
        }
        func drain() { controller.queue.sync {} }
        func check() { controller.check(); drain() }

        func send(_ element: OutputVolumeElement = .scalar(1), defaultChanged: Bool = false) {
            var p = defaultChanged
                ? OutputVolumeHAL.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
                : OutputVolumeHAL.address(element)
            let id = defaultChanged ? AudioObjectID(kAudioObjectSystemObject) : (device ?? 0)
            guard let (queue, block) = callbacks[key(id, p)] else { return }
            queue.sync { block(1, &p) }
        }
        func sendMute() {
            var address = OutputVolumeHAL.address(kAudioDevicePropertyMute)
            let wildcard = OutputVolumeHAL.address(kAudioDevicePropertyMute, kAudioObjectPropertyElementWildcard)
            guard let (queue, block) = callbacks[key(device ?? 0, wildcard)] else { return }
            queue.sync { block(1, &address) }
        }
        var hasListeners: Bool { !callbacks.isEmpty }
        func staleCallback() -> (() -> Void)? {
            var address = OutputVolumeHAL.address(.scalar(2))
            guard let (queue, block) = callbacks[key(device ?? 0, address)] else { return nil }
            return { queue.sync { block(1, &address) } }
        }
    }

    @Test func idleAndDisabledNeverProbeOrInstallListeners() {
        for enabled in [false, true] {
            let f = Fixture(enabled: enabled)
            f.check()
            if !enabled {
                f.begin()
                f.check()
                f.controller.end(f.owner)
                f.drain()
            }
            #expect(f.reads == 0 && f.additions == 0 && f.writes.isEmpty)
        }
    }

    @Test func listenerHandoverRouteChangeAndQueuedCallbackAfterStop() {
        let f = Fixture(), take = UUID()
        f.begin()
        #expect(f.additions > 0)
        f.volumes = [.scalar(0): 0.6]
        f.controller.handover(from: f.owner, to: take); f.drain()
        #expect(f.snapshots == 1 && f.writes == [0.5])
        f.controller.end(f.owner)
        f.begin(take)
        #expect(f.snapshots == 1 && f.writes == [0.5])
        f.device = nil
        f.send(defaultChanged: true); f.drain()
        f.device = UInt32(kAudioObjectUnknown)
        f.send(defaultChanged: true); f.drain()
        #expect(f.writes == [0.5])
        f.device = 44
        f.volumes = [.scalar(2): 0.8]
        f.fixed = true
        f.send(defaultChanged: true); f.drain()
        f.fixed = false
        f.muted = true
        f.send(.scalar(2)); f.drain()
        #expect(f.writes == [0.5])
        f.muted = false
        f.send(.scalar(2)); f.drain()
        #expect(f.writes == [0.5, 0.5])
        let stale = f.staleCallback()
        f.controller.end(take); f.drain()
        #expect(f.additions == f.removals)
        let reads = f.reads
        stale?(); f.drain()
        #expect(f.reads == reads && f.writes.count == 2)
    }

    @Test func unsupportedListenersStillAllowCheckpointCorrections() {
        let f = Fixture()
        f.refuseListeners = true
        f.begin()
        f.volumes = [.scalar(0): 0.7]
        f.check()
        f.controller.end(f.owner); f.drain()
        #expect(!f.hasListeners && f.writes == [0.5])
    }

    @Test func debounceRechecksTheLatestValue() async throws {
        let f = Fixture()
        f.begin()
        f.volumes = [.scalar(1): 0.9, .scalar(2): 0.8]
        f.send(); f.drain()
        f.volumes = [.scalar(1): 0.8, .scalar(2): 0.9]
        f.send(); f.drain()
        #expect(f.writes == [0.5, 0.4])
        f.volumes[.scalar(1)] = 0.1
        try await Task.sleep(for: .milliseconds(350))
        f.drain()
        #expect(f.writes == [0.5, 0.4, 0.4])
        #expect(f.volumes[.scalar(1)] == 0.1)
        f.controller.end(f.owner); f.drain()
    }

    @Test func finalVerificationRejectsStaleDeviceMuteSettabilityAndScalar() {
        for change in 0..<4 {
            let f = Fixture()
            f.begin()
            f.volumes = [.scalar(1): 0.9]
            f.beforeVerification = {
                switch change {
                case 0: f.volumes[.scalar(1)] = 0.2
                case 1: f.device = 42
                case 2: f.muted = true
                default: f.fixed = true
                }
            }
            f.check()
            #expect(f.writes.isEmpty)
            f.controller.end(f.owner); f.drain()
        }
    }

    @Test func observedChangesBetweenFinalReadAndAdmissionVetoTheSetter() {
        for change in 0..<3 {
            let f = Fixture()
            f.begin()
            f.volumes = [.scalar(1): 0.9]
            f.afterVerificationRead = {
                switch change {
                case 0: f.volumes[.scalar(1)] = 0.2; f.send()
                case 1: f.device = 42; f.volumes = [.scalar(1): 0.15]; f.send(defaultChanged: true)
                default: f.muted = true; f.sendMute()
                }
            }
            f.check(); f.drain()
            #expect(f.writes.isEmpty)
            f.controller.end(f.owner); f.drain()
        }
    }

    @Test func captureCancellationPreventsAnEngineStartCheckpointFromWriting() {
        let f = Fixture()
        let capture = MicrophoneCapture(volumeGuard: f.controller, takeID: f.owner)
        capture.beginVolumeGuard(outputID: 41)
        f.drain()
        f.volumes = [.scalar(1): 0.9]
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        f.beforeAdmission = { entered.signal(); _ = resume.wait(timeout: .now() + 2) }
        f.controller.check()
        #expect(entered.wait(timeout: .now() + 2) == .success)
        capture.stop(.cancelled) { _ in }
        f.controller.check()
        capture.beginVolumeGuard(outputID: 41) // stale queued prepare cannot resurrect the attempt
        resume.signal(); f.drain()
        #expect(f.snapshots == 1 && f.writes.isEmpty)
        f.controller.end(f.owner); f.drain()
    }

    @Test func loweringObservedInsideSetIsReconciledButLowerReadbackIsUntouched() {
        for overwritten in [true, false] {
            let f = Fixture()
            f.begin()
            f.volumes = [.scalar(1): 0.9]
            let lower = { f.volumes[.scalar(1)] = 0.2; f.send() }
            if overwritten { f.duringSet = lower } else { f.afterSet = lower }
            f.check(); f.drain()
            #expect(f.volumes[.scalar(1)] == 0.2)
            #expect(f.writes == (overwritten ? [0.5, 0.2] : [0.5]))
            f.controller.end(f.owner); f.drain()
        }
    }

    @Test func witnessedLoweringSurvivesDelayedAcknowledgementAndFailedRepair() async throws {
        for delayed in [false, true] {
            let f = Fixture()
            f.begin()
            f.volumes = [.scalar(1): 0.9]
            f.duringSet = {
                f.volumes[.scalar(1)] = 0.2
                f.send()
                f.failFirstSet = !delayed
            }
            if delayed { f.afterSet = { f.volumes[.scalar(1)] = 0.9 } }
            f.check(); f.drain()
            #expect(f.writes == [0.5])
            if delayed {
                // The device acknowledges the requested scalar asynchronously.
                f.volumes[.scalar(1)] = 0.5
                f.send(); f.drain()
            }
            try await Task.sleep(for: .milliseconds(350))
            f.drain()
            #expect(f.writes == [0.5, 0.2] && f.volumes[.scalar(1)] == 0.2)
            f.controller.end(f.owner); f.drain()
        }
    }

    @Test func observedLoweringOutlivesDebounceUntilHALReflectsTheWrite() async throws {
        enum Source { case duringSet, laterListener, postWriteRead }
        for source in [Source.duringSet, .laterListener, .postWriteRead] {
            let f = Fixture()
            f.begin()
            f.volumes = [.scalar(1): 0.9]
            if source == .duringSet {
                f.duringSet = { f.volumes[.scalar(1)] = 0.2; f.send() }
            }
            // The setter accepts 0.50, but the driver still reads 0.90.
            f.afterSet = { f.volumes[.scalar(1)] = source == .postWriteRead ? 0.2 : 0.9 }
            f.check(); f.drain()
            if source == .laterListener {
                f.controller.queue.sync {
                    f.volumes[.scalar(1)] = 0.2
                    f.send() // notification after the setter's stack has unwound
                    f.volumes[.scalar(1)] = 0.9
                }
            }
            if source == .postWriteRead {
                // Same logical take, fresh capture attempt, still no HAL receipt.
                f.controller.pause(f.owner, attempt: f.owner); f.drain()
                f.volumes[.scalar(1)] = 0.9
                f.begin(attempt: UUID())
            }
            try await Task.sleep(for: .milliseconds(400))
            f.controller.queue.sync {
                #expect(f.writes == [0.5])
                f.volumes[.scalar(1)] = 0.5
                f.send()
            }
            f.drain()
            #expect(f.writes == [0.5, 0.2] && f.volumes[.scalar(1)] == 0.2)
            f.controller.end(f.owner); f.drain()
        }
    }

    @Test func invalidationLeavesLifecycleLaneAvailableWhileNativeSetIsInFlight() {
        enum Stop: CaseIterable { case off, warmStop, captureCancel }
        let lane = MicrophoneCapture.warmLifecycleQueue
        let clock = ContinuousClock()
        for stop in Stop.allCases {
            let f = Fixture()
            let capture = MicrophoneCapture(volumeGuard: f.controller, takeID: f.owner)
            if stop == .captureCancel {
                lane.sync { capture.beginVolumeGuard(outputID: 41) }
                f.drain()
            } else {
                f.begin()
            }
            f.volumes = [.scalar(1): 0.9, .scalar(2): 0.8]
            let entered = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            f.duringSet = {
                entered.signal()
                Thread.sleep(forTimeInterval: 2.55)
            }
            f.afterSet = { finished.signal() }
            f.controller.check()
            #expect(entered.wait(timeout: .now() + 2) == .success)
            f.controller.check() // also leave an evaluation queued behind the entered Set
            let stopTime = clock.measure {
                lane.sync {
                    switch stop {
                    case .off: f.controller.changePreference(false, evidence: nil)
                    case .warmStop:
                        f.controller.pause(f.owner, attempt: f.owner)
                        f.controller.end(f.owner)
                    case .captureCancel: capture.stop(.cancelled) { _ in }
                    }
                }
            }
            let nextCheckpoint = clock.measure { lane.sync { f.controller.check() } }
            #expect(stopTime < .milliseconds(100) && nextCheckpoint < .milliseconds(100))
            #expect(finished.wait(timeout: .now()) == .timedOut)
            f.drain()
            #expect(f.nativeStarts == 1 && f.writes == [0.5])
            print("guard_stop mode=\(stop) set_delay_s=2.55 stop=\(stopTime) next_checkpoint=\(nextCheckpoint) starts=\(f.nativeStarts)")
        }
    }

    @Test func lastGenerationReadRejectsInvalidationAfterFinalHALReads() {
        enum Stop: CaseIterable { case off, end, cancelAttempt }
        for stop in Stop.allCases {
            let f = Fixture()
            let arm = DispatchSemaphore(value: 0), atGate = DispatchSemaphore(value: 0)
            let resume = DispatchSemaphore(value: 0)
            // Hold the last liveness query after the HAL reads. Return its old
            // answer so only the final generation check can reject this Set.
            f.controller.begin(f.owner, device: { 41 }, evidence: nil, live: {
                if arm.wait(timeout: .now()) == .success {
                    atGate.signal()
                    _ = resume.wait(timeout: .now() + 2)
                }
                return true
            })
            f.drain()
            f.volumes = [.scalar(1): 0.8]
            f.afterVerificationRead = { arm.signal() }
            f.controller.check()
            #expect(atGate.wait(timeout: .now() + 2) == .success)
            switch stop {
            case .off: f.controller.changePreference(false, evidence: nil)
            case .end: f.controller.end(f.owner)
            case .cancelAttempt: f.controller.pause(f.owner, attempt: f.owner)
            }
            resume.signal(); f.drain()
            #expect(f.nativeStarts == 0 && f.writes.isEmpty)
            if stop == .cancelAttempt {
                f.begin(attempt: UUID())
                #expect(f.writes == [0.5]) // the veto left no unreflected Set behind
                f.controller.end(f.owner); f.drain()
            }
        }
    }

    @Test func invalidatingDuringFinalReadRejectsQueuedAndInFlightChecks() {
        for mode in 0..<3 {
            let f = Fixture(), attempt = UUID()
            f.begin(attempt: attempt)
            f.volumes = [.scalar(1): 0.8]
            let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
            f.afterVerificationRead = { entered.signal(); _ = resume.wait(timeout: .now() + 2) }
            f.controller.check()
            #expect(entered.wait(timeout: .now() + 2) == .success)
            f.controller.check()
            switch mode {
            case 0: f.controller.changePreference(false, evidence: nil)
            case 1: f.controller.end(f.owner)
            default: f.controller.pause(f.owner, attempt: attempt)
            }
            resume.signal(); f.drain()
            #expect(f.nativeStarts == 0 && f.writes.isEmpty)
        }
    }

    @Test func retriesReuseTheFirstValidLogicalCeiling() {
        for warm in [false, true] {
            let f = Fixture(), take = UUID(), first = UUID()
            f.fixed = true
            if warm {
                f.begin()
                f.volumes = [.scalar(0): 0.6]
                f.controller.handover(from: f.owner, to: take); f.drain()
            } else { f.failedReads = 1 }
            f.begin(take, attempt: first)
            f.controller.pause(take, attempt: first); f.drain()
            let count = f.writes.count
            f.check()
            #expect(f.writes.count == count)
            f.begin(take, attempt: UUID())
            let expectedSnapshots = warm ? 1 : 2
            #expect(f.snapshots == expectedSnapshots)
            f.fixed = false
            f.volumes = [.scalar(0): 0.6]
            f.check()
            #expect(f.writes == [0.5] && f.volumes[.scalar(0)] == 0.5)
            f.controller.end(take); f.drain()
            f.begin(UUID())
            #expect(f.snapshots == expectedSnapshots + 1)
        }
    }

    @Test func failingChannelDoesNotStrandItsSiblingOrItsOwnRetry() async throws {
        let f = Fixture()
        f.begin()
        f.failFirstSet = true
        f.volumes = [.scalar(1): 0.9, .scalar(2): 0.8]
        f.check()
        #expect(f.failedSets == 1 && f.writes == [0.4])
        try await Task.sleep(for: .milliseconds(350))
        f.drain()
        #expect(f.writes == [0.4, 0.5])
        f.controller.end(f.owner); f.drain()
    }

    @Test func failedRemovalRetriesAtIdleAndAtTheNextStart() async throws {
        for nextSession in [false, true] {
            let f = Fixture()
            f.begin()
            let firstCount = f.additions
            let old = f.staleCallback()
            f.failRemovals = true
            f.controller.end(f.owner); f.drain()
            #expect(f.removals == 0)
            f.failRemovals = false
            let next = UUID()
            if nextSession { f.begin(next) }
            else { try await Task.sleep(for: .milliseconds(350)); f.drain() }
            #expect(f.removals == firstCount)
            let reads = f.reads
            old?(); f.drain()
            #expect(f.reads == reads)
            f.controller.end(next); f.drain()
            #expect(f.additions == f.removals)
        }
    }

    @Test func prepareAndWarmStartSnapshotBeforeSimulatedProfileSwitch() throws {
        for warm in [false, true] {
            let f = Fixture(), take = UUID()
            let guardController = f.controller
            let capture = MicrophoneCapture(volumeGuard: guardController, takeID: take)
            f.volumes = [.scalar(0): 0.5]
            let sampled = DispatchSemaphore(value: 0)
            f.didReadSnapshot = { reading in
                #expect(reading.volumes[.scalar(0)] == 0.5)
                sampled.signal()
            }
            MicrophoneCapture.warmLifecycleQueue.sync {
                if warm { guardController.begin(f.owner, device: { 41 }, evidence: nil) }
                else { capture.beginVolumeGuard(outputID: 41) }
            }

            // Model engine start after a successful snapshot handoff.
            try #require(sampled.wait(timeout: .now() + 5) == .success)
            guardController.queue.sync { f.volumes[.scalar(0)] = 0.6 }
            f.check()
            #expect(f.volumes[.scalar(0)] == 0.5)
            #expect(f.snapshots == 1 && f.writes == [0.5])
            guardController.end(warm ? f.owner : take); f.drain()
        }
    }

    @Test func slowSnapshotLeavesCaptureAndWarmHandoverLaneAvailable() {
        for (enabled, warm) in [(false, false), (true, false), (false, true), (true, true)] {
            let f = Fixture(enabled: enabled), take = UUID()
            let started = DispatchSemaphore(value: 0)
            f.snapshotHook = { started.signal(); Thread.sleep(forTimeInterval: 2.55) }
            let guardController = f.controller
            let capture = MicrophoneCapture(volumeGuard: guardController, takeID: take)
            let clock = ContinuousClock()
            let beginTime = clock.measure {
                MicrophoneCapture.warmLifecycleQueue.sync {
                    if warm { guardController.begin(f.owner, device: { 41 }, evidence: nil) }
                    else { capture.beginVolumeGuard(outputID: 41) }
                }
            }
            if enabled {
                #expect(started.wait(timeout: .now() + 1) == .success)
                #expect(beginTime >= .milliseconds(OutputVolumeGuard.snapshotWaitMilliseconds))
            }
            let checkpointTime = clock.measure {
                MicrophoneCapture.warmLifecycleQueue.sync {
                    guardController.check()
                    if warm {
                        capture.inheritVolumeGuard(from: f.owner)
                        capture.beginVolumeGuard(outputID: 41)
                    }
                    guardController.check()
                    guardController.end(take)
                }
            }
            #expect(beginTime < .milliseconds(100) && checkpointTime < .milliseconds(100))
            f.drain()
            #expect(f.snapshots == (enabled ? 1 : 0))
            print("guard_budget warm=\(warm) enabled=\(enabled) snapshot_delay_s=2.55 begin=\(beginTime) checkpoints=\(checkpointTime)")
        }
    }
}
#endif
