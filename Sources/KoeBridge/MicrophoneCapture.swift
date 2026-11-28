#if os(macOS)
import Foundation
import AVFoundation
import Synchronization
import KoeBridgeCore

enum MicrophoneInputInterruption: Equatable, Sendable {
    case deviceRemoval
    case inputChange
}

/// End-of-stream conversion is only valid after a clean stop. Deliver each
/// independent buffer through the source's ordinary meter and admission path.
enum CaptureEnd {
    case normal, interrupted, cancelled

    func drain(_ converter: AVAudioConverter?, consume: (AVAudioPCMBuffer) throws -> Void) throws {
        guard self == .normal, let converter else { return }
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 1024) else {
                throw DrainError.conversion
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                state.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            guard status != .error else { throw DrainError.conversion }
            if output.frameLength > 0 { try consume(output) }
            if status == .endOfStream { return }
            guard output.frameLength > 0 else { throw DrainError.conversion }
        }
    }
    private enum DrainError: Error { case conversion }
}

/// One spare shared between tap and conversion. A busy spare takes the original
/// allocation path immediately. Only the owner touches storage; release follows
/// synchronous conversion, including stale-generation and error exits.
final class TapCopySpare: @unchecked Sendable {
    private let inUse = Atomic(false)
    private var storage: AVAudioPCMBuffer?

    func borrow(for input: AVAudioPCMBuffer) -> (buffer: AVAudioPCMBuffer?, owned: Bool) {
        let owns = !inUse.exchange(true, ordering: .acquiring)
        // A converter may retain its last input. Never overwrite storage
        // while any other owner could still be reading it.
        if owns, isKnownUniquelyReferenced(&storage), let storage,
           storage.format === input.format, storage.frameCapacity == input.frameLength {
            let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
            let dst = UnsafeMutableAudioBufferListPointer(storage.mutableAudioBufferList)
            // A partial plane must never expose data from the preceding callback.
            let bytesPerPlane = UInt64(input.frameLength) * UInt64(input.format.streamDescription.pointee.mBytesPerFrame)
            if src.count == dst.count && src.indices.allSatisfy({
                src[$0].mData != nil && UInt64(src[$0].mDataByteSize) == bytesPerPlane
                    && src[$0].mDataByteSize == dst[$0].mDataByteSize
            }) { return (storage, true) }
        }
        let fresh = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength)
        if owns && fresh == nil { inUse.store(false, ordering: .releasing) }
        return (fresh, owns)
    }

    func recycle(_ buffer: AVAudioPCMBuffer) {
        storage = buffer
        inUse.store(false, ordering: .releasing)
    }
}

/// Engine lifecycle, conversion and inference have separate serial lanes.
/// The real-time tap only copies; health counters use healthLock.
final class MicrophoneCapture: @unchecked Sendable {
    private static let lifecycleQueue = DispatchQueue(label: "dev.koebridge.microphone-lifecycle", qos: .userInteractive)
    private let processingQueue = DispatchQueue(label: "dev.koebridge.pcm-conversion", qos: .userInitiated)
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    typealias EngineLifetime = MicrophoneEngineLifetime<AVAudioEngine>
    private static let engineLifetime = EngineLifetime(makeResource: LeasedMicrophoneTapGraph.makeEngine)
    // Warmer operations share the capture lifecycle lane and retained owner.
    static var warmLifecycleQueue: DispatchQueue { lifecycleQueue }
    static var warmEngineLifetime: EngineLifetime { engineLifetime }

    private let acquisitionPurpose: EngineLifetime.Purpose
    private let lifetime: EngineLifetime
    private let hardware: MicrophoneHardware
    private var engineLease: EngineLifetime.Lease? // lifecycleQueue only
    private var engine: AVAudioEngine? { engineLease?.resource }
    private var inputNode: AVAudioNode? // lifecycleQueue only
    // Read after start throws and failed-attempt teardown has completed.
    private(set) var recoveryDisposition: EngineLifetime.Disposition = .normal
    private let selectedInputUID: String
    private var selectedTarget: MicrophoneSelectionTarget? // lifecycleQueue only
    private let volumeGuard: OutputVolumeGuard?
    private let volumeGuardOwner: UUID
    private let volumeGuardStopped = Atomic(false)
    private var volumeGuardLive: Bool {
        !volumeGuardStopped.load(ordering: .acquiring) && !startupGate.isStopped
    }

    func inheritVolumeGuard(from warm: UUID) {
        volumeGuard?.handover(from: warm, to: volumeGuardOwner, attempt: diagnosticID,
                              live: { [weak self] in self?.volumeGuardLive == true })
    }

