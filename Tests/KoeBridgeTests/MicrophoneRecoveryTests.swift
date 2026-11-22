#if os(macOS)
import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import KoeBridge
import KoeBridgeCore
import KoeBridgeTapFixtures

@MainActor
struct MicrophoneRecoveryTests {
    private enum Fault: CaseIterable {
        case none, formatException, unknownException, topologyBefore, topologyAfter, preflight, bind
        case prepare, readback, start, noPCM, deadlineOnStart, unprovenStop, stopException, unreadableStop, removeException
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 10
        func now() -> TimeInterval { lock.withLock { value } }
        func set(_ time: TimeInterval) { lock.withLock { value = time } }
    }

    private final class Device {
        let engine = KBFakeMicrophoneEngine()
        let node = KBFakeTapNode()
        let fault: Fault
        private(set) var bound: [UInt32] = []

        init(_ fault: Fault, clock: Clock) {
            self.fault = fault
            engine.attach(node)
            node.fixtureHardware = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let staleClient = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            node.fixtureClient = staleClient
            switch fault {
            case .formatException, .unprovenStop, .stopException, .unreadableStop:
                node.switchDeviceDuringInstall = true
                engine.remainRunningAfterStop = fault == .unprovenStop
                engine.raiseOnStop = fault == .stopException
                engine.raiseOnRunningReadAfterStop = fault == .unreadableStop
            case .unknownException: node.raiseUnknown = true
            case .topologyBefore: engine.fixtureRunning = true
            case .topologyAfter, .removeException:
                node.afterInstall = { [weak engine] in engine?.fixtureRunning = true }
                engine.raiseOnStop = fault == .removeException
                node.raiseOnRemove = fault == .removeException
            case .preflight:
                node.afterHardwareRead = { [weak node] in
                    node?.fixtureHardware = AVAudioFormat(commonFormat: .pcmFormatInt16,
                        sampleRate: 16_000, channels: 1, interleaved: false)!
                }
            case .prepare: engine.raiseOnPrepare = true
            case .start: engine.failStart = true
            case .readback: node.afterInstall = { [weak node] in node?.fixtureClient = staleClient }
            case .deadlineOnStart: engine.afterStart = { clock.set(12.5) }
            default: break
            }
        }

        func bind(_ target: MicrophoneSelectionTarget) throws {
            bound.append(target.deviceID)
            if fault == .bind { throw MicrophoneDevices.DeviceError.selectionNotApplied }
            node.currentDeviceID = target.deviceID
        }

        func deliver(_ block: AVAudioNodeTapBlock?, value: Float = 0) {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
            buffer.frameLength = 1024
            for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = value }
            block?(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
        }
    }

    /// Everything except the hardware and monotonic clock runs in production code.
    private final class Rig: @unchecked Sendable {
        let clock = Clock()
        let faults: [Fault]
        private(set) var devices: [Device] = [] // lifecycle lane only
        private(set) var factoryCalls = 0
        var returnSameEngine = false
        var failFactory = false
        var factoryHook: (() -> Void)?
        var configureDevice: ((Device) -> Void)?

        init(_ faults: Fault...) { self.faults = faults }

        private func makeEngine() -> AVAudioEngine? {
            factoryCalls += 1
            factoryHook?()
            if factoryCalls > 1 {
                if returnSameEngine { return devices[0].engine }
                if failFactory { return nil }
            }
            let device = Device(faults[min(devices.count, faults.count - 1)], clock: clock)
            devices.append(device)
            configureDevice?(device)
            return device.engine
        }

        lazy var lifetime = MicrophoneCapture.EngineLifetime { [unowned self] in makeEngine() }
        var hardware: MicrophoneHardware {
            var result = MicrophoneHardware(now: clock.now)
            result.snapshot = {
                .init(devices: [.init(uid: "explicit", name: "Fixture", deviceID: 137),
                                .init(uid: "default", name: "Alternate", deviceID: 173)], defaultID: 173)
            }
            result.isBluetooth = { $0 == 137 }
            result.inputNode = { [unowned self] engine in devices.first { $0.engine === engine }!.node }
            result.bind = { [unowned self] target, node, _ in try devices.first { $0.node === node }!.bind(target) }
            result.isStillSelected = { target, node in (node as! KBFakeTapNode).currentDeviceID == target.deviceID }
            result.route = { _ in nil }
            result.defaultOutputID = { nil }
            return result
        }

