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
        let engine: KBFakeMicrophoneEngine
        let node = KBFakeTapNode()
        let fault: Fault
        private(set) var bound: [UInt32] = []
        var rejectBind: Bool

        init(_ fault: Fault, clock: Clock, engine: KBFakeMicrophoneEngine) {
            self.fault = fault
            rejectBind = fault == .bind
            self.engine = engine
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
            if rejectBind { throw MicrophoneDevices.DeviceError.selectionNotApplied }
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
        var makeHardwareEngine: () -> KBFakeMicrophoneEngine = { KBFakeMicrophoneEngine() }

        init(_ faults: Fault...) { self.faults = faults }

        private func makeEngine() -> AVAudioEngine? {
            factoryCalls += 1
            factoryHook?()
            if factoryCalls > 1 {
                if returnSameEngine { return devices[0].engine }
                if failFactory { return nil }
            }
            let device = Device(faults[min(devices.count, faults.count - 1)], clock: clock, engine: makeHardwareEngine())
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
                     explicitStart: Bool = true, takeID: UUID = UUID(),
                     makeEvidence: @escaping @MainActor () -> MicrophoneEvidenceWriter? = { nil }) -> MicrophoneCapture {
            MicrophoneCapture(selectedInputUID: "explicit", takeID: takeID, startupGate: gate, explicitStart: explicitStart,
                              lifetime: lifetime, hardware: hardware, makeMicrophoneEvidence: makeEvidence)
        }

        @MainActor
        func warm(volumeGuard: OutputVolumeGuard = .init(enabled: false)) -> MicrophoneWarmKeeper {
            MicrophoneWarmKeeper(volumeGuard: volumeGuard, lifetime: lifetime, hardware: hardware, authorized: { true })
        }
    }

    @MainActor private final class CleanupLog {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var consent = InputDiagnosticConsent(enabled: true)
        private lazy var writer = DiagnosticWriter(
            main: .init(fileURL: root.appendingPathComponent("main")),
            microphone: .init(fileURL: root.appendingPathComponent("mic")))

        func evidence() -> MicrophoneEvidenceWriter? {
            DiagnosticLog.microphoneEvidenceWriter(token: consent.token,
                permits: { [self] in consent.allows($0) }, writer: self.writer)
        }

        func startupTrace(_ id: UUID, _ explicit: Bool, clock: Clock? = nil,
                          checkedConsent: (@MainActor @Sendable () -> Void)? = nil) -> MicrophonePreparationDiagnostics? {
            DiagnosticLog.microphoneTrace(captureID: id, explicitSelection: explicit, build: 0,
                token: consent.token, permits: { [self] token in
                    checkedConsent?()
                    return consent.allows(token)
                }, writer: self.writer, clock: { clock?.now() ?? ProcessInfo.processInfo.systemUptime })
        }

        func inputTrace(_ id: UUID) -> InputDiagnosticTrace? {
            guard let token = consent.token else { return nil }
            let writer = self.writer
            return InputDiagnosticTrace(takeID: id, consent: token, permits: { [self] in self.consent.allows($0) }) { [self] lines, token in
                DiagnosticLog.writeInputTrace(lines, consent: token, permits: { [self] in self.consent.allows($0) }, writer: writer)
            }
        }

        func writeInput(_ lines: () -> [String], token: InputDiagnosticConsent.Token) {
            DiagnosticLog.writeInputTrace(lines, consent: token, permits: { [self] in consent.allows($0) }, writer: writer)
        }

        func session(_ event: () -> String) {
            DiagnosticLog.record(event, enabled: { consent.isEnabled }, writer: writer)
        }

        func microphone(_ event: () -> String) {
            DiagnosticLog.recordMicrophoneEvidence(event, makeWriter: evidence)
        }

        func read(_ store: String = "main") -> [String] {
            writer.flush()
            let contents = try? String(contentsOf: root.appendingPathComponent(store), encoding: .utf8)
            return contents?.split(separator: "\n").compactMap {
                $0.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init)
            } ?? []
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

    @Test(arguments: [Fault.prepare, .readback, .start, .noPCM, .formatException, .deadlineOnStart])
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
            #expect(rig.devices[1].node.removes == (fault == .formatException ? 0 : 1))
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
        let log = CleanupLog()
        defer { log.clean() }
        let evidence = try #require(log.evidence())
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
            let disposition = rig.lifetime.finishCleanup(current,
                evidence: .init(stopped: true, hadTap: true, removed: nil),
                record: { evidence.enqueue($0) })
            #expect(disposition == .terminal)
        }
        let lines = try await log.dispositions(count: 1)
        #expect(lines == [
            "mic_cleanup_disposition generation=1 preCommitFormatException=false hadTap=true engineStarted=false"
            + " stopped=true removed=unknown preflightStopped=false runningAtCleanup=unknown"
            + " succeeded=false disposition=terminal"
        ])
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

    /// The next HAL selection read owns this barrier. The test supplies only
    /// the selection result and can hold the read across a real shortcut.
    private final class SelectionRead: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var entered = false
        private var matches = true
        private let release = DispatchSemaphore(value: 0)

        var isBlocked: Bool { lock.withLock { entered } }

        func arm() { lock.withLock { armed = true } }

        func select(actual: Bool) -> Bool {
            let block = lock.withLock {
                guard armed else { return false }
                armed = false
                entered = true
                return true
            }
            guard block else { return actual }
            guard release.wait(timeout: .now() + 4) == .success else {
                Issue.record("HAL selection read was never released")
                return actual
            }
            return lock.withLock { matches }
        }

        func complete(matches: Bool) {
            lock.withLock { self.matches = matches }
            release.signal()
        }
    }

    private final class BlockingStopEngine: KBFakeMicrophoneEngine {
        let stopBarrier = SelectionRead()

        override func stop() {
            _ = stopBarrier.select(actual: true)
            super.stop()
        }
    }

    private final class PreparationAttempt {
        let gate = MicrophoneStartupGate(configuring: true)
        let read = SelectionRead()
        let uid: String
        let takeID: UUID
        let explicitStart: Bool
        var capture: MicrophoneCapture!
        var captureID: UUID?
        var deviceListReads = 0 // lifecycle lane only
        var snapshots: [UInt32] = [] // lifecycle lane only

        init(uid: String, takeID: UUID, explicitStart: Bool) {
            self.uid = uid
            self.takeID = takeID
            self.explicitStart = explicitStart
        }
    }

    @MainActor private final class PreparationReplay {
        let log = CleanupLog()
        let rig: Rig
        private(set) var attempts: [PreparationAttempt] = []
        private(set) var task: Task<Void, Never>?
        private(set) var preparationFinished = false
        private(set) var waits: [TimeInterval] = []
        private(set) var audio: [Data] = []
        var wait: ((TimeInterval) async throws -> Void)?
        var hardwareForAttempt: ((Int, MicrophoneHardware) -> MicrophoneHardware)?
        var selectedUID = "explicit"
        var recognitionResult: String?

        init(rig: Rig = Rig(.none)) { self.rig = rig }

        lazy var controller: VoiceController = {
            var environment = VoiceController.PreparationEnvironment()
            environment.permission = { true }
            environment.selectedInputUID = { [unowned self] in selectedUID }
            environment.makeCapture = { [unowned self] uid, volumeGuard, id, explicit in
                let attempt = PreparationAttempt(uid: uid, takeID: id, explicitStart: explicit)
                var hardware = rig.hardware
                hardware.snapshot = { [read = hardware.snapshot, weak attempt] in
                    attempt?.deviceListReads += 1
                    return try read()
                }
                hardware.isStillSelected = { [read = attempt.read] target, node in
                    read.select(actual: (node as! KBFakeTapNode).currentDeviceID == target.deviceID)
                }
                hardware.route = { [weak attempt] id in
                    attempt?.snapshots.append(id)
                    return .init(inputDeviceID: id, outputDeviceID: 211,
                                 inputTransport: "bluetooth", outputTransport: "built_in")
                }
                hardware = hardwareForAttempt?(attempts.count, hardware) ?? hardware
                let capture = MicrophoneCapture(selectedInputUID: uid, volumeGuard: volumeGuard,
                    takeID: id, startupGate: attempt.gate, explicitStart: explicit, lifetime: rig.lifetime,
                    hardware: hardware, makeMicrophoneEvidence: log.evidence,
                    makeStartupTrace: { [weak attempt, log, clock = rig.clock] captureID, selection in
                        attempt?.captureID = captureID
                        return log.startupTrace(captureID, selection, clock: clock)
                    }, makeSpeechTrace: log.inputTrace)
                attempt.capture = capture
                attempts.append(attempt)
                return capture
            }
            environment.now = rig.clock.now
            environment.waitBeforeRetry = { [unowned self] delay in
                waits.append(delay)
                if let wait { try await wait(delay) }
                else { rig.clock.set(rig.clock.now() + delay) }
            }
            environment.makeInputTrace = log.inputTrace
            environment.recordSession = log.session
            environment.recordMicrophone = log.microphone
            environment.captureTarget = { _ in (target: nil, reason: "target_not_captured") }
            if recognitionResult != nil { environment.shouldPaste = false }
            environment.consumeAudio = { [weak self] stream in
                var receivedAudio = false
                for await packet in stream {
                    receivedAudio = true
                    self?.audio.append(packet)
                }
                return receivedAudio ? self?.recognitionResult : nil
            }
            environment.preparationLaunched = { [weak self] task in
                self?.task = task
                self?.preparationFinished = false
                Task { [weak self] in
                    await task.value
                    self?.preparationFinished = true
                }
            }
            return VoiceController(preparation: environment, storageDirectory: log.root)
        }()

        func finish() {
            for attempt in attempts { attempt.read.complete(matches: false) }
            task?.cancel()
            log.clean()
        }

        func stage(_ attempt: PreparationAttempt, _ field: String) -> [String] {
            guard let id = attempt.captureID else { return [] }
            return log.read("mic").filter {
                $0.hasPrefix("mic_start ") && $0.contains("capture=\(id.uuidString) ") &&
                $0.split(separator: " ").contains(Substring(field))
            }
        }

        private func takeLines(_ take: UUID) -> [String] {
            log.read().filter {
                $0.hasPrefix("input_diag ") && $0.contains("take=\(take.uuidString.lowercased()) ")
            }
        }

        func results(take: UUID) -> [String] {
            let lines = takeLines(take).filter { $0.contains("stage=result kind=result ") }
            // Physical parts share a v1 event number. The v2 summaries are
            // intentionally excluded because they repeat those same events.
            let events = Dictionary(grouping: lines) {
                $0.split(separator: " ").first { $0.hasPrefix("event=") }
            }
            return events.values.map { $0.joined(separator: " ") }
        }

        func hasPostingActivity(take: UUID) -> Bool {
            takeLines(take).contains { $0.contains("stage=posting kind=progress ") }
        }

        func failures() -> [String] {
            log.read("mic").filter { $0.hasPrefix("mic_prepare_failed ") }
        }

        func requestedAttempts() -> [String] {
            log.read("mic").filter { $0.hasPrefix("mic_prepare_attempt ") }
        }
    }

    private func observe(_ message: String, log: CleanupLog? = nil,
                         until predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("\(message)\n\(log?.read().suffix(28).joined(separator: "\n") ?? "")")
        throw CancellationError()
    }

    private func awaitEngine(_ replay: PreparationReplay, index: Int) async throws -> PreparationAttempt {
        try await observe("Capture did not reach engine_start", log: replay.log) {
            replay.attempts.indices.contains(index) && replay.stage(replay.attempts[index], "stage=await_pcm").contains {
                $0.contains("event=begin")
            }
        }
        return replay.attempts[index]
    }

    private func resumeAndHoldSelection(_ replay: PreparationReplay, index: Int) async throws
        -> (PreparationAttempt, Device, AVAudioNodeTapBlock) {
        let attempt = try await awaitEngine(replay, index: index)
        let (device, tap) = await lane {
            let device = replay.rig.devices[0]
            let tap = device.node.partialTap
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: device.engine)
            replay.rig.clock.set(replay.rig.clock.now() + 0.08)
            return (device, tap)
        }
        try await observe("No real revalidation resume", log: replay.log) {
            !replay.stage(attempt, "revalidation_outcome=resume").isEmpty
        }
        attempt.read.arm()
        try await observe("Post-resume HAL selection read did not block", log: replay.log) { attempt.read.isBlocked }
        return (attempt, device, try #require(tap))
    }

    private func stablePCM(_ replay: PreparationReplay, device: Device, tap: @escaping AVAudioNodeTapBlock) {
        let first = replay.rig.clock.now() + 0.01
        replay.rig.clock.set(first)
        device.deliver(tap)
        replay.rig.clock.set(first + 0.17)
        device.deliver(tap)
    }

    private func awaitDelivery(_ replay: PreparationReplay, take: UUID) async throws -> [String] {
        try await observe("Ordered delivery did not finish", log: replay.log) {
            !replay.results(take: take).isEmpty
        }
        #expect(!replay.hasPostingActivity(take: take))
        return replay.results(take: take)
    }

    private func awaitPreparationEnd(_ replay: PreparationReplay) async throws {
        try await observe("Controller startup task did not exit", log: replay.log) { replay.preparationFinished }
    }

    @Test func livePreparationRetriesAfterPostResumeSelectionLoss() async throws {
        let replay = PreparationReplay()
        defer { replay.finish() }
        replay.controller.toggle()
        let (old, device, oldTap) = try await resumeAndHoldSelection(replay, index: 0)
        device.deliver(oldTap, value: 0.5)
        try await observe("Old PCM was not buffered") { old.gate.firstBufferTime != nil }
        old.read.complete(matches: false)

        let fresh = try await awaitEngine(replay, index: 1)
        let failures = replay.failures()
        #expect(failures.count == 1)
        let failed = try #require(failures.first)
        let expectedCode = (MicrophoneCapture.CaptureError.notReady(.inputRouteChanged) as NSError).code
        #expect(failed.contains("take=\(old.takeID.uuidString) attempt=1 category=input_route_changed code=\(expectedCode)"))
        #expect(fresh.takeID == old.takeID)
        #expect(fresh.capture !== old.capture)
        #expect(fresh.captureID != old.captureID)
        #expect([old.uid, fresh.uid] == ["explicit", "explicit"])
        #expect(old.explicitStart && !fresh.explicitStart)
        #expect(!old.gate.didCommit)
        #expect(old.capture.totalPCMBytes == 0)
        #expect(!replay.stage(old, "stage=input_route_changed").isEmpty)
        #expect(!replay.stage(old, "stage=start_failed").isEmpty)
        #expect(replay.waits == [0.05])
        let tap = try #require(await lane {
            #expect(device.bound == [137, 137])
            #expect(old.deviceListReads == 1 && fresh.deviceListReads == 1)
            #expect(old.snapshots == [137] && fresh.snapshots == [137])
            #expect(device.engine.stops == 1)
            #expect(device.node.removes == 1)
            return device.node.partialTap
        })
        device.deliver(oldTap, value: 0.5)
        stablePCM(replay, device: device, tap: tap)
        try await observe("Retry did not become recording", log: replay.log) { replay.controller.phase == .recording }
        try await awaitPreparationEnd(replay)
        #expect(fresh.gate.didCommit)
        #expect(fresh.capture.totalPCMBytes == 4096)
        #expect(fresh.capture.sessionPeakAmplitude == 0)
        #expect(replay.audio.isEmpty)
        let take = old.takeID.uuidString
        #expect(replay.requestedAttempts() == [
            "mic_prepare_attempt take=\(take) attempt=1", "mic_prepare_attempt take=\(take) attempt=2"
        ])
        let ready = replay.log.read("mic").filter { $0.hasPrefix("mic_prepare_ready ") }
        #expect(ready.count == 1)
        #expect(ready.first?.hasPrefix("mic_prepare_ready take=\(take) attempts=2 ") == true)
        #expect(!replay.stage(fresh, "stage=ready").isEmpty)
        #expect(!replay.stage(old, "stage=stopped").isEmpty)
        #expect(replay.log.read().filter { $0.hasPrefix("session resolved;") }.isEmpty)
        replay.controller.toggle()
        let result = try await awaitDelivery(replay, take: old.takeID)
        #expect(result.count == 1)
        #expect(result.first?.contains("reason=no_input") == true)
        #expect(result.first?.contains("events_posted=0") == true)
        #expect(!result.contains { $0.contains("delivery_cancelled_before_post") })
        #expect(replay.log.read().filter { $0.hasPrefix("session resolved;") }.count == 1)
        let cleanup = try await replay.log.dispositions(count: 2)
        #expect(cleanup.allSatisfy { $0.contains("succeeded=true disposition=normal") })
    }

    @Test func preparingCancelWinsBeforeTheHALReadReturns() async throws {
        let replay = PreparationReplay()
        defer { replay.finish() }
        let engine = BlockingStopEngine()
        replay.rig.makeHardwareEngine = { engine }
        replay.controller.toggle()
        let (attempt, _, _) = try await resumeAndHoldSelection(replay, index: 0)
        engine.stopBarrier.arm()
        defer { engine.stopBarrier.complete(matches: true) }
        #expect(replay.controller.phase == .preparing)
        replay.controller.toggle()
        #expect(replay.controller.phase == .idle)
        #expect(attempt.gate.isStopped)
        let immediate = replay.log.read().filter {
            $0 == "session discarded by user" || $0.hasPrefix("session resolved;")
        }
        #expect(immediate.count == 2)
        #expect(immediate.first == "session discarded by user")
        #expect(immediate.last?.contains("accepted=true noInput=true") == true)
        attempt.read.complete(matches: false)
        // Model the field teardown duration. A fast native stop can close
        // mic_start before the suspended start() handles its stopped decision.
        try await observe("Cancellation did not reach start catch before teardown", log: replay.log) {
            engine.stopBarrier.isBlocked && !replay.stage(attempt, "stage=start_failed").isEmpty
        }
        engine.stopBarrier.complete(matches: true)
        try await awaitPreparationEnd(replay)
        let result = try await awaitDelivery(replay, take: attempt.takeID)
        #expect(result.count == 1)
        #expect(result.first?.contains("outcome=cancelled") == true)
        #expect(result.first?.contains("reason=delivery_cancelled_before_post") == true)
        #expect(result.first?.contains("events_posted=0") == true)
        let main = replay.log.read()
        #expect(main.filter { $0 == "session discarded by user" }.count == 1)
        #expect(main.filter { $0.hasPrefix("session resolved;") }.count == 1)
        #expect(replay.requestedAttempts().count == 1)
        #expect(replay.failures().isEmpty)
        #expect(replay.waits.isEmpty)
        #expect(!attempt.gate.didCommit)
        let stop = try #require(replay.stage(attempt, "stage=stop_requested").first)
        let route = try #require(replay.stage(attempt, "stage=input_route_changed").first)
        func sequence(_ line: String) throws -> Int {
            let field = try #require(line.split(separator: " ").first { $0.hasPrefix("seq=") })
            return try #require(Int(field.dropFirst(4)))
        }
        #expect(try sequence(stop) < sequence(route))
        #expect(!replay.stage(attempt, "stage=start_failed").isEmpty)
        #expect(!replay.stage(attempt, "stage=stopped").isEmpty)
        #expect(replay.audio.isEmpty)
    }

    @Test func preparingCancelDuringBackoffCannotStartAnotherAttempt() async throws {
        let replay = PreparationReplay()
        defer { replay.finish() }
        let released = Clock()
        replay.wait = { _ in
            while released.now() == 10 {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { released.set(11) }
        replay.controller.toggle()
        let (attempt, _, _) = try await resumeAndHoldSelection(replay, index: 0)
        attempt.read.complete(matches: false)
        try await observe("No route backoff", log: replay.log) { !replay.waits.isEmpty }
        replay.controller.toggle()
        #expect(replay.controller.phase == .idle)
        released.set(11)
        try await awaitPreparationEnd(replay)
        let result = try await awaitDelivery(replay, take: attempt.takeID)
        #expect(result.count == 1 && result.first?.contains("reason=delivery_cancelled_before_post") == true)
        #expect(replay.waits == [0.05])
        #expect(replay.requestedAttempts().count == 1)
        #expect(replay.failures().count == 1)
        #expect(!attempt.gate.didCommit)
        #expect(replay.log.read().filter { $0.hasPrefix("session resolved;") }.count == 1)
    }

    @Test func livePreparationExhaustsFourRouteAttemptsAndDrainsFailureResult() async throws {
        let replay = PreparationReplay()
        defer { replay.finish() }
        replay.controller.toggle()
        for index in 0..<4 {
            let (attempt, _, _) = try await resumeAndHoldSelection(replay, index: index)
            if index == 3 { #expect(replay.controller.microphoneNotice == nil) }
            attempt.read.complete(matches: false)
        }
        try await awaitPreparationEnd(replay)
        #expect(replay.controller.microphoneNotice?.state == .buffersUnstable)
        let take = replay.attempts[0].takeID
        let result = try await awaitDelivery(replay, take: take)
        #expect(replay.controller.status == "マイクの接続切り替えが安定しませんでした")
        #expect(replay.attempts.count == 4)
        #expect(replay.attempts.allSatisfy { $0.takeID == take && !$0.gate.didCommit })
        #expect(replay.requestedAttempts().count == 4)
        #expect(replay.waits == [0.05, 0.05, 0.05])
        let failures = replay.failures()
        #expect(failures.count == 4)
        let expectedCode = (MicrophoneCapture.CaptureError.notReady(.inputRouteChanged) as NSError).code
        for (index, line) in failures.enumerated() {
            #expect(line.contains("take=\(take.uuidString) attempt=\(index + 1) category=input_route_changed code=\(expectedCode)"))
            let elapsed = try #require(Int(line.components(separatedBy: "elapsed_ms=").last ?? ""))
            #expect(abs(elapsed - (80 + index * 130)) <= 1)
        }
        #expect(result.count == 1)
        #expect(result.first?.contains("outcome=skipped reason=recognition_failed") == true)
        #expect(result.first?.contains("events_posted=0") == true)
        let cleanup = try await replay.log.dispositions(count: 4)
        #expect(cleanup.count == 4 && cleanup.allSatisfy { $0.contains("succeeded=true disposition=normal") })
    }

    @Test func routeBackoffStopsWhenLessThanFiftyMillisecondsRemain() async throws {
        let replay = PreparationReplay()
        defer { replay.finish() }
        replay.controller.toggle()
        let (attempt, _, _) = try await resumeAndHoldSelection(replay, index: 0)
        replay.rig.clock.set(19.96875)
        attempt.read.complete(matches: false)
        try await awaitPreparationEnd(replay)
        _ = try await awaitDelivery(replay, take: attempt.takeID)
        #expect(replay.requestedAttempts().count == 1)
        #expect(replay.waits.isEmpty)
        let failed = try #require(replay.failures().first)
        let expectedCode = (MicrophoneCapture.CaptureError.notReady(.inputRouteChanged) as NSError).code
        #expect(failed.contains("category=input_route_changed code=\(expectedCode) elapsed_ms=9968"))
        #expect(!attempt.gate.didCommit)
    }

    @Test(arguments: [false, true])
    func retryUsesTheShortenedOverallDeadline(atDeadline: Bool) async throws {
        let replay = PreparationReplay()
        defer { replay.finish() }
        replay.controller.toggle()
        let (first, _, _) = try await resumeAndHoldSelection(replay, index: 0)
        replay.rig.clock.set(18)
        first.read.complete(matches: false)
        let second = try await awaitEngine(replay, index: 1)
        let (device, block) = await lane {
            let device = replay.rig.devices[0]
            return (device, device.node.partialTap)
        }
        let tap = try #require(block)
        second.read.arm()
        try await observe("Readiness poll did not reach HAL", log: replay.log) { second.read.isBlocked }
        replay.rig.clock.set(19.75)
        stablePCM(replay, device: device, tap: tap)
        try await observe("Synthetic PCM not ready before overall deadline") {
            second.gate.decision(at: replay.rig.clock.now(), deadline: 20, engineRunning: true) == .ready
        }
        if atDeadline { replay.rig.clock.set(20) }
        second.read.complete(matches: true)
        try await awaitPreparationEnd(replay)
        #expect(replay.requestedAttempts().count == 2)
        #expect(replay.waits == [0.05])
        if atDeadline {
            #expect(!second.gate.didCommit)
            #expect(second.capture.totalPCMBytes == 0)
            let expectedCode = (MicrophoneCapture.CaptureError.notReady(.unstableBuffers) as NSError).code
            #expect(replay.failures().last?.contains("attempt=2 category=unstable_buffers code=\(expectedCode) elapsed_ms=10000") == true)
        } else {
            #expect(second.gate.didCommit)
            #expect(replay.controller.phase == .recording)
            #expect(replay.failures().count == 1)
            replay.controller.toggle()
        }
        _ = try await awaitDelivery(replay, take: first.takeID)
    }

    private func notifyDuringHandoff(_ attempt: PreparationAttempt, device: Device) {
        let delivered = DispatchSemaphore(value: 0)
        let notification = DispatchWorkItem {
            defer { delivered.signal() }
            let limit = DispatchTime.now() + .seconds(1)
            while !attempt.gate.didCommit && DispatchTime.now() < limit {
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard attempt.gate.didCommit else {
                Issue.record("The real gate did not commit during handoff")
                return
            }
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: device.engine)
        }
        // The notification originates outside the lifecycle lane so it can run
        // even if another capture is already queued there. Hold MainActor to
        // keep recording UI from advancing until the notification is delivered.
        DispatchQueue.global(qos: .userInitiated).async(execute: notification)
        attempt.read.complete(matches: true)
        #expect(delivered.wait(timeout: .now() + 2) == .success)
    }

    @Test(arguments: [false, true])
    func committedPreparationUsesExistingInterruptionDuringAndAfterHandoff(handoff: Bool) async throws {
        let replay = PreparationReplay()
        defer { replay.finish() }
        replay.controller.toggle()
        let attempt = try await awaitEngine(replay, index: 0)
        let (device, block) = await lane {
            let device = replay.rig.devices[0]
            return (device, device.node.partialTap)
        }
        let tap = try #require(block)
        if handoff {
            attempt.read.arm()
            try await observe("Commit poll did not reach HAL", log: replay.log) { attempt.read.isBlocked }
            stablePCM(replay, device: device, tap: tap)
            try await observe("Synthetic PCM not ready for commit") {
                attempt.gate.decision(at: replay.rig.clock.now(), deadline: 12.5, engineRunning: true) == .ready
            }
            #expect(replay.controller.phase == .preparing)
            notifyDuringHandoff(attempt, device: device)
            #expect(replay.controller.phase == .preparing)
        } else {
            stablePCM(replay, device: device, tap: tap)
            try await observe("Capture did not enter recording", log: replay.log) { replay.controller.phase == .recording }
            #expect(attempt.gate.didCommit)
            await lane {
                NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: device.engine)
            }
        }
        try await awaitPreparationEnd(replay)
        let result = try await awaitDelivery(replay, take: attempt.takeID)
        #expect(replay.controller.status == "マイク入力が変更または中断されたため録音を終了しました")
        #expect(attempt.gate.recordingWasInterrupted)
        let id = try #require(attempt.captureID)
        #expect(replay.log.read("mic").filter { $0 == "mic_interrupted capture=\(id.uuidString) category=configuration_changed" }.count == 1)
        #expect(replay.requestedAttempts().count == 1)
        #expect(replay.failures().isEmpty && replay.waits.isEmpty)
        #expect(result.count == 1 && result.first?.contains("events_posted=0") == true)
        #expect(replay.log.read().filter { $0.hasPrefix("session resolved;") }.count == 1)
        let cleanup = try await replay.log.dispositions(count: 1)
        #expect(cleanup.count == 1 && cleanup.first?.contains("succeeded=true disposition=normal") == true)
    }

    @Test func preparationDiagnosticSinksPreserveLineOrderAndMirrorDestinations() async throws {
        let log = CleanupLog()
        defer { log.clean() }
        let id = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000089"))
        let clock = Clock()
        var permissionChecks = 0
        let startup = try #require(log.startupTrace(id, true, clock: clock) { permissionChecks += 1 })
        log.session { "session discarded by user" }
        log.microphone { "mic_prepare_attempt take=\(id.uuidString) attempt=1" }
        startup.begin(.engineStart)
        clock.set(10.125)
        startup.end(.engineStart)
        try await observe("Startup trace producer did not submit both stages", log: log) { permissionChecks == 2 }

        let input = try #require(log.inputTrace(id))
        input.record(.session, stage: .requested, [.shouldPaste: .flag(true)])
        input.record(.result, stage: .result, [
            .outcome: .token(.cancelled), .reason: .reason("delivery_cancelled_before_post"),
            .eventsPosted: .flag(false), .receiptAvailable: .flag(false), .receiptMode: .token(.none),
            .exactBaselineAvailable: .flag(false), .totalMS: .integer(123),
            .plannedChunks: .integer(2), .sentChunks: .integer(0), .polls: .integer(0)
        ])
        let expectedInput = input.buffer.renderedLines()
        #expect(expectedInput.contains { $0.contains("part=2/2") })
        #expect(expectedInput.contains { $0.hasPrefix("input_summary v=2 section=result") })
        input.finish()
        input.finish()
        #expect(input.buffer.totalCount == 0)

        let prefix = "mic_start v=1 capture=\(id.uuidString) build=0 explicit=1"
        let suffix = "input_buffers=0 converted_buffers=0 discarded_startup_ms=0 zero_startup_buffers=0 input_rate=0 input_channels=0"
        let expectedMic = [
            "mic_prepare_attempt take=\(id.uuidString) attempt=1",
            "\(prefix) seq=1 t_ms=0 stage=engine_start event=begin pending=1 stage_ms=0 \(suffix)",
            "\(prefix) seq=2 t_ms=125 stage=engine_start event=end pending=0 stage_ms=125 \(suffix)"
        ]
        #expect(log.read("mic") == expectedMic)
        #expect(log.read() == ["session discarded by user"] + expectedMic + expectedInput)
    }

    @Test func preparationDiagnosticSinksRejectRevokedTokensBeforeRenderingOrWriting() async throws {
        let log = CleanupLog()
        defer { log.clean() }
        let id = UUID()
        var evaluations = 0
        func event() -> String {
            evaluations += 1
            return "diagnostic probe"
        }

        log.consent.setEnabled(false)
        #expect(log.startupTrace(id, true) == nil)
        #expect(log.inputTrace(id) == nil)
        #expect(log.evidence() == nil)
        log.session(event)
        log.microphone(event)
        #expect(evaluations == 0)
        #expect(log.read().isEmpty && log.read("mic").isEmpty)

        log.consent.setEnabled(true)
        let oldToken = try #require(log.consent.token)
        let oldEvidence = try #require(log.evidence())
        let oldInput = try #require(log.inputTrace(id))
        oldInput.record(.result, stage: .result, [.outcome: .token(.cancelled)])
        var permissionChecked = false
        let oldStartup = try #require(log.startupTrace(id, true) { permissionChecked = true })
        oldStartup.note(.stopRequested)
        let pendingEvidence = oldEvidence.enqueue("old-token microphone probe")
        log.consent.setEnabled(false)
        log.consent.setEnabled(true)
        oldInput.finish()
        oldInput.finish()
        // Prove the shared final writer checks consent before asking for the
        // lines, separately from checking finish() consumed the real buffer.
        log.writeInput({ [event()] }, token: oldToken)
        await pendingEvidence.value
        try await observe("Delayed startup trace never checked its token") { permissionChecked }
        #expect(evaluations == 0)
        #expect(oldInput.buffer.totalCount == 0)
        #expect(log.read().isEmpty && log.read("mic").isEmpty)

        log.session(event)
        log.microphone(event)
        let newInput = try #require(log.inputTrace(id))
        newInput.record(.result, stage: .result, [.outcome: .token(.skipped)])
        let expected = newInput.buffer.renderedLines()
        newInput.finish()
        #expect(evaluations == 2)
        #expect(log.read() == ["diagnostic probe", "diagnostic probe"] + expected)
        #expect(log.read("mic") == ["diagnostic probe"])
    }

    private var deferredAfterStart: String {
        "mic_cleanup_disposition generation=2 preCommitFormatException=false hadTap=true engineStarted=true"
            + " stopped=true removed=true preflightStopped=true runningAtCleanup=false succeeded=true disposition=verificationDeferred"
    }

    private func retireFirstEngine(_ replay: PreparationReplay, index: Int = 0) async throws {
        replay.controller.toggle()
        try await awaitPreparationEnd(replay)
        let failed = try #require(replay.attempts.last)
        #expect(failed.capture.recoveryDisposition == .replacementPending)
        #expect(replay.rig.lifetime.disposition == .replacementPending)
        #expect(replay.attempts.count == index + 1)
        _ = try await awaitDelivery(replay, take: failed.takeID)
    }

    private func holdVerificationSelection(_ replay: PreparationReplay, attempt: Int) async throws
        -> (PreparationAttempt, Device, AVAudioNodeTapBlock) {
        let current = try await awaitEngine(replay, index: attempt)
        let (device, block) = await lane {
            let device = replay.rig.devices[1]
            current.read.arm()
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: device.engine)
            replay.rig.clock.set(replay.rig.clock.now() + 0.08)
            return (device, device.node.partialTap)
        }
        try await observe("Selection was not read during revalidation", log: replay.log) { current.read.isBlocked }
        return (current, device, try #require(block))
    }

    private func loseSelectionDuringVerification(_ replay: PreparationReplay, attempt: Int,
                                                 fault: (Device) -> Void = { _ in }) async throws
        -> (PreparationAttempt, AVAudioNodeTapBlock) {
        let (current, device, block) = try await holdVerificationSelection(replay, attempt: attempt)
        // The lifecycle lane owns this read and is paused until complete().
        fault(device)
        current.read.complete(matches: false)
        try await observe("No selection verdict", log: replay.log) {
            replay.stage(current, "failing_component=selection").count == 1
        }
        return (current, block)
    }

    private func commitVerification(_ replay: PreparationReplay, attempt index: Int, device deviceIndex: Int,
                                    value: Float = 0) async throws -> PreparationAttempt {
        let attempt = try await awaitEngine(replay, index: index)
        let (device, block) = await lane {
            let device = replay.rig.devices[deviceIndex]
            return (device, device.node.partialTap)
        }
        let tap = try #require(block)
        let first = replay.rig.clock.now() + 0.01
        replay.rig.clock.set(first)
        device.deliver(tap, value: value)
        replay.rig.clock.set(first + 0.17)
        device.deliver(tap, value: value)
        try await awaitPreparationEnd(replay)
        #expect(replay.controller.phase == .recording)
        #expect(attempt.gate.didCommit)
        return attempt
    }

    @Test func verificationDefersAndRetriesTheSameGenerationThroughOrderedDelivery() async throws {
        let replay = PreparationReplay(rig: Rig(.none, .none))
        replay.recognitionResult = "音声入力の確認"
        defer { replay.finish() }
        replay.controller.toggle()
        let first = try await commitVerification(replay, attempt: 0, device: 0)
        replay.controller.toggle()
        _ = try await awaitDelivery(replay, take: first.takeID)
        let old = await lane { () -> AVAudioNodeTapBlock? in
            let device = replay.rig.devices[0]
            device.node.switchDeviceDuringInstall = true
            return device.node.partialTap
        }
        #expect(old == nil)
        try await retireFirstEngine(replay, index: 1)
        let retiredTap = try #require(await lane { replay.rig.devices[0].node.partialTap })

        replay.controller.toggle()
        let (failed, failedTap) = try await loseSelectionDuringVerification(replay, attempt: 2)
        try await observe("Gen2 was not re-acquired", log: replay.log) { replay.attempts.count == 4 }
        let retry = replay.attempts[3]
        #expect(retry.takeID == failed.takeID)
        #expect(retry.capture !== failed.capture)
        #expect(replay.waits == [0.05])
        #expect(failed.capture.recoveryDisposition == .verificationDeferred)
        #expect(replay.failures().last?.contains("attempt=1 category=input_route_changed") == true)
        #expect(!failed.gate.didCommit)
        _ = try await awaitEngine(replay, index: 3)
        let device = await lane {
            #expect((try? replay.rig.lifetime.acquire(for: .capture, canAcquire: true)) == nil)
            #expect((try? replay.rig.lifetime.acquire(for: .continuation, takeID: retry.takeID, canAcquire: true)) == nil)
            return replay.rig.devices[1]
        }
        device.deliver(failedTap, value: 0.9)
        device.deliver(retiredTap, value: 0.9)
        await failed.capture.cancelAndWait()
        await failed.capture.cancelAndWait()
        let committed = try await commitVerification(replay, attempt: 3, device: 1, value: 0.25)
        #expect(committed.capture.totalPCMBytes == 4096)
        #expect(committed.capture.sessionPeakAmplitude == 0.25)
        #expect(failed.capture.totalPCMBytes == 0)
        #expect(replay.rig.lifetime.disposition == .normal)
        replay.controller.toggle()
        let result = try await awaitDelivery(replay, take: retry.takeID)
        #expect(result.count == 1)
        #expect(replay.controller.history.count == 1)
        let audio = replay.audio.reduce(into: Data()) { $0.append($1) }
        #expect(audio.count == 4096)
        #expect(audio.withUnsafeBytes { $0.bindMemory(to: Int16.self).allSatisfy { $0 == 8192 } })
        let dispositions = try await replay.log.dispositions(count: 4)
        #expect(dispositions.count == 4)
        #expect(dispositions.filter { $0 == deferredAfterStart }.count == 1)
        #expect(dispositions.filter { $0.hasSuffix("disposition=replacementPending") }.count == 1)
        #expect(dispositions.last?.hasSuffix("succeeded=true disposition=normal") == true)
        await lane {
            #expect(replay.rig.factoryCalls == 2)
            #expect(replay.rig.devices[0].engine.starts == 1)
            #expect(device.engine.starts == 2)
            #expect(device.bound == [137, 137])
            #expect(retry.snapshots == [137])
        }
        replay.controller.toggle()
        let later = try await commitVerification(replay, attempt: 4, device: 1)
        replay.controller.toggle()
        _ = try await awaitDelivery(replay, take: later.takeID)
        await lane {
            #expect(replay.rig.factoryCalls == 2)
            #expect(device.engine.starts == 3)
            #expect(replay.rig.devices[0].engine.starts == 1)
        }
    }

    private func assertQuarantined(_ replay: PreparationReplay) async throws {
        replay.controller.toggle()
        try await awaitPreparationEnd(replay)
        let rejected = try #require(replay.attempts.last)
        _ = try await awaitDelivery(replay, take: rejected.takeID)
        #expect(replay.rig.lifetime.disposition == .terminal)
        #expect(replay.failures().last?.contains("category=tap_graph_quarantined") == true)
        await lane { #expect(replay.rig.factoryCalls == 2) }
    }

    @Test(arguments: [Fault.formatException, .unknownException, .topologyAfter])
    private func verificationGraphErrorsRetireEvenWithSuccessfulCleanup(_ fault: Fault) async throws {
        let replay = PreparationReplay(rig: Rig(.formatException, fault))
        defer { replay.finish() }
        if fault == .topologyAfter {
            // The installed graph becomes running and the selected ID changes.
            replay.rig.configureDevice = { device in
                guard device.fault == .topologyAfter else { return }
                device.node.afterInstall = {
                    device.engine.fixtureRunning = true
                    device.node.currentDeviceID = 173
                }
            }
        }
        try await retireFirstEngine(replay)
        replay.controller.toggle()
        try await awaitPreparationEnd(replay)
        let failed = try #require(replay.attempts.last)
        _ = try await awaitDelivery(replay, take: failed.takeID)
        let category = switch fault {
        case .formatException: "tap_format_mismatch"
        case .unknownException: "tap_unknown_exception"
        default: "tap_graph_unexpected"
        }
        #expect(replay.failures().last?.contains("category=" + category) == true)
        let cleanup = try #require((try await replay.log.dispositions(count: 2)).last)
        #expect(cleanup.hasSuffix("succeeded=true disposition=terminal"))
        #expect(replay.waits.isEmpty)
        try await assertQuarantined(replay)
    }

    private enum ProofFailure: CaseIterable {
        case stop, remove, running, unreadable

        func inject(_ device: Device) {
            switch self {
            case .stop: device.engine.raiseAfterStopping = true
            case .remove: device.node.raiseOnRemove = true
            case .running: device.engine.runningOnIndependentStopReadback = true
            case .unreadable: device.engine.raiseOnIndependentStopReadback = true
            }
        }
    }

    @Test(arguments: ProofFailure.allCases)
    private func verificationRequiresEveryIndependentCleanupProof(_ fault: ProofFailure) async throws {
        let replay = PreparationReplay(rig: Rig(.formatException, .none))
        defer { replay.finish() }
        try await retireFirstEngine(replay)
        replay.controller.toggle()
        let (failed, _) = try await loseSelectionDuringVerification(replay, attempt: 1, fault: fault.inject)
        try await awaitPreparationEnd(replay)
        _ = try await awaitDelivery(replay, take: failed.takeID)
        let cleanup = try #require((try await replay.log.dispositions(count: 2)).last)
        #expect(cleanup.contains("generation=2"))
        #expect(cleanup.contains("stopped=\(fault != .stop) removed=\(fault != .remove)"))
        let running = switch fault {
        case .running: "true"
        case .stop, .remove: "false"
        case .unreadable: "unknown"
        }
        #expect(cleanup.contains("runningAtCleanup=\(running) succeeded=false disposition=terminal"))
        #expect(replay.waits.isEmpty)
        await lane {
            #expect(replay.rig.devices[1].engine.stops == 1)
            #expect(replay.rig.devices[1].node.removes == 1)
        }
        try await assertQuarantined(replay)
    }

    @Test func failedCleanupAfterReplacementCommitStillQuarantines() async throws {
        let replay = PreparationReplay(rig: Rig(.formatException, .none))
        defer { replay.finish() }
        try await retireFirstEngine(replay)
        replay.controller.toggle()
        let attempt = try await commitVerification(replay, attempt: 1, device: 1)
        await lane { replay.rig.devices[1].node.raiseOnRemove = true }
        replay.controller.toggle()
        _ = try await awaitDelivery(replay, take: attempt.takeID)
        let cleanup = try #require((try await replay.log.dispositions(count: 2)).last)
        #expect(cleanup.contains("removed=false"))
        #expect(cleanup.hasSuffix("succeeded=false disposition=terminal"))
        try await assertQuarantined(replay)
    }

    @Test func replacementBindMismatchKeepsTheErrorAndAllowsRecapture() async throws {
        let rig = Rig(.formatException, .bind)
        let log = CleanupLog()
        defer { log.clean() }
        _ = await failure(rig.capture())
        let takeID = UUID()
        let failed = rig.capture(takeID: takeID, makeEvidence: log.evidence)
        let error = try #require(await failure(failed))
        #expect(error as? MicrophoneDevices.DeviceError == .selectionNotApplied)
        #expect(failed.recoveryDisposition == .verificationDeferred)
        #expect(VoiceController.microphoneStartFailureMessage(error, disposition: failed.recoveryDisposition)
            == MicrophoneDevices.DeviceError.selectionNotApplied.errorDescription)
        #expect(MicrophoneCapture.retryDelay(for: error, policy: .init(), attempts: 1, elapsed: 0.1,
            disposition: failed.recoveryDisposition) == 0.2)
        let line = try #require((try await log.dispositions(count: 1)).first)
        #expect(line.contains("generation=2 preCommitFormatException=false hadTap=false engineStarted=false"
            + " stopped=true removed=not_required preflightStopped=false runningAtCleanup=false"))
        #expect(line.hasSuffix("succeeded=true disposition=verificationDeferred"))
        await lane { rig.devices[1].rejectBind = false }
        let retry = rig.capture(explicitStart: false, takeID: takeID)
        let task = Task { try await retry.start(deadline: 12.5, onAudio: { _ in }) }
        defer { task.cancel() }
        try await feedStablePCM(rig, index: 1)
        try await awaitCommit(task, clock: rig.clock)
        await retry.cancelAndWait()
        await lane {
            #expect(rig.factoryCalls == 2)
            #expect(rig.devices[1].bound == [137, 137])
            #expect(rig.devices[1].engine.stops == 2)
            #expect(rig.devices[1].node.removes == 1)
        }
    }

    private enum SelectionFault: CaseIterable {
        case noSystemInput, selectedMissing, ambiguousDefault, enumerate, bind, nativeBind
        case firstGraphCheck, beforeInstall, afterInstall, afterPrepare

        var systemDefault: Bool { self == .noSystemInput || self == .ambiguousDefault }
        var terminal: Bool { self == .enumerate || self == .nativeBind }
        var hasReceipt: Bool { self == .afterInstall || self == .afterPrepare }
        var passedPreflight: Bool { self == .beforeInstall || hasReceipt }
        var graphRead: Int? {
            switch self {
            case .firstGraphCheck: 1
            case .beforeInstall: 2
            case .afterInstall: 3
            case .afterPrepare: 4
            default: nil
            }
        }

        func apply(to original: MicrophoneHardware) -> MicrophoneHardware {
            var hardware = original
            switch self {
            case .noSystemInput:
                hardware.snapshot = { .init(devices: [], defaultID: nil) }
            case .selectedMissing:
                hardware.snapshot = { .init(devices: [], defaultID: 137) }
            case .ambiguousDefault:
                // Explicit UID collisions are filtered by Snapshot. The system
                // path matches IDs and rejects two distinct UIDs for that ID.
                hardware.snapshot = {
                    .init(devices: [.init(uid: "a", name: "A", deviceID: 137),
                                    .init(uid: "b", name: "B", deviceID: 137)], defaultID: 137)
                }
            case .enumerate:
                hardware.snapshot = { throw MicrophoneDevices.DeviceError.enumerationFailed }
            case .bind:
                hardware.bind = { _, _, _ in throw MicrophoneDevices.DeviceError.selectionNotApplied }
            case .nativeBind:
                hardware.bind = { _, _, _ in throw MicrophoneDevices.DeviceError.selectionFailed(-50) }
            case .firstGraphCheck, .beforeInstall, .afterInstall, .afterPrepare:
                var reads = 0
                hardware.isStillSelected = { target, node in
                    reads += 1
                    if reads == graphRead { return false }
                    return original.isStillSelected(target, node)
                }
            }
            return hardware
        }
    }

    @Test(arguments: SelectionFault.allCases)
    private func verificationClassifiesRealSynchronousSelectionStages(_ fault: SelectionFault) async throws {
        let replay = PreparationReplay(rig: Rig(.formatException, .none))
        defer { replay.finish() }
        replay.hardwareForAttempt = { index, hardware in index == 1 ? fault.apply(to: hardware) : hardware }
        let release = Clock()
        replay.wait = { _ in
            while release.now() == 10 { try await Task.sleep(for: .milliseconds(5)) }
        }
        defer { release.set(11) }
        try await retireFirstEngine(replay)
        if fault.systemDefault { replay.selectedUID = "" }
        replay.controller.toggle()
        let cleanup = try #require((try await replay.log.dispositions(count: 2)).last)
        #expect(cleanup.contains("generation=2 preCommitFormatException=false hadTap=\(fault.hasReceipt) engineStarted=false"))
        #expect(cleanup.contains("preflightStopped=\(fault.passedPreflight)"))
        let failed = try #require(replay.attempts.last)
        if fault.terminal {
            try await awaitPreparationEnd(replay)
            #expect(failed.capture.recoveryDisposition == .terminal)
            #expect(cleanup.contains("runningAtCleanup=unknown succeeded=true disposition=terminal"))
            #expect(replay.waits.isEmpty)
        } else {
            let removed = fault.hasReceipt ? "true" : "not_required"
            #expect(cleanup.contains("stopped=true removed=\(removed)"))
            #expect(cleanup.contains("runningAtCleanup=false succeeded=true disposition=verificationDeferred"))
            if fault.graphRead != nil || fault == .bind {
                try await observe("No retry for a valid pre-start selection failure", log: replay.log) { !replay.waits.isEmpty }
                #expect(replay.waits == [fault == .bind ? 0.2 : 0.05])
                replay.controller.toggle()
                release.set(11)
                try await awaitPreparationEnd(replay)
            } else {
                try await awaitPreparationEnd(replay)
                let expected: MicrophoneSelectionError = switch fault {
                case .noSystemInput: .noSystemInput
                case .ambiguousDefault: .ambiguousDevice
                default: .selectedDeviceMissing
                }
                _ = try await awaitDelivery(replay, take: failed.takeID)
                // B89's selection errors use the existing generic display,
                // even though they have distinct original NSError codes.
                #expect(replay.controller.status == "マイクの開始に失敗しました。時間をおいてもう一度お試しください。")
                let code = (expected as NSError).code
                #expect(replay.stage(failed, "stage=start_failed").contains {
                    $0.split(separator: " ").contains("code=\(code)")
                })
                #expect(replay.waits.isEmpty)
            }
            #expect(failed.capture.recoveryDisposition == .verificationDeferred)
        }
        _ = try await awaitDelivery(replay, take: failed.takeID)
        #expect(replay.attempts.count == 2)
        await lane {
            #expect(replay.rig.factoryCalls == 2)
            #expect(replay.rig.devices[1].node.installs == (fault.hasReceipt ? 1 : 0))
            #expect(replay.rig.devices[1].node.removes == (fault.hasReceipt ? 1 : 0))
            #expect(replay.rig.devices[1].engine.starts == 0)
        }
    }

    @Test func verificationReadinessLossLeavesDeferralForTheNextExplicitTakeAfterBudgetExhaustion() async throws {
        let replay = PreparationReplay(rig: Rig(.formatException, .none))
        defer { replay.finish() }
        try await retireFirstEngine(replay)
        replay.controller.toggle()
        for index in 1...4 {
            let attempt = try await awaitEngine(replay, index: index)
            attempt.read.arm()
            try await observe("Readiness did not poll selection", log: replay.log) { attempt.read.isBlocked }
            attempt.read.complete(matches: false)
        }
        try await awaitPreparationEnd(replay)
        let timedOut = try #require(replay.attempts.last)
        _ = try await awaitDelivery(replay, take: timedOut.takeID)
        #expect(replay.controller.status == "マイクの接続切り替えが安定しませんでした")
        #expect(replay.waits == [0.05, 0.05, 0.05])
        #expect(replay.attempts.count == 5)
        #expect(replay.attempts.dropFirst().allSatisfy { $0.capture.recoveryDisposition == .verificationDeferred })
        let cleanup = try await replay.log.dispositions(count: 5)
        #expect(cleanup.filter { $0 == deferredAfterStart }.count == 4)
        #expect(replay.rig.lifetime.disposition == .verificationDeferred)

        let warmer = replay.rig.warm()
        warmer.resume(enabled: true, selectedUID: "explicit", takeActive: false, reason: "test")
        let otherTake = UUID()
        await lane {
            #expect(replay.rig.lifetime.acquire() == nil)
            #expect((try? replay.rig.lifetime.acquire(for: .continuation, takeID: otherTake, canAcquire: true)) == nil)
            #expect(replay.rig.lifetime.disposition == .verificationDeferred)
            #expect(replay.rig.devices[1].engine.starts == 4)
        }
        warmer.suspend()
        let cancelled = MicrophoneStartupGate(configuring: true)
        cancelled.stop()
        #expect(await failure(replay.rig.capture(gate: cancelled)) is CancellationError)
        #expect(await failure(replay.rig.capture(), deadline: replay.rig.clock.now()) != nil)
        #expect(replay.rig.lifetime.disposition == .verificationDeferred)
        #expect(try await replay.log.dispositions(count: 5) == cleanup)

        replay.controller.toggle()
        let later = try await commitVerification(replay, attempt: 5, device: 1)
        #expect(later.takeID != timedOut.takeID)
        replay.controller.toggle()
        _ = try await awaitDelivery(replay, take: later.takeID)
        await lane {
            #expect(replay.rig.factoryCalls == 2)
            #expect(replay.rig.devices[1].engine.starts == 5)
        }
    }

    private enum VerificationVeto: CaseIterable { case cancelled, deadline, stoppedEngine }

    @Test(arguments: VerificationVeto.allCases)
    private func revalidationCannotDeferAnUnadoptedOrUnsafeSelectionFailure(_ veto: VerificationVeto) async throws {
        let replay = PreparationReplay(rig: Rig(.formatException, .none))
        defer { replay.finish() }
        try await retireFirstEngine(replay)
        replay.controller.toggle()
        let (attempt, device, _) = try await holdVerificationSelection(replay, attempt: 1)
        switch veto {
        case .cancelled: replay.controller.toggle()
        case .deadline: replay.rig.clock.set(replay.rig.clock.now() + 2.5)
        case .stoppedEngine: device.engine.fixtureRunning = false
        }
        attempt.read.complete(matches: false)
        try await awaitPreparationEnd(replay)
        _ = try await awaitDelivery(replay, take: attempt.takeID)
        let cleanup = try #require((try await replay.log.dispositions(count: 2)).last)
        #expect(cleanup.contains("runningAtCleanup=unknown succeeded=true disposition=terminal"))
        #expect(attempt.capture.recoveryDisposition == .terminal)
        if veto != .cancelled {
            #expect(replay.failures().last?.contains("category=input_route_changed") == true)
        }
        #expect(replay.attempts.count == 2)
        #expect(replay.waits.isEmpty)
        try await assertQuarantined(replay)
    }

    private func expectationFlag() -> Clock {
        let clock = Clock()
        clock.set(0)
        return clock
    }
}
#endif