    func beginVolumeGuard(outputID: UInt32?, deadline: TimeInterval? = nil) {
        volumeGuard?.begin(volumeGuardOwner, attempt: diagnosticID, device: { outputID }, evidence: microphoneEvidence,
                           startupDeadline: deadline, live: { [weak self] in self?.volumeGuardLive == true })
    }

    func invalidateVolumeGuard() {
        volumeGuardStopped.store(true, ordering: .releasing)
        volumeGuard?.pause(volumeGuardOwner, attempt: diagnosticID)
    }

    init(selectedInputUID: String = "", volumeGuard: OutputVolumeGuard? = nil, takeID: UUID = UUID(), startupGate: MicrophoneStartupGate = .init(configuring: true),
         explicitStart: Bool = true, lifetime: EngineLifetime = MicrophoneCapture.engineLifetime,
         hardware: MicrophoneHardware = .init(),
         makeMicrophoneEvidence: @escaping @MainActor () -> MicrophoneEvidenceWriter? = { DiagnosticLog.microphoneEvidenceWriter() },
         makeStartupTrace: @escaping @MainActor (UUID, Bool) -> MicrophonePreparationDiagnostics? = {
             DiagnosticLog.microphoneTrace(captureID: $0, explicitSelection: $1)
         },
         makeSpeechTrace: @escaping @MainActor (UUID) -> InputDiagnosticTrace? = {
             DiagnosticLog.inputTrace(takeID: $0)
         }) {
        acquisitionPurpose = explicitStart ? .capture : .continuation
        self.lifetime = lifetime
        self.hardware = hardware
        self.makeMicrophoneEvidence = makeMicrophoneEvidence
        self.makeStartupTrace = makeStartupTrace
        self.makeSpeechTrace = makeSpeechTrace
        volumeGuardOwner = takeID
        self.volumeGuard = volumeGuard
        self.selectedInputUID = selectedInputUID
        self.startupGate = startupGate
    }
    private let startupGate: MicrophoneStartupGate
    private var revalidationWorkItem: DispatchWorkItem? // lifecycleQueue only
    // Assigned before the observer is installed; immutable for the attempt.
    private var attemptDeadline: TimeInterval = 0
    private var startupBufferEpoch: UInt64 = 1 // processingQueue only
    private let stopLatch = MicrophoneStopLatch()
    private let tap = MicrophoneTapInstallation() // lifecycleQueue only
    private var teardownStarted = false // lifecycleQueue only
    private var startupBuffers: [AVAudioPCMBuffer] = [] // processingQueue only
    private var startupFrames = 0 // processingQueue only; capped at four seconds
    @MainActor private var startRequested = false
    private var carry = Data()
    private var onAudio: ((Data) -> Void)?
    private let chunkBytes = 1_600
    private var alive = false
    private let tapSpare = TapCopySpare()
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
    private let makeMicrophoneEvidence: @MainActor () -> MicrophoneEvidenceWriter?
    private let makeStartupTrace: @MainActor (UUID, Bool) -> MicrophonePreparationDiagnostics?
    private let makeSpeechTrace: @MainActor (UUID) -> InputDiagnosticTrace?
    private var microphoneEvidence: MicrophoneEvidenceWriter?
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

    static func retryDelay(for error: Error, policy: MicrophoneStartupRetryPolicy,
                           attempts: Int, elapsed: TimeInterval,
                           disposition: EngineLifetime.Disposition = .normal) -> TimeInterval? {
        guard disposition == .normal || disposition == .verificationDeferred,
              !(error is MicrophoneSelectionError), !(error is MicrophoneGraphError),
              !(error is CancellationError) else { return nil }
        if let error = error as? CaptureError, case .notReady(let failure) = error {
            return policy.retryDelay(after: attempts, elapsed: elapsed, failure: failure)
        }
        return policy.retryDelay(after: attempts, elapsed: elapsed)
    }