        func capture(gate: MicrophoneStartupGate = .init(configuring: true),
                     explicitStart: Bool = true,
                     makeEvidence: @escaping @MainActor () -> MicrophoneEvidenceWriter? = { nil }) -> MicrophoneCapture {
            MicrophoneCapture(selectedInputUID: "explicit", startupGate: gate, explicitStart: explicitStart,
                              lifetime: lifetime, hardware: hardware, makeMicrophoneEvidence: makeEvidence)
        }

        @MainActor
        func warm(volumeGuard: OutputVolumeGuard = .init(enabled: false)) -> MicrophoneWarmKeeper {
            MicrophoneWarmKeeper(volumeGuard: volumeGuard, lifetime: lifetime, hardware: hardware, authorized: { true })
        }
    }

    @MainActor private final class CleanupLog {
        private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        private let consent = InputDiagnosticConsent(enabled: true)
        private lazy var writer = DiagnosticWriter(
            main: .init(fileURL: root.appendingPathComponent("main")),
            microphone: .init(fileURL: root.appendingPathComponent("mic")))

        func evidence() -> MicrophoneEvidenceWriter? {
            let writer = self.writer
            let consent = self.consent
            return MicrophoneEvidenceWriter(token: consent.token, permits: { consent.allows($0) }) {
                writer.append([$0], mirrored: true)
            }
        }

        func dispositions(count: Int) async throws -> [String] {
            for _ in 0..<100 {
                writer.flush()
                let contents = try? String(contentsOf: root.appendingPathComponent("mic"), encoding: .utf8)
                let lines = contents?.split(separator: "\n").compactMap { line -> String? in
                    guard let event = line.split(separator: " ", maxSplits: 1).last,
                          event.hasPrefix("mic_cleanup_disposition ") else { return nil }
                    return String(event)
                } ?? []
                if lines.count >= count { return lines }
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("Missing microphone cleanup evidence")
            return []
        }

        func clean() {
            writer.flush()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func lane<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            MicrophoneCapture.warmLifecycleQueue.async { continuation.resume(returning: body()) }
        }
    }

    private func readyForPCM(_ rig: Rig, index: Int) async throws {
        for _ in 0..<100 {
            if await lane({ rig.devices.indices.contains(index) && rig.devices[index].engine.starts == 1 }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Engine did not reach start")
        throw CancellationError()
    }

    private func awaitCommit(_ task: Task<Void, Error>, clock: Clock) async throws {
        let deadline = Task {
            try await Task.sleep(for: .seconds(1))
            clock.set(12.5)
        }
        defer { deadline.cancel() }
        try await task.value
    }

    private func feedStablePCM(_ rig: Rig, index: Int) async throws {
        try await readyForPCM(rig, index: index)
        await lane {
            let device = rig.devices[index]
            let first = rig.clock.now() + 0.01
            rig.clock.set(first)
            device.deliver(device.node.partialTap)
            rig.clock.set(first + 0.17)
            device.deliver(device.node.partialTap)
        }
    }

    private func failure(_ capture: MicrophoneCapture, deadline: TimeInterval = 12.5) async -> Error? {
        do {
            try await capture.start(deadline: deadline, onAudio: { _ in Issue.record("Failed attempt emitted audio") })
            Issue.record("Expected microphone preparation to fail")
            await capture.cancelAndWait()
            return nil
        } catch { return error }
    }

    private func expectGraphError(_ error: Error?, _ expected: MicrophoneGraphError, code: Int) {
        #expect(error as? MicrophoneGraphError == expected)
        #expect((error as NSError?)?.code == code)
        #expect((error as NSError?)?.domain == (expected as NSError).domain)
    }

    @Test func captureRecoversOnTheNextExplicitTake() async throws {
        let rig = Rig(.formatException, .none)
        let firstGate = MicrophoneStartupGate(configuring: true)
        let first = rig.capture(gate: firstGate)
        let error = await failure(first)
        expectGraphError(error, .formatException, code: 0)
        #expect(first.formatSnapshot?.tapRate == 16_000)
        #expect(first.formatSnapshot?.appliedRate == 0)
        #expect(firstGate.isStopped)
        #expect(first.recoveryDisposition == .replacementPending)
        let cause = try #require(error)
        #expect(VoiceController.microphoneStartFailureMessage(cause, disposition: first.recoveryDisposition)
                == "マイクの入力形式が変わりました。もう一度録音を開始してください")
        #expect(MicrophoneCapture.retryDelay(for: cause, policy: .init(), attempts: 1, elapsed: 0.1,
            disposition: first.recoveryDisposition) == nil)

