#if os(macOS)
import Foundation
import AVFoundation
import KoeBridgeCore

/// Engine lifecycle, conversion and inference have separate serial lanes.
/// The real-time tap only copies; health counters use healthLock.
final class MicrophoneCapture: @unchecked Sendable {
    private static let lifecycleQueue = DispatchQueue(label: "dev.koebridge.microphone-lifecycle", qos: .userInteractive)
    private let processingQueue = DispatchQueue(label: "dev.koebridge.pcm-conversion", qos: .userInitiated)
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    // Capture objects are per attempt; the audio engine is NOT. Both supplied
    // Build 34 crashes occurred while AVAudioEngine deallocated concurrently
    // with its AVAudioIOUnit property listener. Keep a single stopped engine
    // alive across attempts instead of trying to guess a safe deallocation delay.
    private static let engineLifetime = MicrophoneEngineLifetime { AVAudioEngine() }
    // Warmer operations share the capture lifecycle lane and retained owner.
    static var warmLifecycleQueue: DispatchQueue { lifecycleQueue }
    static var warmEngineLifetime: MicrophoneEngineLifetime<AVAudioEngine> { engineLifetime }
    private var engineLease: MicrophoneEngineLifetime<AVAudioEngine>.Lease? // lifecycleQueue only
    private var engine: AVAudioEngine? { engineLease?.resource }
    private let selectedInputUID: String
    private var selectedTarget: MicrophoneSelectionTarget? // lifecycleQueue only
    init(selectedInputUID: String = "") { self.selectedInputUID = selectedInputUID }
    private let startupGate = MicrophoneStartupGate(configuring: true)
    private let settlingPolicy = MicrophoneSettlingPolicy()
    private var revalidationWorkItem: DispatchWorkItem? // lifecycleQueue only
    // Assigned before the observer is installed; immutable for the attempt.
    private var attemptDeadline: TimeInterval = 0
    private var startupBufferEpoch: UInt64 = 1 // processingQueue only
    private let stopLatch = MicrophoneStopLatch()
    private var tapInstalled = false // lifecycleQueue only
    private var tapPlan: MicrophoneTapFormatPlan? // lifecycleQueue only
    private var teardownStarted = false // lifecycleQueue only
    private var startupBuffers: [AVAudioPCMBuffer] = [] // processingQueue only
    private var startupFrames = 0 // processingQueue only; capped at four seconds
    @MainActor private var startRequested = false
    private var carry = Data()
    private var onAudio: ((Data) -> Void)?
    private let chunkBytes = 1_600
    private var alive = false
    private let workSlots = DispatchSemaphore(value: 16)
    private let healthLock = NSLock()
    private var droppedBuffers = 0
    private var conversionErrors = 0
    private var capturedPCMBytes = 0
    private var peakAmplitude: Float = 0
    private var activityMeter = AudioActivityMeter()
    private var cachedActivity = AudioActivityMeter().evidence
    private var admission = SpeechAdmissionBuffer() // processingQueue only
    private let speechDetector = NativeSpeechDetector()
    private let diagnosticID = UUID()
    @MainActor private var speechTrace: InputDiagnosticTrace?
    // Assigned once before dispatching startBlocking, then read-only across queues.
    private var startupDiagnostics: MicrophonePreparationDiagnostics?

    struct StartTimings {
        let microphonePreparation: TimeInterval
        let engineStart: TimeInterval
        let total: TimeInterval
        var firstBufferDelay: TimeInterval = 0
        var sampleRate: Double = 0
        var channels: UInt32 = 0
    }
    private(set) var startTimings: StartTimings?
    // Written once per attempt on lifecycleQueue; read by the controller only
    // after start() has returned or thrown and teardown has completed.
    private(set) var routeSnapshot: MicrophoneRouteSnapshot?
    struct InputFormatSnapshot: Sendable {
        let hardwareRate: Double
        let hardwareChannels: UInt32
        let nodeRate: Double
        let nodeChannels: UInt32
        var tapRate: Double = 0
        var tapChannels: UInt32 = 0
        var appliedRate: Double = 0
        var appliedChannels: UInt32 = 0
        var diagnosticFields: String {
            "hardware_rate=\(hardwareRate) hardware_channels=\(hardwareChannels) node_rate=\(nodeRate) node_channels=\(nodeChannels) tap_rate=\(tapRate) tap_channels=\(tapChannels) applied_rate=\(appliedRate) applied_channels=\(appliedChannels)"
        }
    }
    private(set) var formatSnapshot: InputFormatSnapshot?
    var sessionPeakAmplitude: Float {
        healthLock.lock(); defer { healthLock.unlock() }
        return peakAmplitude
    }
    var activityEvidence: AudioActivityEvidence {
        healthLock.lock()
        let energy = cachedActivity
        healthLock.unlock()
        return energy.withSpeechVerification(speechDetector.evidence)
    }
    /// Captured duration is independent of the leading-silence admission buffer.
    /// Provider usage continues to count only bytes actually sent by that provider.
    var totalPCMBytes: Int {
        healthLock.lock(); defer { healthLock.unlock() }
        return capturedPCMBytes
    }
    private var configurationObserver: NSObjectProtocol?
    private var healthTimer: DispatchSourceTimer? // lifecycleQueue only
    var lostBufferCount: Int {
        healthLock.lock()
        let losses = droppedBuffers + conversionErrors
        healthLock.unlock()
        // The UI may already be idle when a queued interruption arrives.
        // Never turn that race into permission to submit truncated audio.
        return losses + (startupGate.recordingWasInterrupted ? 1 : 0)
    }
    private func noteBufferLoss(conversionError: Bool = false) {
        healthLock.lock()
        if conversionError { conversionErrors += 1 } else { droppedBuffers += 1 }
        healthLock.unlock()
    }