    @MainActor
    func start(deadline requestedDeadline: TimeInterval? = nil,
               onAudio: @escaping (Data) -> Void,
               onDeviceChanged: @escaping (MicrophoneInputInterruption) -> Void = { _ in }) async throws {
        guard !startRequested else { throw CaptureError.alreadyStarted }
        startRequested = true
        let beganAt = hardware.now()
        let deadline = requestedDeadline ?? (beganAt + MicrophoneStartupRetryPolicy().attemptTimeout)
        attemptDeadline = deadline
        microphoneEvidence = makeMicrophoneEvidence()
        startupDiagnostics = makeStartupTrace(diagnosticID, !selectedInputUID.isEmpty)
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
        speechTrace = makeSpeechTrace(diagnosticID)
        if speechTrace?.isCollecting == true {
            self.microphoneEvidence?.write("speech_classifier_started capture=\(diagnosticID.uuidString) build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
        }
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard deadline.isFinite, beganAt < deadline else { throw CaptureError.notReady(.unstableBuffers) }
                guard !startupGate.isStopped else {
                    throw CancellationError()
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Self.lifecycleQueue.async { [self] in
                        do {
                            try startBlocking(onAudio: onAudio, onDeviceChanged: onDeviceChanged)
                            continuation.resume(returning: ())
                        } catch {
                            if error is MicrophoneGraphError, let lease = engineLease {
                                // Install already marks retirement. Include graph errors
                                // beyond install without changing its first disposition.
                                lifetime.retire(lease, preCommitFormatException: false)
                            }
                            startupGate.stop(at: hardware.now())
                            startupDiagnostics?.note(.startFailed, code: (error as NSError).code)
                            stopBlocking(flushPendingAudio: false)
                            if let failure = error as? MicrophoneStartupGate.Failure {
                                continuation.resume(throwing: CaptureError.notReady(failure))
                            } else {
                                continuation.resume(throwing: error)
                            }
                        }
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
                                total: hardware.now() - beganAt,
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
                stop(.cancelled) { _ in }
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
                let running = engine.flatMap { LeasedMicrophoneTapGraph.readEngineRunning($0) } ?? false
                // Settling is notification-driven only. Polls neither probe the HAL
                // during debounce nor turn a poll-detected failure into revalidation.
                switch startupGate.currentPhase {
                case .failed, .stopped, .revalidating, .configuring:
                    continuation.resume(returning: startupGate.decision(
                        at: hardware.now(), deadline: deadline, engineRunning: running))
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
                        at: hardware.now(), deadline: deadline, engineRunning: running))
                    return
                }
                if let inputNode, let selectedTarget,
                   !hardware.isStillSelected(selectedTarget, inputNode) {
                    startupDiagnostics?.note(.inputRouteChanged)
                    if let lease = engineLease, lifetime.isVerifying(lease) {
                        let engine = lease.resource
                        // .revalidating returned early above, so a stopped
                        // engine here means input is genuinely down.
                        let graphIsIntact = running
                            && tap.isInstalled
                            && LeasedMicrophoneTapGraph.readNodeEngine(inputNode) === engine
                            && (LeasedMicrophoneTapGraph.readNodeOutputCount(inputNode) ?? 0) > 0
                            && LeasedMicrophoneTapGraph.readEngineConnectionPoints(
                                engine, node: inputNode, outputBus: 0)?.isEmpty == true
                            && LeasedMicrophoneTapGraph.readNodeFormat(
                                inputNode, input: true, bus: 0).map { tap.hardwareMatches($0) } == true
                            && LeasedMicrophoneTapGraph.readNodeFormat(
                                inputNode, input: false, bus: 0).map { tap.appliedMatches($0) } == true
                        healthLock.lock()
                        let buffersAreIntact = droppedBuffers == 0 && conversionErrors == 0
                        healthLock.unlock()
                        let accepted = startupGate.invalidateForVerification(.inputRouteChanged,
                            at: hardware.now(), deadline: deadline)
                        if accepted && graphIsIntact && buffersAreIntact {
                            lifetime.recordVerificationFailure(.readinessSelection, for: lease)
                        }
                    } else {
                        startupGate.invalidate(.inputRouteChanged)
                    }
                }
                // A notification may also have blocked commit while selection was read.
                switch startupGate.currentPhase {
                case .failed, .stopped, .revalidating, .configuring:
                    continuation.resume(returning: startupGate.decision(
                        at: hardware.now(), deadline: deadline, engineRunning: running))
                    return
                default: break
                }
                let inspectedEpoch = startupGate.currentEpoch
                if let inputNode {
                    do { try verifyTapFormat(inputNode) }
                    catch {
                        startupDiagnostics?.note(.formatChanged)
                        startupGate.invalidate(.formatChanged)
                    }
                }
                var decision = startupGate.decision(
                    at: hardware.now(), deadline: deadline, engineRunning: running)
                if decision == .ready {
                    let committed = processingQueue.sync { [self] in
                        guard self.startupBufferEpoch == inspectedEpoch,
                              self.startupGate.commitBeforeDeadline(deadline, engineRunning: running,
                                                                    expectedEpoch: inspectedEpoch, now: self.hardware.now) else { return false }
                        let pending = self.startupBuffers
                        self.startupBuffers.removeAll(keepingCapacity: false)
                        self.startupFrames = 0
                        // Preserve the start of speech without exposing PCM from
                        // a failed preparation to SoundAnalysis or either ASR.
                        for buffer in pending { self.consume(buffer) }
                        return true
                    }
                    if committed, let lease = engineLease {
                        lifetime.finishVerification(lease)
                    }
                    if !committed {
                        decision = startupGate.decision(at: hardware.now(),
                                                         deadline: deadline, engineRunning: running)
                        if decision == .ready { decision = .waiting }
                    }
                }
                continuation.resume(returning: decision)
            }
        }
    }

    /// Wait for failed-attempt teardown before creating another engine.
    func cancelAndWait() async {
        invalidateVolumeGuard()
        startupDiagnostics?.note(.stopRequested)
        startupGate.stop(at: hardware.now())
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.lifecycleQueue.async { [self] in
                stopBlocking(flushPendingAudio: false) { _ in
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func invalidateStartup(_ reason: MicrophoneStartupGate.Failure,
                                   onDeviceChanged: @escaping (MicrophoneInputInterruption) -> Void) {
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
                                    onDeviceChanged: @escaping (MicrophoneInputInterruption) -> Void) {
        // Never stop/deallocate an engine in its notification callback. Disarm
        // input on the lifecycle lane immediately instead of leaving it live
        // for the whole UI round trip; teardown ownership stays with stop().
        Self.lifecycleQueue.async { [weak self] in self?.quiesceEngine() }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.startupGate.isStopped else { return }
            self.microphoneEvidence?.write("mic_interrupted capture=\(self.diagnosticID.uuidString) category=\(reason.rawValue)")
            onDeviceChanged(reason == .inputRouteChanged ? .deviceRemoval : .inputChange)
        }
    }

    /// Stop input rendering without releasing the lease or the tap. A live
    /// engine during a route change is what lets a CoreAudio input callback
    /// reach a graph that AVFAudio is rebuilding underneath it; full teardown
    /// ownership stays with stopBlocking().
    private func quiesceEngine() {
        guard let lease = engineLease else { return }
        _ = LeasedMicrophoneTapGraph.stopEngine(lease.resource)
    }

    /// Liveness observed when input was first disarmed for this engine.
    /// Revalidation probes run against the stopped engine, so the verdict and
    /// graph-intact checks use this snapshot instead of a live read.
    private var revalidationWasRunning = false // lifecycleQueue only

    /// Disarm input while a route change settles. AVFAudio rebuilds the input
    /// unit under a running engine; a stopped engine cannot deliver the input
    /// callback that aborts when that rebuild removes the tap behind our back.
    private func quiesceForRevalidation() {
        guard !teardownStarted, case .revalidating = startupGate.currentPhase else { return }
        guard let lease = engineLease else { return }
        let running = LeasedMicrophoneTapGraph.readEngineRunning(lease.resource)
        // An already-stopped engine keeps the earlier snapshot: we may be the
        // ones holding it. An unreadable isRunning is treated as live.
        guard running != false else { return }
        revalidationWasRunning = true
        if !LeasedMicrophoneTapGraph.stopEngine(lease.resource) {
            startupGate.invalidate(.engineStopped, at: hardware.now())
        }
    }

    private func updateSettlingDiagnostics() {
        startupDiagnostics?.settling(startupGate.settlingSnapshot(at: hardware.now()))
    }

    private func handleConfigurationChange(reason: MicrophoneStartupGate.Failure,
                                           onDeviceChanged: @escaping (MicrophoneInputInterruption) -> Void) {
        let outcome = startupGate.handleConfigurationChange(
            at: hardware.now(), deadline: attemptDeadline, reason: reason)
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
            Self.lifecycleQueue.async { [weak self] in self?.quiesceEngine() }
        case .revalidate(let epoch, _):
            startupDiagnostics?.noteChurn(epoch: epoch)
            Self.lifecycleQueue.async { [weak self] in
                guard let self else { return }
                self.quiesceForRevalidation()
                self.scheduleRevalidation(after: 0)
            }
        }
    }

    /// First wake is immediate; the gate computes the remaining debounce from
    /// notification time, so a slow setup/HAL call cannot restart the coalesce window.
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
        switch startupGate.revalidationReadiness(at: hardware.now(), deadline: attemptDeadline) {
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
        volumeGuard?.check()
        // Disarm input before probing: the engine stays stopped through the
        // settle window so a CoreAudio input callback cannot reach the graph
        // while AVFAudio rebuilds it. The verdict sees quiesce-time liveness.
        quiesceForRevalidation()
        guard !teardownStarted, case .revalidating = startupGate.currentPhase else {
            startupDiagnostics?.end(.revalidating)
            return
        }
        let engine = self.engine
        let node = inputNode
        let selected = selectedTarget.map { target in
            node.map { hardware.isStillSelected(target, $0) } ?? false
        } ?? false
        let hardwareFormat = node.flatMap { LeasedMicrophoneTapGraph.readNodeFormat($0, input: true, bus: 0) }
        let applied = node.flatMap { LeasedMicrophoneTapGraph.readNodeFormat($0, input: false, bus: 0) }
        healthLock.lock()
        let losses = droppedBuffers, errors = conversionErrors
        healthLock.unlock()
        let running = revalidationWasRunning
        let input = MicrophoneRevalidationInput(
            hasEngineAndTarget: engineLease != nil && selectedTarget != nil,
            deviceStillSelected: selected, engineRunning: running, tapInstalled: tap.isInstalled,
            outputConnectionsEmpty: node.flatMap { n in
                engine.flatMap { LeasedMicrophoneTapGraph.readEngineConnectionPoints($0, node: n, outputBus: 0)?.isEmpty }
            } ?? false,
            hardwareFormatValid: hardwareFormat.map { MicrophoneTapFormatPlan(hardwareSampleRate: $0.sampleRate, hardwareChannels: $0.channelCount) != nil } ?? false,
            hardwareMatchesPlan: hardwareFormat.map { tap.hardwareMatches($0) } ?? false,
            appliedMatchesPlan: applied.map { tap.appliedMatches($0) } ?? false,
            droppedBuffers: losses, conversionErrors: errors)
        let verdict = MicrophoneRevalidationPolicy.evaluate(input)
        // Native reads can race a newer notification or cancellation. Never apply
        // an old checklist (including its failure) to a different epoch.
        guard case .revalidating(let current, _, _) = startupGate.currentPhase, current == epoch else {
            startupDiagnostics?.end(.revalidating)
            scheduleRevalidation(after: 0)
            return
        }
        switch verdict {
        case .fail(let reason, let component):
            if reason == .inputRouteChanged, component == .selection,
               let lease = engineLease, lifetime.isVerifying(lease) {
                let graphIsIntact = input.engineRunning && input.tapInstalled && input.outputConnectionsEmpty
                    && node.flatMap({ LeasedMicrophoneTapGraph.readNodeEngine($0) }) === lease.resource
                    && (node.flatMap { LeasedMicrophoneTapGraph.readNodeOutputCount($0) } ?? 0) > 0
                    && input.hardwareFormatValid && input.hardwareMatchesPlan && input.appliedMatchesPlan
                let accepted = startupGate.invalidateForVerification(reason, expectedEpoch: epoch,
                    at: hardware.now(), deadline: attemptDeadline)
                if accepted && graphIsIntact {
                    lifetime.recordVerificationFailure(.revalidationSelection, for: lease)
                }
            } else {
                startupGate.invalidate(reason, expectedEpoch: epoch, at: hardware.now())
            }
        case .resume:
            do {
                guard let lease = engineLease, let node else {
                    throw MicrophoneGraphError.unexpectedTopology
                }
                // Input was disarmed for the settled probe; restart it only
                // after the checklist passes, on the settled route.
                try LeasedMicrophoneTapGraph(lifetime: lifetime, lease: lease,
                                             node: node) { true }.start()
            } catch {
                startupDiagnostics?.end(.revalidating)
                updateSettlingDiagnostics()
                startupGate.invalidate(.engineStopped, expectedEpoch: epoch, at: hardware.now())
                if case .failed = startupGate.currentPhase { startupDiagnostics?.note(.settlingBudget) }
                return
            }
            // Input is live again: the quiesce-time snapshot must not leak into
            // later liveness checks or the next quiesce read.
            revalidationWasRunning = false
            let resumed = processingQueue.sync { [self] in
                discardStartupBuffers()
                // Retain the converter but discard any internally buffered old PCM.
                converter?.reset()
                startupBufferEpoch = epoch
                return startupGate.resumeStabilising(expectedEpoch: epoch, at: hardware.now())
            }
            if !resumed {
                startupDiagnostics?.end(.revalidating)
                updateSettlingDiagnostics()
                if case .failed = startupGate.currentPhase { startupDiagnostics?.note(.settlingBudget) }
                scheduleRevalidation(after: 0)
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
                               onDeviceChanged: @escaping (MicrophoneInputInterruption) -> Void) throws {
        guard !startupGate.isStopped, !teardownStarted else { throw CancellationError() }
        guard hardware.now() < attemptDeadline else { throw CaptureError.notReady(.unstableBuffers) }
        guard engine == nil else { throw CaptureError.alreadyStarted }
        let beganAt = Date()
        startupDiagnostics?.end(.lifecycle)
        // A replacement is reserved before resolving the device again. A
        // failed selection after generation creation fails its verification.
        switch lifetime.disposition {
        case .replacementPending, .verificationDeferred:
            try acquireEngine()
            try checkStartupWindow()
        case .terminal:
            startupDiagnostics?.begin(.engineLease)
            recoveryDisposition = .terminal
            throw MicrophoneGraphError.quarantined
        case .normal: break
        }
        startupDiagnostics?.begin(.deviceList)
        let snapshot = try hardware.snapshot()
        startupDiagnostics?.end(.deviceList, code: snapshot.devices.count)
        startupDiagnostics?.begin(.selection)
        let target: MicrophoneSelectionTarget
        do {
            target = try MicrophoneSelectionPolicy.resolve(uid: selectedInputUID,
                devices: snapshot.devices, systemDefaultID: snapshot.defaultID)
        } catch let error as MicrophoneSelectionError {
            switch error {
            case .noSystemInput, .selectedDeviceMissing, .ambiguousDevice:
                recordSynchronousVerificationFailure(.deviceResolution(error))
            }
            throw error
        }
        selectedTarget = target
        startupDiagnostics?.end(.selection)
        startupDiagnostics?.begin(.routeSnapshot)
        routeSnapshot = hardware.route(target.deviceID)
        beginVolumeGuard(outputID: routeSnapshot?.outputDeviceID, deadline: attemptDeadline)
        startupDiagnostics?.end(.routeSnapshot)
        if engineLease == nil { try acquireEngine() }
        try checkStartupWindow()
        guard let lease = engineLease else { throw CaptureError.engineInUse }
        let engine = lease.resource
        startupDiagnostics?.begin(.inputNode)
        let node = hardware.inputNode(engine)
        inputNode = node
        startupDiagnostics?.end(.inputNode)
        guard let node else { throw MicrophoneDevices.DeviceError.noAudioUnit }
        do {
            try hardware.bind(target, node, startupDiagnostics)
        } catch MicrophoneDevices.DeviceError.selectionNotApplied {
            if lifetime.isVerifying(lease),
               LeasedMicrophoneTapGraph.readNodeEngine(node) === engine,
               (LeasedMicrophoneTapGraph.readNodeOutputCount(node) ?? 0) > 0,
               LeasedMicrophoneTapGraph.readEngineConnectionPoints(
                   engine, node: node, outputBus: 0)?.isEmpty == true {
                recordSynchronousVerificationFailure(.binding)
            }
            throw MicrophoneDevices.DeviceError.selectionNotApplied
        }
        // Device binding itself may emit a synchronous configuration change.
        // Subscribe after that deliberate change, before tap/engine startup.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.invalidateStartup(.configurationChanged, onDeviceChanged: onDeviceChanged)
        }
        let graph = LeasedMicrophoneTapGraph(lifetime: lifetime, lease: lease, node: node) { [hardware] in
            hardware.isStillSelected(target, node)
        }
        let sink = MicrophoneTapInstallation.Sink.capture(output: output, configure: { converter, hardware, client in
            let input = converter.inputFormat
            self.formatSnapshot = InputFormatSnapshot(hardwareRate: hardware.sampleRate,
                hardwareChannels: hardware.channelCount, nodeRate: client.sampleRate,
                nodeChannels: client.channelCount, tapRate: input.sampleRate, tapChannels: input.channelCount)
            self.processingQueue.sync {
                self.onAudio = onAudio
                self.converter = converter
                self.alive = true
            }
        }, readback: { applied in
            self.formatSnapshot?.appliedRate = applied.sampleRate
            self.formatSnapshot?.appliedChannels = applied.channelCount
        }, receive: { [weak self] buffer, token in
            guard let self else { return }
            // Timestamp arrival, not eventual conversion. Queued old buffers
            // must not make a stalled microphone appear live/ready.
            let arrivedAt = self.hardware.now()
            if self.startupGate.noteTapArrival(token, at: arrivedAt) {
                self.startupDiagnostics?.note(.buffersInterrupted)
                self.notifyInterruption(.buffersInterrupted, onDeviceChanged: onDeviceChanged)
                return
            }
            self.startupDiagnostics?.observeInput(frames: Int(buffer.frameLength), at: arrivedAt)
            guard self.workSlots.wait(timeout: .now()) == .success else { self.noteBufferLoss(); return }
            let (candidate, ownsSpare) = self.tapSpare.borrow(for: buffer)
            guard let copy = candidate else {
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
            self.processingQueue.async { [weak self, slots = self.workSlots, spare = self.tapSpare] in
                defer {
                    if ownsSpare { spare.recycle(copy) }
                    slots.signal()
                }
                self?.convert(copy, arrivedAt: arrivedAt, token: token, onDeviceChanged: onDeviceChanged)
            }
        })
        volumeGuard?.check()
        let plan = try tap.installAndPrepare(graph: graph, gate: startupGate, deadline: attemptDeadline,
                                             diagnostics: startupDiagnostics, now: hardware.now, sink: sink) {
            if lifetime.isVerifying(lease), graph.stoppedAndUnconnected {
                recordSynchronousVerificationFailure(.preStartSelection)
            }
        }
        guard !startupGate.isStopped else { throw CancellationError() }
        guard hardware.now() < attemptDeadline else { throw CaptureError.notReady(.unstableBuffers) }
        let startAt = Date()
        startupDiagnostics?.begin(.engineStart)
        try graph.start()
        volumeGuard?.check()
        startupDiagnostics?.end(.engineStart)
        guard !startupGate.isStopped else { throw CancellationError() }
        guard hardware.now() < attemptDeadline else { throw CaptureError.notReady(.unstableBuffers) }
        let phase = startupGate.finishConfiguring(at: hardware.now())
        if case .revalidating = phase {
            quiesceForRevalidation()
            scheduleRevalidation(after: 0)
        } else { startupDiagnostics?.begin(.awaitPCM) }
        let timer = DispatchSource.makeTimerSource(queue: Self.lifecycleQueue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let failure = self.startupGate.recordingFailure(
                at: self.hardware.now(),
                engineRunning: self.engine.flatMap {
                    LeasedMicrophoneTapGraph.readEngineRunning($0)
                } ?? false) {
                self.invalidateStartup(failure, onDeviceChanged: onDeviceChanged)
            } else if self.startupGate.didCommit,
                      let node = self.inputNode, let target = self.selectedTarget,
                      !self.hardware.isStillSelected(target, node) {
                self.invalidateStartup(.inputRouteChanged, onDeviceChanged: onDeviceChanged)
            }
        }
        healthTimer = timer
        timer.resume()
        let completedAt = Date()
        startTimings = StartTimings(microphonePreparation: startAt.timeIntervalSince(beganAt),
                                   engineStart: completedAt.timeIntervalSince(startAt),
                                   total: completedAt.timeIntervalSince(beganAt),
                                   sampleRate: plan.sampleRate, channels: plan.channelCount)
    }

    private func recordSynchronousVerificationFailure(_ cause: EngineLifetime.VerificationFailure) {
        guard let lease = engineLease, lifetime.isVerifying(lease),
              LeasedMicrophoneTapGraph.readEngineRunning(lease.resource) == false,
              hardware.now() < attemptDeadline, !startupGate.isStopped else { return }
        lifetime.recordVerificationFailure(cause, for: lease)
    }

    private func checkStartupWindow() throws {
        guard !startupGate.isStopped else { throw CancellationError() }
        guard hardware.now() < attemptDeadline else { throw CaptureError.notReady(.unstableBuffers) }
    }

    private func acquireEngine() throws {
        startupDiagnostics?.begin(.engineLease)
        try checkStartupWindow()
        let acquired: EngineLifetime.Lease?
        do {
            acquired = try lifetime.acquire(for: acquisitionPurpose, takeID: volumeGuardOwner,
                canAcquire: hardware.now() < attemptDeadline && !startupGate.isStopped)
        } catch {
            recoveryDisposition = lifetime.disposition
            throw error
        }
        guard let acquired else {
            try checkStartupWindow()
            if lifetime.isQuarantined {
                recoveryDisposition = lifetime.disposition
                throw MicrophoneGraphError.quarantined
            }
            throw CaptureError.engineInUse
        }
        engineLease = acquired
        revalidationWasRunning = false
        startupDiagnostics?.end(.engineLease)
    }

    /// Read back both scopes; never promote a successful API call alone to a
    /// valid stream. This does not change the system device or hardware rate.
    private func verifyTapFormat(_ node: AVAudioNode) throws {
        let hardware = LeasedMicrophoneTapGraph.readNodeFormat(node, input: true, bus: 0)
        let applied = LeasedMicrophoneTapGraph.readNodeFormat(node, input: false, bus: 0)
        formatSnapshot?.appliedRate = applied?.sampleRate ?? 0
        formatSnapshot?.appliedChannels = applied?.channelCount ?? 0
        guard let hardware, let applied,
              tap.hardwareMatches(hardware), tap.appliedMatches(applied) else {
            throw CaptureError.notReady(.formatChanged)
        }
    }

    func acceptsForConversion(_ buffer: AVAudioPCMBuffer, token: MicrophoneStartupGate.TapCaptureToken,
                              expected: AVAudioFormat, onDeviceChanged: @escaping (MicrophoneInputInterruption) -> Void) -> Bool {
        guard startupGate.accepts(token), buffer.frameLength > 0 else { return false }
        let format = buffer.format
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              MicrophoneTapInstallation.sameFormat(format, expected) else {
            noteBufferLoss(conversionError: true)
            invalidateStartup(.formatChanged, onDeviceChanged: onDeviceChanged)
            return false
        }
        return true
    }

    private func convert(_ incoming: AVAudioPCMBuffer, arrivedAt: TimeInterval,
                         token: MicrophoneStartupGate.TapCaptureToken,
                         onDeviceChanged: @escaping (MicrophoneInputInterruption) -> Void) {
        guard alive, let converter,
              acceptsForConversion(incoming, token: token, expected: converter.inputFormat,
                                   onDeviceChanged: onDeviceChanged) else { return }
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
        microphoneEvidence?.enqueue("admission_opened capture=\(diagnosticID.uuidString) first_speech_ms=\(firstSpeechMS) released_from_ms=\(Int(geometry.releasedFrom * 1_000)) buffered_ms=\(Int(geometry.bufferedDuration * 1_000))")
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

    func stop(_ end: CaptureEnd, completion: @escaping (Int) -> Void) {
        invalidateVolumeGuard()
        startupDiagnostics?.note(.stopRequested)
        startupGate.stop(at: hardware.now())
        Self.lifecycleQueue.async { [self] in
            stopBlocking(flushPendingAudio: startupGate.didCommit, end: end, completion: completion)
        }
    }
    private func stopBlocking(flushPendingAudio: Bool, end: CaptureEnd = .cancelled, completion: ((Int) -> Void)? = nil) {
        guard stopLatch.begin(completion: completion) else { return }
        invalidateVolumeGuard()
        startupDiagnostics?.begin(.stopGate)
        teardownStarted = true
        updateSettlingDiagnostics()
        startupGate.stop(at: hardware.now())
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
        let cleanupLease = engineLease.flatMap { lifetime.beginCleanup($0) ? $0 : nil }
        var cleanupEvidence: EngineLifetime.CleanupEvidence?
        if let lease = cleanupLease {
            let hadTap = tap.isInstalled
            startupDiagnostics?.begin(.engineStop)
            let stopped = LeasedMicrophoneTapGraph.stopEngine(lease.resource)
            startupDiagnostics?.end(.engineStop)
            let running = lifetime.needsIndependentStopReadback(lease, hadTap: hadTap)
                ? LeasedMicrophoneTapGraph.readEngineRunning(lease.resource) : nil
            if hadTap { startupDiagnostics?.begin(.tapRemove) }
            let removed = tap.removeIfOwned()
            if hadTap { startupDiagnostics?.end(.tapRemove) }
            cleanupEvidence = .init(stopped: stopped, hadTap: hadTap, removed: removed, runningAtCleanup: running)
            if !stopped || (hadTap && removed != true) || lifetime.cleanupEndsTake(lease) {
                volumeGuard?.end(volumeGuardOwner)
            }
        } else {
            tap.removeIfOwned()
        }
        inputNode = nil
        selectedTarget = nil
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
            if flushPendingAudio && lostBufferCount == 0 {
                do { try end.drain(converter, consume: consume) }
                catch { noteBufferLoss(conversionError: true) }
            }
            if flushPendingAudio && !carry.isEmpty { admit(carry) }
            carry.removeAll(keepingCapacity: true)
            converter = nil
            if !flushPendingAudio { admission = SpeechAdmissionBuffer(); onAudio = nil }
        }
        // Old processing work has drained and its generation is closed. Subsequent
        // classifier completion only uses this capture's buffers, not the engine.
        // Clear the local lease before returning its token; the lifetime owner
        // retains the engine and stale stop callbacks cannot release a new lease.
        startupDiagnostics?.end(.processingDrain)
        startupDiagnostics?.begin(.leaseRelease)
        engineLease = nil
        revalidationWasRunning = false
        if !flushPendingAudio { speechDetector.cancel() }
        if let lease = cleanupLease, let cleanupEvidence {
            let record: ((String) -> Void)? = microphoneEvidence.map { writer in { _ = writer.enqueue($0) } }
            recoveryDisposition = lifetime.finishCleanup(lease, evidence: cleanupEvidence, record: record)
        }
        startupDiagnostics?.end(.leaseRelease)
        guard flushPendingAudio else {
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
                        self.microphoneEvidence?.enqueue("admission_recovered capture=\(self.diagnosticID.uuidString) buffered_ms=\(Int(Double(remainder.count) / 32_000 * 1_000))")
                    }
                    self.emit(remainder)
                }
                self.onAudio = nil
                Task { @MainActor [self] in
                    if let trace = self.speechTrace, trace.isCollecting {
                        let score = Int((speech.maximumConfidence * 1_000).rounded())
                        self.microphoneEvidence?.write("speech_classifier capture=\(self.diagnosticID.uuidString) state=\(speech.state.rawValue) windows=\(speech.windows) positives=\(speech.positiveWindows) max_permille=\(score) allowed=\(speech.allowsTranscript) first_speech_ms=\(speech.firstSpeechStart.map { Int($0 * 1_000) } ?? -1)")
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