        let warm = rig.warm()
        warm.resume(enabled: true, selectedUID: "explicit", takeActive: false, reason: "test")
        await lane {
            #expect(rig.factoryCalls == 1)
            let old = rig.devices[0]
            #expect(old.engine.stops == 1)
            #expect(old.engine.prepares == 0)
            #expect(old.node.installs == 1)
            #expect(old.node.removes == 0)
            #expect(old.node.partialTap != nil)
        }

        let continuation = rig.capture(explicitStart: false)
        expectGraphError(await failure(continuation), .quarantined, code: 3)
        #expect(continuation.recoveryDisposition == .replacementPending)

        let cancelledGate = MicrophoneStartupGate(configuring: true)
        cancelledGate.stop()
        #expect(await failure(rig.capture(gate: cancelledGate)) is CancellationError)
        let expired = rig.capture()
        #expect(await failure(expired, deadline: rig.clock.now()) != nil)
        #expect(rig.lifetime.disposition == .replacementPending)

        let secondGate = MicrophoneStartupGate(configuring: true)
        let second = rig.capture(gate: secondGate)
        let task = Task { try await second.start(deadline: 12.5, onAudio: { _ in Issue.record("Silence escaped admission") }) }
        defer { task.cancel() }
        try await readyForPCM(rig, index: 1)
        await first.cancelAndWait()
        await lane {
            let old = rig.devices[0]
            let current = rig.devices[1]
            #expect(old.engine !== current.engine)
            #expect(old.bound == [137])
            #expect(current.bound == [137])
            #expect(current.engine.prepares == 1)
            #expect(current.node.requested?.sampleRate == 16_000)
            #expect((try? rig.lifetime.acquire(for: .warm, canAcquire: true)) == nil)
            #expect((try? rig.lifetime.acquire(for: .capture, canAcquire: true)) == nil)
            old.deliver(old.node.partialTap, value: 0.5)
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: old.engine)
            #expect(old.engine.stops == 1)
            #expect(current.engine.stops == 0)
        }
        try await feedStablePCM(rig, index: 1)
        try await awaitCommit(task, clock: rig.clock)
        #expect(secondGate.didCommit)
        #expect(second.recoveryDisposition.message == nil)
        #expect(second.totalPCMBytes == 4096)
        #expect(second.sessionPeakAmplitude == 0)
        #expect(first.totalPCMBytes == 0)
        await second.cancelAndWait()
        await lane {
            #expect(rig.devices[1].engine.stops == 1)
            #expect(rig.devices[1].node.removes == 1)
            #expect(rig.factoryCalls == 2)
        }
    }

    @Test func formatExceptionAfterCommittedTakeReplacesStoppedGeneration() async throws {
        let rig = Rig(.none)
        let log = CleanupLog()
        defer { log.clean() }
        let firstGate = MicrophoneStartupGate(configuring: true)
        let first = rig.capture(gate: firstGate, makeEvidence: log.evidence)
        let firstTask = Task { try await first.start(deadline: 12.5, onAudio: { _ in }) }
        defer { firstTask.cancel() }
        try await feedStablePCM(rig, index: 0)
        try await awaitCommit(firstTask, clock: rig.clock)
        #expect(firstGate.didCommit)
        #expect(first.totalPCMBytes == 4096)
        let losses = await withCheckedContinuation { continuation in
            first.stop(.normal) { continuation.resume(returning: $0) }
        }
        #expect(losses == 0)
        #expect(first.recoveryDisposition == .normal)

        await lane {
            let old = rig.devices[0]
            #expect(old.engine.starts == 1)
            #expect(old.engine.stops == 1)
            #expect(old.node.removes == 1)
            old.node.switchDeviceDuringInstall = true
            old.engine.raiseOnStop = true
        }
        let failedGate = MicrophoneStartupGate(configuring: true)
        let failed = rig.capture(gate: failedGate, makeEvidence: log.evidence)
        expectGraphError(await failure(failed), .formatException, code: 0)
        #expect(failedGate.isStopped)
        #expect(!failedGate.didCommit)
        #expect(failed.formatSnapshot?.appliedRate == 0)
        #expect(failed.recoveryDisposition == .replacementPending)

        let lines = try await log.dispositions(count: 2)
        #expect(lines.count == 2)
        #expect(lines.filter { $0.contains("preCommitFormatException=true") } == [
            "mic_cleanup_disposition generation=1 preCommitFormatException=true hadTap=false engineStarted=false"
            + " stopped=false removed=not_required preflightStopped=true runningAtCleanup=false"
            + " succeeded=true disposition=\(failed.recoveryDisposition)"
        ])

        let warm = rig.warm()
        warm.resume(enabled: true, selectedUID: "explicit", takeActive: false, reason: "test")
        await lane {
            #expect(rig.factoryCalls == 1)
            #expect(rig.lifetime.disposition == .replacementPending)
            let old = rig.devices[0]
            #expect(old.bound == [137, 137])
            #expect(old.node.installs == 2)
            #expect(old.node.partialTap != nil)
            #expect(old.engine.starts == 1)
            #expect(old.engine.stops == 2)
            #expect(old.node.removes == 1)
        }

        let nextGate = MicrophoneStartupGate(configuring: true)
        let next = rig.capture(gate: nextGate)
        let nextTask = Task {
            try await next.start(deadline: 12.5, onAudio: { _ in Issue.record("Unexpected admitted audio") })
        }
        defer { nextTask.cancel() }
        try await readyForPCM(rig, index: 1)
        await lane {
            let old = rig.devices[0]
            let current = rig.devices[1]
            #expect(old.engine !== current.engine)
            #expect(current.bound == [137])
            #expect(current.node.installs == 1)
            #expect(current.engine.prepares == 1)
            old.deliver(old.node.partialTap, value: 0.5)
        }
        try await feedStablePCM(rig, index: 1)
        try await awaitCommit(nextTask, clock: rig.clock)
        #expect(nextGate.didCommit)
        #expect(next.totalPCMBytes == 4096)
        #expect(next.sessionPeakAmplitude == 0)
        #expect(failed.totalPCMBytes == 0)
        await next.cancelAndWait()
        await lane {
            let lease = try? rig.lifetime.acquire(for: .capture, canAcquire: true)
            #expect(lease?.resource === rig.devices[1].engine)
            if let lease { #expect(rig.lifetime.release(token: lease.token)) }
            #expect(rig.devices[0].node.installs == 2)
            #expect(rig.factoryCalls == 2)
        }
    }

    @Test(arguments: [false, true])
    func receiptRequiresBothNativeOperations(failStop: Bool) async throws {
        let rig = Rig(.topologyAfter)
        rig.configureDevice = { device in
            device.engine.raiseOnStop = failStop
            device.node.raiseOnRemove = !failStop
        }
        let log = CleanupLog()
        defer { log.clean() }
        let capture = rig.capture(makeEvidence: log.evidence)
        expectGraphError(await failure(capture), .unexpectedTopology, code: 2)
        #expect(capture.recoveryDisposition == .terminal)
        await lane {
            #expect(rig.devices[0].engine.stops == 1)
            #expect(rig.devices[0].node.removes == 1)
            #expect(rig.factoryCalls == 1)
        }
        let lines = try await log.dispositions(count: 1)
        #expect(lines == [
            "mic_cleanup_disposition generation=1 preCommitFormatException=false hadTap=true engineStarted=false"
            + " stopped=\(!failStop) removed=\(failStop) preflightStopped=true runningAtCleanup=unknown"
            + " succeeded=false disposition=\(capture.recoveryDisposition)"
        ])
        expectGraphError(await failure(rig.capture()), .quarantined, code: 3)
    }

    @Test(arguments: [false, true])
    func calledStartWithoutReceiptStillRequiresSuccessfulStop(startThrows: Bool) async throws {
        let rig = Rig(.stopException)
        let worker = MicrophoneWarmKeeper.Worker(volumeGuard: .init(enabled: false),
            lifetime: rig.lifetime, hardware: rig.hardware)
        rig.configureDevice = { [weak worker] device in
            device.engine.failStart = startThrows
            device.node.afterRetainTap = { [weak worker, weak node = device.node] in
                guard let lease = worker?.lease, let node else {
                    Issue.record("Missing lease at native install boundary")
                    return
                }
                let graph = LeasedMicrophoneTapGraph(lifetime: rig.lifetime, lease: lease, node: node) { true }
                do {
                    try graph.start()
                    #expect(!startThrows)
                } catch {
                    #expect(startThrows)
                }
            }
        }
        let log = CleanupLog()
        defer { log.clean() }
        let evidence = log.evidence()
        let gate = MicrophoneStartupGate(configuring: true)
        await lane {
            worker.resume(enabled: true, uid: "explicit", takeActive: false, reason: "test",
                          gate: gate, deadline: 12.5, evidence: nil, cleanupEvidence: evidence, changed: {})
            rig.configureDevice = nil
            let device = rig.devices[0]
            device.node.afterRetainTap = nil
            #expect(device.engine.starts == 1)
            #expect(device.engine.stops == 1)
            #expect(device.node.removes == 0)
            #expect(worker.lease == nil)
            #expect(gate.isStopped)
        }
        #expect(rig.lifetime.disposition == .terminal)
        let started = startThrows ? "unknown" : "true"
        let lines = try await log.dispositions(count: 1)
        #expect(lines == [
            "mic_cleanup_disposition generation=1 preCommitFormatException=true hadTap=false engineStarted=\(started)"
            + " stopped=false removed=not_required preflightStopped=true runningAtCleanup=unknown"
            + " succeeded=false disposition=terminal"
        ])
        expectGraphError(await failure(rig.capture()), .quarantined, code: 3)
        await lane { #expect(rig.factoryCalls == 1) }
    }

    @Test(arguments: [Fault.unknownException, .topologyBefore, .topologyAfter, .removeException,
                       .stopException, .unprovenStop, .unreadableStop, .preflight, .readback], [false, true])
    private func firstGenerationFailures(_ fault: Fault, warm: Bool) async {
        let rig = Rig(fault)
        if warm {
            let keeper = rig.warm()
            var oldNotifications = 0
            keeper.onConfigurationChange = { oldNotifications += 1 }
            keeper.resume(enabled: true, selectedUID: "explicit", takeActive: false, reason: "test")
            await lane {}
            keeper.suspend()
            keeper.suspend()
            await lane {
                NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: rig.devices[0].engine)
            }
            #expect(oldNotifications == 0)
        } else {
            let gate = MicrophoneStartupGate(configuring: true)
            let capture = rig.capture(gate: gate)
            let error = await failure(capture)
            #expect(gate.isStopped)
            switch fault {
            case .unknownException: expectGraphError(error, .unknownException, code: 1)
            case .topologyBefore, .topologyAfter, .removeException: expectGraphError(error, .unexpectedTopology, code: 2)
            case .stopException, .unprovenStop, .unreadableStop: expectGraphError(error, .formatException, code: 0)
            case .preflight, .readback:
                #expect((error as? MicrophoneCapture.CaptureError)?.diagnosticCategory == "format_changed")
            default: Issue.record("Unexpected fixture")
            }
        }
        await lane {
            let device = rig.devices[0]
            #expect(device.engine.stops == 1)
            #expect(device.engine.starts == 0)
            #expect(device.engine.prepares == 0)
            #expect(device.node.installs == ([.topologyBefore, .preflight].contains(fault) ? 0 : 1))
            #expect(device.node.removes == ([.topologyAfter, .readback, .removeException].contains(fault) ? 1 : 0))
            #expect(rig.factoryCalls == 1)
        }
        let expected: MicrophoneCapture.EngineLifetime.Disposition
        switch fault {
        case .preflight, .readback: expected = .normal
        case .stopException: expected = .replacementPending
        default: expected = .terminal
        }
        #expect(rig.lifetime.disposition == expected)
        if expected == .terminal {
            expectGraphError(await failure(rig.capture()), .quarantined, code: 3)
        }
    }

    @Test func warmFailureHandsOffToCaptureInFIFOOrder() async throws {
        let rig = Rig(.formatException, .none)
        let keeper = rig.warm()
        keeper.resume(enabled: true, selectedUID: "explicit", takeActive: false, reason: "test")
        await lane {}
        #expect(rig.lifetime.disposition == .replacementPending)
        let next = rig.capture()
        keeper.suspend(handingTo: next)
        let task = Task { try await next.start(deadline: 12.5, onAudio: { _ in }) }
        defer { task.cancel() }
        try await feedStablePCM(rig, index: 1)
        try await awaitCommit(task, clock: rig.clock)
        await next.cancelAndWait()

        keeper.resume(enabled: true, selectedUID: "explicit", takeActive: false, reason: "test")
        await lane {
            #expect(rig.devices[0].engine.stops == 1)
            #expect(rig.devices[0].node.removes == 0)
            #expect(rig.devices[1].engine.starts == 2)
        }
        let handed = rig.capture()
        keeper.suspend(handingTo: handed)
        let handedTask = Task { try await handed.start(deadline: 12.5, onAudio: { _ in }) }
        defer { handedTask.cancel() }
        for _ in 0..<100 {
            if await lane({ rig.devices[1].engine.starts == 3 }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await lane {
            let current = rig.devices[1]
            #expect(current.engine.starts == 3)
            #expect(current.engine.stops == 2)
            #expect(current.node.removes == 2)
            let first = rig.clock.now() + 0.01
            rig.clock.set(first)
            current.deliver(current.node.partialTap)
            rig.clock.set(first + 0.17)
            current.deliver(current.node.partialTap)
        }
        try await awaitCommit(handedTask, clock: rig.clock)
        await handed.cancelAndWait()
    }

    @Test(arguments: [Fault.bind, .prepare, .readback, .start, .noPCM, .formatException, .deadlineOnStart])
    private func replacementVerificationFailureIsTerminal(_ fault: Fault) async throws {
        let rig = Rig(.formatException, fault)
        _ = await failure(rig.capture())
        let capture = rig.capture()
        let task = Task { await failure(capture) }
        defer { task.cancel() }
        if fault == .noPCM {
            try await readyForPCM(rig, index: 1)
            rig.clock.set(12.5)
        }
        let error = try #require(await task.value)
        switch fault {
        case .bind: #expect(error as? MicrophoneDevices.DeviceError == .selectionNotApplied)
        case .prepare: #expect((error as NSError).code == 0)
        case .start:
            #expect((error as NSError).domain == NSOSStatusErrorDomain)
            #expect((error as NSError).code == -50)
        case .formatException: expectGraphError(error, .formatException, code: 0)
        case .readback: #expect((error as? MicrophoneCapture.CaptureError)?.diagnosticCategory == "format_changed")
        case .noPCM: #expect((error as? MicrophoneCapture.CaptureError)?.diagnosticCategory == "no_buffers")
        case .deadlineOnStart: #expect((error as? MicrophoneCapture.CaptureError)?.diagnosticCategory == "unstable_buffers")
        default: Issue.record("Unexpected fixture")
        }
        #expect(capture.recoveryDisposition == .terminal)
        #expect(VoiceController.microphoneStartFailureMessage(error, disposition: capture.recoveryDisposition)
                == "マイクの安全な状態を確認できません。アプリを再起動してください")
        #expect(MicrophoneCapture.retryDelay(for: error, policy: .init(), attempts: 1, elapsed: 0.1,
            disposition: capture.recoveryDisposition) == nil)
        expectGraphError(await failure(rig.capture(), deadline: 15), .quarantined, code: 3)
        await lane {
            #expect(rig.factoryCalls == 2)
            #expect(rig.devices[0].engine.stops == 1)
            #expect(rig.devices[1].engine.stops == 1)
            #expect(rig.devices[1].node.removes == ([.bind, .formatException].contains(fault) ? 0 : 1))
        }
    }

    @Test(arguments: [false, true])
    func factoryFailureDoesNotReuseRetiredEngine(duplicate: Bool) async {
        let rig = Rig(.formatException, .none)
        rig.returnSameEngine = duplicate
        rig.failFactory = !duplicate
        _ = await failure(rig.capture())
        let next = rig.capture()
        let initialError = await failure(next)
        let factoryError = initialError as? MicrophoneCapture.EngineLifetime.AcquisitionError
        #expect(factoryError == (duplicate ? .retiredEngineReturned : .factoryFailed))
        #expect(next.recoveryDisposition == .terminal)
        expectGraphError(await failure(rig.capture()), .quarantined, code: 3)
        await lane {
            #expect(rig.factoryCalls == 2)
            #expect(rig.devices.count == 1)
            #expect(rig.devices[0].engine.stops == 1)
            #expect(rig.devices[0].node.installs == 1)
        }
    }

    @Test(arguments: [false, true])
    func startupWindowClosesInsideReplacementFactory(cancelled: Bool) async {
        let rig = Rig(.formatException, .none)
        _ = await failure(rig.capture())
        let gate = MicrophoneStartupGate(configuring: true)
        rig.factoryHook = { [unowned rig] in
            #expect((try? rig.lifetime.acquire(for: .warm, canAcquire: true)) == nil)
            #expect((try? rig.lifetime.acquire(for: .capture, canAcquire: true)) == nil)
            if cancelled { gate.stop() }
            else { rig.clock.set(12.5) }
        }
        let next = rig.capture(gate: gate)
        let error = await failure(next)
        if cancelled {
            #expect(error is CancellationError)
            let cause = CancellationError()
            #expect(VoiceController.microphoneStartFailureMessage(cause, disposition: next.recoveryDisposition)
                    == VoiceController.microphoneStartFailureMessage(cause, disposition: .normal))
        } else { #expect((error as? MicrophoneCapture.CaptureError)?.diagnosticCategory == "unstable_buffers") }
        #expect(next.recoveryDisposition == .terminal)
        await lane {
            #expect(rig.factoryCalls == 2)
            #expect(rig.devices[1].bound.isEmpty)
            #expect(rig.devices[1].engine.stops == 1)
            #expect(rig.devices[1].node.installs == 0)
        }
    }

    @Test func warmSuspendRemovesObserverAndEndsVolumeMonitoring() async throws {
        let rig = Rig(.none)
        rig.clock.set(ProcessInfo.processInfo.systemUptime)
        let uid: UInt32 = 41
        let readback = OutputVolumeReading(uid: "output", device: uid, muted: false, volumes: [.virtualMain: 0.5])
        var guardHardware = OutputVolumeGuard.Hardware()
        var additions = 0
        var removals = 0
        guardHardware.defaultDevice = { uid }
        guardHardware.sample = { _, _ in .init(reading: readback, settable: []) }
        guardHardware.add = { _, _, _, _ in additions += 1; return noErr }
        guardHardware.remove = { _, _, _, _ in removals += 1; return noErr }
        let guardController = OutputVolumeGuard(enabled: true, hardware: guardHardware)
        var hardware = rig.hardware
        hardware.defaultOutputID = { uid }
        let keeper = MicrophoneWarmKeeper(volumeGuard: guardController, lifetime: rig.lifetime,
                                          hardware: hardware, authorized: { true })
        var notifications = 0
        keeper.onConfigurationChange = { notifications += 1 }
        keeper.resume(enabled: true, selectedUID: "explicit", takeActive: false, reason: "test")
        let engine = await lane { rig.devices.first?.engine }
        let running = try #require(engine)
        guardController.queue.sync {
            #expect(additions > 0)
            #expect(removals == 0)
        }
        keeper.suspend()
        await lane {
            #expect(running.stops == 1)
            #expect(rig.devices[0].node.removes == 1)
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: running)
        }
        await Task.yield()
        #expect(notifications == 0)
        guardController.queue.sync { #expect(removals == additions) }
        #expect(rig.lifetime.disposition == .normal)
    }

    @Test func staleWarmStopDoesNotTouchNewLease() async throws {
        let rig = Rig(.none)
        let gate = MicrophoneStartupGate(configuring: true)
        let guardController = OutputVolumeGuard(enabled: false)
        let worker = MicrophoneWarmKeeper.Worker(volumeGuard: guardController,
            lifetime: rig.lifetime, hardware: rig.hardware)
        let retained = await lane {
            worker.resume(enabled: true, uid: "explicit", takeActive: false, reason: "test",
                          gate: gate, deadline: 12.5, evidence: nil, changed: { Issue.record("Stale observer ran") })
            return worker.lease
        }
        let stale = try #require(retained)
        await lane {
            // Inject lease loss at the lifetime boundary to make the old Worker
            // hold a real native receipt while a different owner holds the token.
            #expect(rig.lifetime.release(token: stale.token))
            guard let current = try? rig.lifetime.acquire(for: .capture, canAcquire: true) else {
                Issue.record("Failed to create the newer owner")
                return
            }
            worker.stop(reason: "stale")
            worker.stop(reason: "stale")
            let device = rig.devices[0]
            #expect(gate.isStopped)
            #expect(worker.lease == nil)
            #expect(device.engine.stops == 0)
            #expect(device.node.removes == 0)
            #expect(rig.lifetime.isCurrent(token: current.token))
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: device.engine)
            #expect(!rig.lifetime.release(token: stale.token))
            #expect(rig.lifetime.beginCleanup(current))
            #expect(LeasedMicrophoneTapGraph.stopEngine(device.engine))
            // The fixture tap belonged to the stale token, so even the
            // newer owner cannot remove it.
            #expect(rig.lifetime.finishCleanup(current, evidence: .init(stopped: true, hadTap: true)) == .terminal)
        }
    }

    @Test func lifetimeRetainsRetiredEngineAfterTheOldLeaseIsGone() throws {
        let lifetime = MicrophoneEngineLifetime { NSObject() }
        weak var retired: NSObject?
        do {
            let first = try #require(try lifetime.acquire(for: .capture, canAcquire: true))
            retired = first.resource
            lifetime.recordPreflightStopped(true, for: first)
            lifetime.retire(first, preCommitFormatException: true)
            #expect(!lifetime.isCurrent(token: first.token))
            #expect((try? lifetime.acquire(for: .capture, canAcquire: true)) == nil)
            #expect(lifetime.beginCleanup(first))
            #expect(!lifetime.beginCleanup(first))
            #expect(lifetime.finishCleanup(first, evidence: .init(stopped: true, hadTap: false, runningAtCleanup: false)) == .replacementPending)
        }
        let second = try #require(try lifetime.acquire(for: .capture, canAcquire: true))
        #expect(retired != nil)
        #expect(retired !== second.resource)
        withExtendedLifetime(lifetime) {}
    }

    @Test func committedReplacementKeepsExistingInterruptionPath() async throws {
        let rig = Rig(.formatException, .none)
        _ = await failure(rig.capture())
        let capture = rig.capture()
        let interrupted = expectationFlag()
        let take = Task {
            try await capture.start(deadline: 12.5, onAudio: { _ in },
                                    onDeviceChanged: { interrupted.set(1) })
        }
        defer { take.cancel() }
        try await feedStablePCM(rig, index: 1)
        try await awaitCommit(take, clock: rig.clock)
        await lane {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: rig.devices[1].engine)
        }
        for _ in 0..<100 {
            if interrupted.now() == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(interrupted.now() == 1)
        #expect(capture.lostBufferCount == 1)
        await capture.cancelAndWait()
        #expect(rig.lifetime.disposition == .normal)
    }

    private func expectationFlag() -> Clock {
        let clock = Clock()
        clock.set(0)
        return clock
    }
}
#endif