    @MainActor
    func start(timeout: TimeInterval = 2.5,
               onAudio: @escaping (Data) -> Void,
               onDeviceChanged: @escaping () -> Void = {}) async throws {
        guard !startRequested else { throw CaptureError.alreadyStarted }
        startRequested = true
        let beganAt = ProcessInfo.processInfo.systemUptime
        let deadline = beganAt + max(0, timeout)
        attemptDeadline = deadline
        startupDiagnostics = DiagnosticLog.microphoneTrace(captureID: diagnosticID,
                                                           explicitSelection: !selectedInputUID.isEmpty)
        startupDiagnostics?.begin(.lifecycle)
        // This task runs independently of a blocked native audio call. It only
        // snapshots in-memory counters: no extra HAL/device probes or recovery.
        let diagnosticWatch: Task<Void, Never>?
        if let trace = startupDiagnostics {
            diagnosticWatch = Task { @MainActor [weak trace] in
                for _ in 0..<45 {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let trace else { return }
                    trace.poll()
                }
            }
        } else { diagnosticWatch = nil }
        defer { diagnosticWatch?.cancel() }
        speechTrace = DiagnosticLog.inputTrace(takeID: diagnosticID)
        if speechTrace?.isCollecting == true {
            DiagnosticLog.recordMicrophoneEvidence("speech_classifier_started capture=\(diagnosticID.uuidString) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
        }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard timeout.isFinite, timeout > 0, !startupGate.isStopped else {
                    throw CancellationError()
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Self.lifecycleQueue.async { [self] in
                        do {
                            try startBlocking(onAudio: onAudio, onDeviceChanged: onDeviceChanged)
                            continuation.resume(returning: ())
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                while true {
                    try Task.checkCancellation()
                    switch await checkReadiness(deadline: deadline) {
                    case .ready:
                        updateSettlingDiagnostics()
                        startupDiagnostics?.end(.awaitPCM)
                        startupDiagnostics?.note(.ready)
                        if let t = startTimings {
                            startTimings = StartTimings(
                                microphonePreparation: t.microphonePreparation, engineStart: t.engineStart,
                                total: ProcessInfo.processInfo.systemUptime - beganAt,
                                firstBufferDelay: max(0, (startupGate.firstBufferTime ?? beganAt) - beganAt),
                                sampleRate: t.sampleRate, channels: t.channels)
                        }
                        return
                    case .stopped: throw CancellationError()
                    case .failed(let reason): throw CaptureError.notReady(reason)
                    case .waiting: try await Task.sleep(for: .milliseconds(40))
                    }
                }
            } onCancel: { [self] in
                // Immediate flag prevents a queued engine start from resurrecting
                // a cancelled take. Teardown itself stays on the lifecycle lane.
                stop { _ in }
            }
        } catch {
            startupDiagnostics?.note(.startFailed, code: (error as NSError).code)
            if let captureError = error as? CaptureError, case .notReady(let failure) = captureError {
                if let stage = MicrophonePreparationDiagnostics.Stage(rawValue: failure.rawValue) {
                    startupDiagnostics?.note(stage)
                }
            }
            await cancelAndWait()
            speechTrace?.finish()
            throw error
        }
    }

    private func checkReadiness(deadline: TimeInterval) async -> MicrophoneStartupGate.Decision {
        await withCheckedContinuation { continuation in
            Self.lifecycleQueue.async { [self] in
                let running = engine?.isRunning == true
                // Settling is notification-driven only. Polls neither probe the HAL
                // during debounce nor turn a poll-detected failure into revalidation.
                switch startupGate.currentPhase {
                case .failed, .stopped, .revalidating, .configuring:
                    continuation.resume(returning: startupGate.decision(
                        at: ProcessInfo.processInfo.systemUptime, deadline: deadline, engineRunning: running))
                    return
                default: break
                }
                healthLock.lock()
                let losses = droppedBuffers, errors = conversionErrors
                healthLock.unlock()
                if errors > 0 { startupGate.invalidate(.conversionFailed) }
                else if losses > 0 { startupGate.invalidate(.bufferDropped) }
                if case .failed = startupGate.currentPhase {
                    continuation.resume(returning: startupGate.decision(
                        at: ProcessInfo.processInfo.systemUptime, deadline: deadline, engineRunning: running))
                    return
                }
                if let engine, let selectedTarget,
                   !MicrophoneDevices.isStillSelected(selectedTarget, node: engine.inputNode) {
                    startupDiagnostics?.note(.inputRouteChanged)
                    startupGate.invalidate(.inputRouteChanged)
                }
                // A notification may also have blocked commit while selection was read.
                switch startupGate.currentPhase {
                case .failed, .stopped, .revalidating, .configuring:
                    continuation.resume(returning: startupGate.decision(
                        at: ProcessInfo.processInfo.systemUptime, deadline: deadline, engineRunning: running))
                    return
                default: break
                }
                let inspectedEpoch = startupGate.currentEpoch
                if let engine, let tapPlan {
                    do { try verifyTapFormat(engine.inputNode, plan: tapPlan) }
                    catch {
                        startupDiagnostics?.note(.formatChanged)
                        startupGate.invalidate(.formatChanged)
                    }
                }
                var decision = startupGate.decision(
                    at: ProcessInfo.processInfo.systemUptime, deadline: deadline, engineRunning: running)
                if decision == .ready {
                    let committed = processingQueue.sync { [self] in
                        guard startupBufferEpoch == inspectedEpoch, startupGate.commit(at: ProcessInfo.processInfo.systemUptime,
                                                 deadline: deadline, engineRunning: running,
                                                 expectedEpoch: inspectedEpoch) else { return false }
                        let pending = startupBuffers
                        startupBuffers.removeAll(keepingCapacity: false)
                        startupFrames = 0
                        // Preserve the start of speech without exposing PCM from
                        // a failed preparation to SoundAnalysis or either ASR.
                        for buffer in pending { consume(buffer) }
                        return true
                    }
                    if !committed {
                        decision = startupGate.decision(at: ProcessInfo.processInfo.systemUptime,
                                                         deadline: deadline, engineRunning: running)
                    }
                }
                continuation.resume(returning: decision)
            }
        }
    }

    /// Wait for failed-attempt teardown before creating another engine.
    func cancelAndWait() async {
        startupDiagnostics?.note(.stopRequested)
        startupGate.stop()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.lifecycleQueue.async { [self] in
                stopBlocking(flushPendingAudio: false) { _ in
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func invalidateStartup(_ reason: MicrophoneStartupGate.Failure,
                                   onDeviceChanged: @escaping () -> Void) {
        if reason == .configurationChanged || reason == .inputRouteChanged {
            handleConfigurationChange(reason: reason, onDeviceChanged: onDeviceChanged)
            return
        }
        if let stage = MicrophonePreparationDiagnostics.Stage(rawValue: reason.rawValue) {
            startupDiagnostics?.note(stage)
        }
        guard startupGate.invalidate(reason) else { return }
        notifyInterruption(reason, onDeviceChanged: onDeviceChanged)
    }

    private func notifyInterruption(_ reason: MicrophoneStartupGate.Failure,
                                    onDeviceChanged: @escaping () -> Void) {
        // Never stop/deallocate an engine in its notification callback.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.startupGate.isStopped else { return }
            DiagnosticLog.recordMicrophoneEvidence("mic_interrupted capture=\(self.diagnosticID.uuidString) category=\(reason.rawValue)")
            onDeviceChanged()
        }
    }

    private func updateSettlingDiagnostics() {
        startupDiagnostics?.settling(startupGate.settlingSnapshot(at: ProcessInfo.processInfo.systemUptime))
    }

    private func handleConfigurationChange(reason: MicrophoneStartupGate.Failure,
                                           onDeviceChanged: @escaping () -> Void) {
        let outcome = startupGate.handleConfigurationChange(
            at: ProcessInfo.processInfo.systemUptime, deadline: attemptDeadline, reason: reason)
        switch outcome {
        case .ignored: return
        case .committedInterrupted:
            if let stage = MicrophonePreparationDiagnostics.Stage(rawValue: reason.rawValue) {
                startupDiagnostics?.note(stage)
            }
            notifyInterruption(reason, onDeviceChanged: onDeviceChanged)
        case .budgetExhausted:
            startupDiagnostics?.noteChurn(epoch: startupGate.currentEpoch)
            updateSettlingDiagnostics()
            startupDiagnostics?.note(.settlingBudget)
        case .revalidate(let epoch, _):
            startupDiagnostics?.noteChurn(epoch: epoch)
            Self.lifecycleQueue.async { [weak self] in
                self?.scheduleRevalidation(after: self?.settlingPolicy.debounceDuration ?? 0)
            }
        }
    }

    private func scheduleRevalidation(after delay: TimeInterval) {
        guard !teardownStarted, revalidationWorkItem == nil,
              case .revalidating = startupGate.currentPhase else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.revalidationWorkItem = nil
            self.runRevalidationIfReady()
        }
        revalidationWorkItem = work
        Self.lifecycleQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runRevalidationIfReady() {
        guard !teardownStarted else { return }
        let epoch: UInt64
        switch startupGate.revalidationReadiness(at: ProcessInfo.processInfo.systemUptime, deadline: attemptDeadline) {
        case .notRevalidating: return
        case .budgetExhausted:
            updateSettlingDiagnostics()
            startupDiagnostics?.note(.settlingBudget)
            return
        case .debouncePending(let remaining):
            scheduleRevalidation(after: remaining)
            return
        case .readyToRevalidate(let readyEpoch): epoch = readyEpoch
        }
        startupDiagnostics?.begin(.revalidating)
        let engine = self.engine
        let node = engine?.inputNode
        let selected = selectedTarget.map { target in
            node.map { MicrophoneDevices.isStillSelected(target, node: $0) } ?? false
        } ?? false
        let hardware = node?.inputFormat(forBus: 0)
        let applied = node?.outputFormat(forBus: 0)
        healthLock.lock()
        let losses = droppedBuffers, errors = conversionErrors
        healthLock.unlock()
        let running = engine?.isRunning == true
        let input = MicrophoneRevalidationInput(
            hasEngineAndTarget: engineLease != nil && selectedTarget != nil,
            deviceStillSelected: selected, engineRunning: running, tapInstalled: tapInstalled,
            outputConnectionsEmpty: node.map { engine?.outputConnectionPoints(for: $0, outputBus: 0).isEmpty == true } ?? false,
            hardwareFormatValid: hardware.map { MicrophoneTapFormatPlan(hardwareSampleRate: $0.sampleRate, hardwareChannels: $0.channelCount) != nil } ?? false,
            hardwareMatchesPlan: hardware.map { tapPlan?.matches(sampleRate: $0.sampleRate, channels: $0.channelCount) == true } ?? false,
            appliedMatchesPlan: applied.map { tapPlan?.matches(sampleRate: $0.sampleRate, channels: $0.channelCount) == true } ?? false,
            droppedBuffers: losses, conversionErrors: errors)
        let verdict = MicrophoneRevalidationPolicy.evaluate(input)
        // Native reads can race a newer notification or cancellation. Never apply
        // an old checklist (including its failure) to a different epoch.
        guard case .revalidating(let current, _, _) = startupGate.currentPhase, current == epoch else {
            startupDiagnostics?.end(.revalidating)
            scheduleRevalidation(after: settlingPolicy.debounceDuration)
            return
        }
        switch verdict {
        case .fail(let reason, _):
            startupGate.invalidate(reason, expectedEpoch: epoch)
        case .resume:
            let resumed = processingQueue.sync { [self] in
                discardStartupBuffers()
                // Retain the converter but discard any internally buffered old PCM.
                converter?.reset()
                startupBufferEpoch = epoch
                return startupGate.resumeStabilising(expectedEpoch: epoch, at: ProcessInfo.processInfo.systemUptime)
            }
            if !resumed {
                startupDiagnostics?.end(.revalidating)
                updateSettlingDiagnostics()
                if case .failed = startupGate.currentPhase { startupDiagnostics?.note(.settlingBudget) }
                scheduleRevalidation(after: settlingPolicy.debounceDuration)
                return
            }
        }
        updateSettlingDiagnostics()
        startupDiagnostics?.revalidation(verdict, engineRunning: running)
        if case .resume = verdict { startupDiagnostics?.begin(.awaitPCM) }
    }

    /// Processing lane only; all epochs and failed attempts discard their PCM.
    private func discardStartupBuffers() {
        startupDiagnostics?.discardStartup(duration: Double(startupFrames) / output.sampleRate)
        startupBuffers.removeAll(keepingCapacity: false)
        startupFrames = 0
    }

    private func startBlocking(onAudio: @escaping (Data) -> Void,
                               onDeviceChanged: @escaping () -> Void) throws {
        guard !startupGate.isStopped, !teardownStarted else { throw CancellationError() }
        guard engine == nil else { throw CaptureError.alreadyStarted }
        let beganAt = Date()
        startupDiagnostics?.end(.lifecycle)
        startupDiagnostics?.begin(.deviceList)
        let snapshot = MicrophoneDevices.snapshot()
        startupDiagnostics?.end(.deviceList, code: snapshot.devices.count)
        startupDiagnostics?.begin(.selection)
        let target = try MicrophoneSelectionPolicy.resolve(uid: selectedInputUID,
            devices: snapshot.devices, systemDefaultID: snapshot.defaultID)
        selectedTarget = target
        startupDiagnostics?.end(.selection)
        startupDiagnostics?.begin(.routeSnapshot)
        routeSnapshot = MicrophoneRouteSnapshot.current(inputDeviceID: target.deviceID)
        startupDiagnostics?.end(.routeSnapshot)
        startupDiagnostics?.begin(.engineLease)
        guard let lease = Self.engineLifetime.acquire() else { throw CaptureError.engineInUse }
        engineLease = lease
        let engine = lease.resource
        startupDiagnostics?.end(.engineLease)
        startupDiagnostics?.begin(.inputNode)
        let node = engine.inputNode
        startupDiagnostics?.end(.inputNode)
        try MicrophoneDevices.bind(target, to: node, diagnostics: startupDiagnostics)
        // Device binding itself may emit a synchronous configuration change.
        // Subscribe after that deliberate change, before tap/engine startup.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.invalidateStartup(.configurationChanged, onDeviceChanged: onDeviceChanged)
        }
        startupDiagnostics?.begin(.formats)
        let hardware = node.inputFormat(forBus: 0)
        let previousClientFormat = node.outputFormat(forBus: 0)
        formatSnapshot = InputFormatSnapshot(hardwareRate: hardware.sampleRate,
                                            hardwareChannels: hardware.channelCount,
                                            nodeRate: previousClientFormat.sampleRate,
                                            nodeChannels: previousClientFormat.channelCount)
        // A retained engine keeps the OLD client format after a device change.
        // Build 36 reproduced hardware 16 kHz/mono versus client 44.1 kHz/stereo.
        // A nil tap format leaves that mismatch intact; retries cannot repair it.
        guard let plan = MicrophoneTapFormatPlan(hardwareSampleRate: hardware.sampleRate,
                                                hardwareChannels: hardware.channelCount),
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: plan.sampleRate, channels: plan.channelCount,
                                        interleaved: false) else { throw CaptureError.noInput }
        startupDiagnostics?.format(sampleRate: input.sampleRate, channels: input.channelCount)
        startupDiagnostics?.end(.formats)
        startupDiagnostics?.begin(.converter)
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw CaptureError.noInput
        }
        formatSnapshot?.tapRate = input.sampleRate
        formatSnapshot?.tapChannels = input.channelCount
        startupDiagnostics?.end(.converter)
        guard !startupGate.isStopped else { throw CancellationError() }
        processingQueue.sync {
            self.onAudio = onAudio; self.converter = converter; self.alive = true
        }
        // This engine is exclusively leased and owns a tap-only input graph.
        // A non-nil format is valid only on an unconnected output bus. Refuse
        // an unexpected graph rather than modifying another connection.
        guard !engine.isRunning,
              engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty else {
            throw CaptureError.notReady(.formatChanged)
        }
        let beforeTap = node.inputFormat(forBus: 0)
        guard plan.matches(sampleRate: beforeTap.sampleRate, channels: beforeTap.channelCount) else {
            throw CaptureError.notReady(.formatChanged)
        }
        guard !startupGate.isStopped else { throw CancellationError() }
        // Explicitly reconfigure the input node output to CURRENT hardware.
        // The tap and AVAudioConverter must use this SAME format.
        startupDiagnostics?.begin(.tapInstall)
        let tapGeneration = startupGate.currentTapGeneration
        node.installTap(onBus: 0, bufferSize: 1024, format: input) { [weak self] buffer, _ in
            guard let self, buffer.frameLength > 0,
                  let token = self.startupGate.captureTokenForTap(tapGeneration: tapGeneration) else { return }
            // Timestamp arrival, not eventual conversion. Queued old buffers
            // must not make a stalled microphone appear live/ready.
            let arrivedAt = ProcessInfo.processInfo.systemUptime
            self.startupDiagnostics?.observeInput(frames: Int(buffer.frameLength), at: arrivedAt)
            guard self.workSlots.wait(timeout: .now()) == .success else { self.noteBufferLoss(); return }
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                self.noteBufferLoss(); self.workSlots.signal(); return
            }
            copy.frameLength = buffer.frameLength
            let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for i in 0..<min(src.count, dst.count) {
                guard let from = src[i].mData, let to = dst[i].mData else { continue }
                memcpy(to, from, Int(src[i].mDataByteSize))
                dst[i].mDataByteSize = src[i].mDataByteSize
            }
            self.processingQueue.async { [weak self, slots = self.workSlots] in
                defer { slots.signal() }
                self?.convert(copy, arrivedAt: arrivedAt, token: token, onDeviceChanged: onDeviceChanged)
            }
        }
        tapInstalled = true
        tapPlan = plan
        startupDiagnostics?.end(.tapInstall)
        do {
            try verifyTapFormat(node, plan: plan)
            startupDiagnostics?.begin(.enginePrepare)
            engine.prepare()
            startupDiagnostics?.end(.enginePrepare)
            try verifyTapFormat(node, plan: plan)
            guard !startupGate.isStopped else { throw CancellationError() }
            let startAt = Date()
            startupDiagnostics?.begin(.engineStart)
            try engine.start()
            startupDiagnostics?.end(.engineStart)
            let phase = startupGate.finishConfiguring(at: ProcessInfo.processInfo.systemUptime)
            if case .revalidating = phase { scheduleRevalidation(after: settlingPolicy.debounceDuration) }
            else { startupDiagnostics?.begin(.awaitPCM) }
            let timer = DispatchSource.makeTimerSource(queue: Self.lifecycleQueue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(30))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if let failure = self.startupGate.recordingFailure(
                    at: ProcessInfo.processInfo.systemUptime,
                    engineRunning: self.engine?.isRunning == true) {
                    self.invalidateStartup(failure, onDeviceChanged: onDeviceChanged)
                } else if self.startupGate.didCommit,
                          let engine = self.engine, let target = self.selectedTarget,
                          !MicrophoneDevices.isStillSelected(target, node: engine.inputNode) {
                    self.invalidateStartup(.inputRouteChanged, onDeviceChanged: onDeviceChanged)
                }
            }
            healthTimer = timer
            timer.resume()
            let completedAt = Date()
            startTimings = StartTimings(microphonePreparation: startAt.timeIntervalSince(beganAt),
                                       engineStart: completedAt.timeIntervalSince(startAt),
                                       total: completedAt.timeIntervalSince(beganAt),
                                       sampleRate: input.sampleRate, channels: input.channelCount)
        } catch {
            startupDiagnostics?.note(.startFailed, code: (error as NSError).code)
            stopBlocking(flushPendingAudio: false)
            throw error
        }
    }

    /// Read back both scopes; never promote a successful API call alone to a
    /// valid stream. This does not change the system device or hardware rate.
    private func verifyTapFormat(_ node: AVAudioInputNode,
                                 plan: MicrophoneTapFormatPlan) throws {
        let hardware = node.inputFormat(forBus: 0)
        let applied = node.outputFormat(forBus: 0)
        formatSnapshot?.appliedRate = applied.sampleRate
        formatSnapshot?.appliedChannels = applied.channelCount
        guard plan.matches(sampleRate: hardware.sampleRate, channels: hardware.channelCount),
              plan.matches(sampleRate: applied.sampleRate, channels: applied.channelCount) else {
            throw CaptureError.notReady(.formatChanged)
        }
    }

    private func convert(_ incoming: AVAudioPCMBuffer, arrivedAt: TimeInterval,
                         token: MicrophoneStartupGate.TapCaptureToken,
                         onDeviceChanged: @escaping () -> Void) {
        guard alive, startupGate.accepts(token), let converter else { return }
        guard incoming.frameLength > 0 else { return }
        guard incoming.format.sampleRate.isFinite, incoming.format.sampleRate > 0,
              incoming.format.channelCount > 0, incoming.format.isEqual(converter.inputFormat) else {
            invalidateStartup(.formatChanged, onDeviceChanged: onDeviceChanged)
            return
        }
        let capacity = AVAudioFrameCount(ceil(Double(incoming.frameLength) * 16_000.0 / incoming.format.sampleRate)) + 128
        guard let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            noteBufferLoss(conversionError: true)
            invalidateStartup(.conversionFailed, onDeviceChanged: onDeviceChanged)
            return
        }
        var didProvide = false
        var conversionError: NSError?
        _ = converter.convert(to: target, error: &conversionError) { _, status in
            if didProvide { status.pointee = .noDataNow; return nil }
            didProvide = true; status.pointee = .haveData
            return incoming
        }
        guard conversionError == nil else {
            noteBufferLoss(conversionError: true)
            invalidateStartup(.conversionFailed, onDeviceChanged: onDeviceChanged)
            return
        }
        guard target.frameLength > 0 else { return }
        startupDiagnostics?.observeConverted(frames: Int(target.frameLength))
        guard target.floatChannelData?.pointee != nil else {
            noteBufferLoss(conversionError: true)
            invalidateStartup(.conversionFailed, onDeviceChanged: onDeviceChanged)
            return
        }
        switch startupGate.observeConvertedBuffer(frames: Int(target.frameLength),
                                                  at: arrivedAt, epoch: token.stabilityEpoch) {
        case .dropped: return
        case .committed: consume(target)
        case .buffered:
            // Diagnostics only, on the conversion lane; exact digital zero is
            // measured without changing readiness or speech admission.
            if let startupDiagnostics, let samples = target.floatChannelData?.pointee {
                var isZero = true
                for i in 0..<Int(target.frameLength) {
                    if samples[i] != 0 { isZero = false; break }
                }
                startupDiagnostics.observeStartupBuffer(isExactlyZero: isZero)
            }
            // Four seconds of 16 kHz mono Float32, at most 256 KB per attempt.
            // The ordinary attempt deadline is 2.5 s, so this is a safety cap.
            guard startupFrames + Int(target.frameLength) <= 64_000 else {
                invalidateStartup(.startupBufferOverflow, onDeviceChanged: onDeviceChanged)
                return
            }
            startupBuffers.append(target)
            startupFrames += Int(target.frameLength)
        }
    }

    private func consume(_ target: AVAudioPCMBuffer) {
        guard startupGate.acceptsBuffers, let floats = target.floatChannelData?.pointee else { return }
        let n = Int(target.frameLength)
        activityMeter.observe(UnsafeBufferPointer(start: floats, count: n))
        let energy = activityMeter.evidence
        var pcm = Data(count: n * 2)
        var peak: Float = 0
        pcm.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<n {
                let finite = floats[i].isFinite ? floats[i] : 0
                peak = max(peak, abs(finite))
                let clipped = max(-1.0, min(1.0, finite))
                floats[i] = clipped
                let value = Int16((clipped * 32767).rounded()).littleEndian
                base[i * 2] = UInt8(truncatingIfNeeded: value)
                base[i * 2 + 1] = UInt8(truncatingIfNeeded: Int(value) >> 8)
            }
        }
        healthLock.lock()
        peakAmplitude = max(peakAmplitude, peak)
        cachedActivity = energy
        capturedPCMBytes += pcm.count
        healthLock.unlock()
        speechDetector.append(target) // target is independently owned, never recycled
        carry.append(pcm)
        while carry.count >= chunkBytes {
            let data = carry.subdata(in: 0..<chunkBytes)
            carry.removeSubrange(0..<chunkBytes)
            admit(data)
        }
    }

    private func admit(_ pcm: Data) {
        let wasOverflowed = admission.overflowed
        let wasOpened = admission.opened
        if let admitted = admission.append(pcm, proof: speechDetector.evidence) {
            if !wasOpened { recordAdmissionOpened() }
            emit(admitted)
        }
        if admission.overflowed && !wasOverflowed { noteBufferLoss(conversionError: true) }
    }
    private func recordAdmissionOpened() {
        guard let geometry = admission.openGeometry else { return }
        let firstSpeechMS = geometry.firstSpeechStart.map { Int($0 * 1_000) } ?? -1
        let message = "admission_opened capture=\(diagnosticID.uuidString) first_speech_ms=\(firstSpeechMS) released_from_ms=\(Int(geometry.releasedFrom * 1_000)) buffered_ms=\(Int(geometry.bufferedDuration * 1_000))"
        Task { @MainActor in
            DiagnosticLog.recordMicrophoneEvidence(message)
        }
    }

    private func emit(_ pcm: Data) {
        // A long review-only take is replayed in bounded packets, not thousands
        // of 50ms synchronous yields that could overflow the 480-item ASR queue.
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 64_000, pcm.count)
            onAudio?(pcm.subdata(in: offset..<end))
            offset = end
        }
    }

    func stop(completion: @escaping (Int) -> Void) {
        startupDiagnostics?.note(.stopRequested)
        startupGate.stop()
        Self.lifecycleQueue.async { [self] in
            stopBlocking(flushPendingAudio: startupGate.didCommit, completion: completion)
        }
    }
    private func stopBlocking(flushPendingAudio: Bool = true, completion: ((Int) -> Void)? = nil) {
        guard stopLatch.begin(completion: completion) else { return }
        startupDiagnostics?.begin(.stopGate)
        teardownStarted = true
        updateSettlingDiagnostics()
        startupGate.stop()
        revalidationWorkItem?.cancel()
        revalidationWorkItem = nil
        healthTimer?.setEventHandler(handler: nil)
        healthTimer?.cancel()
        healthTimer = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        startupDiagnostics?.end(.stopGate)
        if let engine {
            startupDiagnostics?.begin(.engineStop)
            engine.stop()
            startupDiagnostics?.end(.engineStop)
            if tapInstalled {
                startupDiagnostics?.begin(.tapRemove)
                engine.inputNode.removeTap(onBus: 0)
                startupDiagnostics?.end(.tapRemove)
            }
        }
        tapInstalled = false
        tapPlan = nil
        // Do not drop the process-wide engine owner here. Removing our
        // NotificationCenter observer does not drain AVFAudio's private queue.
        startupDiagnostics?.begin(.processingDrain)
        processingQueue.sync { [self] in
            alive = false
            if !startupGate.didCommit {
                discardStartupBuffers()
            }
            startupBuffers.removeAll(keepingCapacity: false)
            startupFrames = 0
            if flushPendingAudio && !carry.isEmpty { admit(carry) }
            carry.removeAll(keepingCapacity: true)
            converter = nil
            if !flushPendingAudio { admission = SpeechAdmissionBuffer(); onAudio = nil }
        }
        // Old processing work has drained and the tap is gone. Subsequent
        // classifier completion only uses this capture's buffers, not the engine.
        // Clear the local lease before returning its token; the lifetime owner
        // retains the engine and stale stop callbacks cannot release a new lease.
        startupDiagnostics?.end(.processingDrain)
        startupDiagnostics?.begin(.leaseRelease)
        if let lease = engineLease {
            engineLease = nil
            _ = Self.engineLifetime.release(token: lease.token)
        }
        startupDiagnostics?.end(.leaseRelease)
        guard flushPendingAudio else {
            speechDetector.cancel()
            startupDiagnostics?.finish()
            stopLatch.finish(losses: lostBufferCount)
            return
        }
        // Do not hold lifecycleQueue while a stopped take completes inference.
        startupDiagnostics?.begin(.classifierFinish)
        speechDetector.finish { [self] speech in
            self.processingQueue.async { [self] in
                let digitalSilence = self.activityEvidence.classification == .nearSilence
                if let remainder = self.admission.finish(proof: speech, isDigitalSilence: digitalSilence) {
                    if speech.allowsTranscript {
                        self.recordAdmissionOpened()
                    } else {
                        let message = "admission_recovered capture=\(self.diagnosticID.uuidString) buffered_ms=\(Int(Double(remainder.count) / 32_000 * 1_000))"
                        Task { @MainActor in
                            DiagnosticLog.recordMicrophoneEvidence(message)
                        }
                    }
                    self.emit(remainder)
                }
                self.onAudio = nil
                Task { @MainActor [self] in
                    if let trace = self.speechTrace, trace.isCollecting {
                        let score = Int((speech.maximumConfidence * 1_000).rounded())
                        DiagnosticLog.recordMicrophoneEvidence("speech_classifier capture=\(self.diagnosticID.uuidString) state=\(speech.state.rawValue) windows=\(speech.windows) positives=\(speech.positiveWindows) max_permille=\(score) allowed=\(speech.allowsTranscript) first_speech_ms=\(speech.firstSpeechStart.map { Int($0 * 1_000) } ?? -1)")
                        trace.finish()
                    }
                }
                self.startupDiagnostics?.end(.classifierFinish)
                self.startupDiagnostics?.finish()
                self.stopLatch.finish(losses: self.lostBufferCount)
            }
        }
    }

    enum CaptureError: Error, LocalizedError {
        case noInput, alreadyStarted, engineInUse
        case notReady(MicrophoneStartupGate.Failure)

        var diagnosticCategory: String {
            switch self {
            case .noInput: return "invalid_input_format"
            case .alreadyStarted: return "already_started"
            case .engineInUse: return "engine_in_use"
            case .notReady(let reason): return reason.rawValue
            }
        }

        var errorDescription: String? {
            switch self {
            case .noInput:
                return "マイクの入力形式が確定しませんでした。接続・入力デバイスを確認してください"
            case .alreadyStarted:
                return "同じマイクの準備処理が重複しました"
            case .engineInUse:
                return "前のマイク処理の終了を待っています"
            case .notReady(.configurationChanged), .notReady(.inputRouteChanged), .notReady(.formatChanged):
                return "マイクの接続切り替えが安定しませんでした"
            case .notReady(.noBuffers):
                return "接続したマイクから音声データが届きませんでした"
            default:
                return "マイクから安定した音声データを受信できませんでした"
            }
        }
    }
}
#endif