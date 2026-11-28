import Foundation

/// App-level retry budget. This cannot preempt a blocked OS audio driver call.
public struct MicrophoneStartupRetryPolicy: Sendable {
    public let maximumAttempts: Int
    public let totalTimeout: TimeInterval
    public let attemptTimeout: TimeInterval

    public init(maximumAttempts: Int = 4, totalTimeout: TimeInterval = 10,
                attemptTimeout: TimeInterval = 2.5) {
        precondition(maximumAttempts > 0)
        precondition(totalTimeout.isFinite && totalTimeout > 0)
        precondition(attemptTimeout.isFinite && attemptTimeout > 0)
        self.maximumAttempts = maximumAttempts
        self.totalTimeout = totalTimeout
        self.attemptTimeout = attemptTimeout
    }

    public func remaining(at elapsed: TimeInterval) -> TimeInterval {
        guard elapsed.isFinite else { return 0 }
        return max(0, totalTimeout - max(0, elapsed))
    }

    /// `completedAttempts` includes the attempt that just failed.
    public func retryDelay(after completedAttempts: Int,
                           elapsed: TimeInterval) -> TimeInterval? {
        retryDelay(after: completedAttempts, elapsed: elapsed, failure: nil)
    }

    /// Route-churn failures often reflect an unchanged format and settle quickly;
    /// driver or buffer failures keep the legacy backoff.
    public func retryDelay(after completedAttempts: Int,
                           elapsed: TimeInterval,
                           failure: MicrophoneStartupGate.Failure?) -> TimeInterval? {
        guard completedAttempts > 0, completedAttempts < maximumAttempts else { return nil }
        let delay: TimeInterval
        if let failure, Self.isRouteChurn(failure) {
            delay = 0.05
        } else {
            delay = min(0.8, 0.2 * Double(completedAttempts))
        }
        guard remaining(at: elapsed) > delay else { return nil }
        return delay
    }

    private static func isRouteChurn(_ failure: MicrophoneStartupGate.Failure) -> Bool {
        switch failure {
        case .configurationChanged, .formatChanged, .inputRouteChanged:
            return true
        case .conversionFailed, .bufferDropped, .startupBufferOverflow,
             .engineStopped, .noBuffers, .buffersInterrupted, .unstableBuffers:
            return false
        }
    }

    public func timeoutForNextAttempt(elapsed: TimeInterval) -> TimeInterval {
        min(attemptTimeout, remaining(at: elapsed))
    }
}

/// A gate belongs to ONE AVAudioEngine attempt. New attempts use new gates,
/// converters and classifiers, so late events cannot poison a newer attempt.
/// No speech, amplitude or transcript threshold is used for device readiness:
/// a valid silent PCM stream is a successfully opened microphone.
public final class MicrophoneStartupGate: @unchecked Sendable {
    public enum Failure: String, Error, Sendable {
        case configurationChanged = "configuration_changed"
        case inputRouteChanged = "input_route_changed"
        case formatChanged = "format_changed"
        case conversionFailed = "conversion_failed"
        case bufferDropped = "buffer_dropped"
        case startupBufferOverflow = "startup_buffer_overflow"
        case engineStopped = "engine_stopped"
        case noBuffers = "no_buffers"
        case buffersInterrupted = "buffers_interrupted"
        case unstableBuffers = "unstable_buffers"
    }

    public enum Decision: Equatable, Sendable {
        case waiting, ready, stopped
        case failed(Failure)
    }

    public enum Phase: Equatable, Sendable {
        case configuring(epoch: UInt64, churnPending: Bool)
        case stabilising(epoch: UInt64)
        case revalidating(epoch: UInt64, pendingSince: TimeInterval, lastChurnAt: TimeInterval)
        case committed, failed(Failure), stopped
    }
    public enum ConfigurationChangeOutcome: Equatable, Sendable {
        case ignored, committedInterrupted
        case revalidate(epoch: UInt64, firstInBurst: Bool)
        case budgetExhausted(Failure)
    }
    public enum RevalidationReadiness: Equatable, Sendable {
        case notRevalidating
        case debouncePending(remaining: TimeInterval)
        case readyToRevalidate(epoch: UInt64)
        case budgetExhausted(Failure)
    }
    public enum ObserveResult: Equatable, Sendable { case buffered, committed, dropped }
    public struct TapCaptureToken: Equatable, Sendable {
        public let stabilityEpoch: UInt64
        public let tapGeneration: UInt64
    }
    public struct SettlingSnapshot: Equatable, Sendable {
        public let epoch: UInt64
        public let churnCount: Int
        public let revalidations: Int
        public let duration: TimeInterval
        public let readyViaSettling: Bool
    }

    private let lock = NSLock()
    private let settlingPolicy: MicrophoneSettlingPolicy
    private var configuring: Bool
    private var stabilityEpoch: UInt64 = 1
    // Phase 1 retains the installed tap. Kept separate from the stability epoch.
    private let tapGeneration: UInt64 = 1
    private var pendingSince: TimeInterval?
    private var lastChurnAt: TimeInterval?
    private var settlingDeadline: TimeInterval?
    private var cumulativeSettlingDuration: TimeInterval = 0
    private var settlingEndedAt: TimeInterval?
    private var revalidationEpoch: UInt64?
    private var churnCount = 0
    private var revalidations = 0
    private var everReceivedBuffer = false
    private let stableDuration: TimeInterval
    private let maximumGap: TimeInterval
    private var firstBufferAt: TimeInterval?
    private var lastTapAt: TimeInterval?
    public static let recordingGap: TimeInterval = 1
    private var lastBufferAt: TimeInterval?
    private var stableSince: TimeInterval?
    private var consecutiveBuffers = 0
    private var failure: Failure?
    private var committed = false
    private var stopped = false

    /// Capture starts with `configuring: true`; legacy stream-only callers may
    /// start directly in stabilising without an engine-setup phase.
    public init(stableDuration: TimeInterval = 0.15,
                maximumGap: TimeInterval = 0.35,
                settlingPolicy: MicrophoneSettlingPolicy = .init(),
                configuring: Bool = false) {
        precondition(stableDuration.isFinite && stableDuration >= 0)
        precondition(maximumGap.isFinite && maximumGap > stableDuration)
        self.settlingPolicy = settlingPolicy
        self.configuring = configuring
        self.stableDuration = stableDuration
        self.maximumGap = maximumGap
    }

    public var didCommit: Bool {
        lock.lock(); defer { lock.unlock() }
        return committed
    }

    /// Sticky after stop: an interruption can race with the UI's stop action.
    /// The final capture receipt must still reject incomplete audio, even when
    /// the asynchronous onDeviceChanged callback no longer owns the UI.
    public var recordingWasInterrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return committed && failure != nil
    }

    public var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// A normal stop must drain already queued recording buffers. A cancelled
    /// preparation must never emit them. `alive` on the processing queue also
    /// gates all work after the tap has been removed.
    public var acceptsBuffers: Bool {
        lock.lock(); defer { lock.unlock() }
        return acceptsBuffersLocked
    }

    public var firstBufferTime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return firstBufferAt
    }

    public var currentPhase: Phase {
        lock.lock(); defer { lock.unlock() }
        return phaseLocked
    }
    package var configuringWithoutChurn: Bool {
        lock.lock(); defer { lock.unlock() }
        return configuring && !stopped && failure == nil && pendingSince == nil
    }

    package func cancelWarmPreparation() {
        lock.lock(); defer { lock.unlock() }
        if configuring { stopped = true }
    }

    /// A change during installation invalidates that single warm attempt.
    /// Only a previously established warm route can request a fresh evaluation.
    package func warmConfigurationChanged() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, failure == nil else { return false }
        if configuring { failure = .configurationChanged }
        return !configuring
    }

    /// Linearize a warm start against cancellation and configuration callbacks.
    /// A warmer has no audio admission or recording commit.
    package func finishWarmStart(deadline: TimeInterval, now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard configuring, !stopped, failure == nil, pendingSince == nil,
              now() < deadline else { return false }
        configuring = false
        return true
    }

    public var currentTapGeneration: UInt64 { tapGeneration }
    public var currentEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return stabilityEpoch
    }
    private var phaseLocked: Phase {
        if stopped { return .stopped }
        if let failure { return .failed(failure) }
        if committed { return .committed }
        if configuring { return .configuring(epoch: stabilityEpoch, churnPending: pendingSince != nil) }
        if let pendingSince, let lastChurnAt {
            return .revalidating(epoch: stabilityEpoch, pendingSince: pendingSince, lastChurnAt: lastChurnAt)
        }
        return .stabilising(epoch: stabilityEpoch)
    }
    private var acceptsBuffersLocked: Bool {
        failure == nil && (committed || (!stopped && pendingSince == nil))
    }
    public func captureTokenForTap(tapGeneration: UInt64) -> TapCaptureToken? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, acceptsBuffersLocked, tapGeneration == self.tapGeneration else { return nil }
        return TapCaptureToken(stabilityEpoch: stabilityEpoch, tapGeneration: tapGeneration)
    }
    /// Queued recording buffers still drain after a normal stop; new tap work cannot enter.
    public func accepts(_ token: TapCaptureToken) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return acceptsBuffersLocked && token.stabilityEpoch == stabilityEpoch && token.tapGeneration == tapGeneration
    }
    /// Called for admitted tap work, before conversion can hide an arrival gap.
    /// The token may already be draining after stop.
    public func noteTapArrival(_ token: TapCaptureToken, at now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard acceptsBuffersLocked, token.stabilityEpoch == stabilityEpoch,
              token.tapGeneration == tapGeneration else { return false }
        if committed, let previous = lastTapAt ?? lastBufferAt, now - previous >= Self.recordingGap {
            failure = .buffersInterrupted
            return true
        }
        lastTapAt = now
        return false
    }

    public func observeConvertedBuffer(frames: Int, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _ = observeLocked(frames: frames, at: now, epoch: stabilityEpoch)
    }
    public func observeConvertedBuffer(frames: Int, at now: TimeInterval, epoch: UInt64) -> ObserveResult {
        lock.lock(); defer { lock.unlock() }
        return observeLocked(frames: frames, at: now, epoch: epoch)
    }
    private func observeLocked(frames: Int, at now: TimeInterval, epoch: UInt64) -> ObserveResult {
        guard frames > 0, now.isFinite, acceptsBuffersLocked, epoch == stabilityEpoch else { return .dropped }
        if stopped { return committed ? .committed : .dropped }
        if let last = lastBufferAt, now < last { return .dropped }
        everReceivedBuffer = true
        if firstBufferAt == nil { firstBufferAt = now }
        if let last = lastBufferAt, now - last <= maximumGap {
            consecutiveBuffers += 1
        } else {
            consecutiveBuffers = 1
            stableSince = now
        }
        lastBufferAt = now
        return committed ? .committed : .buffered
    }
    private func resetStabilityLocked() {
        firstBufferAt = nil; lastBufferAt = nil; lastTapAt = nil; stableSince = nil; consecutiveBuffers = 0
    }
    @discardableResult public func finishConfiguring(at now: TimeInterval) -> Phase {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, failure == nil, !committed else { return phaseLocked }
        configuring = false
        return phaseLocked
    }
    /// Notification entry point: no HAL calls, queue hops, or check-then-commit gap.
    public func handleConfigurationChange(at now: TimeInterval, deadline: TimeInterval,
                                          reason: Failure = .configurationChanged) -> ConfigurationChangeOutcome {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, failure == nil else { return .ignored }
        if committed { failure = reason; return .committedInterrupted }
        let first = pendingSince == nil
        stabilityEpoch += 1
        churnCount += 1
        resetStabilityLocked()
        if first { pendingSince = now }
        lastChurnAt = now
        settlingDeadline = min(settlingDeadline ?? deadline, deadline)
        if !settlingBudgetAllowsLocked(at: now, deadline: deadline) {
            failure = .configurationChanged
            settlingEndedAt = now
            return .budgetExhausted(.configurationChanged)
        }
        return .revalidate(epoch: stabilityEpoch, firstInBurst: first)
    }
    public func revalidationReadiness(at now: TimeInterval, deadline: TimeInterval) -> RevalidationReadiness {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, failure == nil, !committed, !configuring,
              let pendingSince, let lastChurnAt else { return .notRevalidating }
        let target = min(lastChurnAt + settlingPolicy.debounceDuration,
                         pendingSince + settlingPolicy.maxCoalesceDuration)
        guard settlingBudgetAllowsLocked(at: now, deadline: deadline),
              deadline - max(now, target) >= settlingPolicy.minimumCommitRunway else {
            failure = .configurationChanged
            settlingEndedAt = now
            return .budgetExhausted(.configurationChanged)
        }
        if now < target { return .debouncePending(remaining: target - now) }
        // A checklist may be probed more than once but only consumes one slot per epoch.
        if revalidationEpoch != stabilityEpoch {
            guard revalidations < settlingPolicy.maxRevalidations else {
                failure = .configurationChanged
                settlingEndedAt = now
                return .budgetExhausted(.configurationChanged)
            }
            revalidations += 1
            revalidationEpoch = stabilityEpoch
        }
        return .readyToRevalidate(epoch: stabilityEpoch)
    }
    public func resumeStabilising(expectedEpoch: UInt64, at now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, failure == nil, !committed, !configuring,
              expectedEpoch == stabilityEpoch, revalidationEpoch == expectedEpoch,
              let pendingSince, let deadline = settlingDeadline else { return false }
        // Re-check after potentially slow native calls, without extending the attempt.
        guard settlingBudgetAllowsLocked(at: now, deadline: deadline) else {
            failure = .configurationChanged
            settlingEndedAt = now
            return false
        }
        cumulativeSettlingDuration += max(0, now - pendingSince)
        self.pendingSince = nil; lastChurnAt = nil
        resetStabilityLocked()
        return true
    }
    private func settlingBudgetAllowsLocked(at now: TimeInterval, deadline: TimeInterval) -> Bool {
        guard now.isFinite, deadline.isFinite, let pendingSince, pendingSince.isFinite,
              now >= pendingSince else { return false }
        return churnCount <= settlingPolicy.maxChurnNotifications
            && cumulativeSettlingDuration + now - pendingSince < settlingPolicy.maxSettlingDuration
            && deadline - now >= settlingPolicy.minimumCommitRunway
    }
    public func settlingSnapshot(at now: TimeInterval) -> SettlingSnapshot {
        lock.lock(); defer { lock.unlock() }
        return SettlingSnapshot(epoch: stabilityEpoch, churnCount: churnCount, revalidations: revalidations,
            duration: cumulativeSettlingDuration + (pendingSince.map { max(0, (settlingEndedAt ?? now) - $0) } ?? 0),
            readyViaSettling: committed && churnCount > 0)
    }

    /// Return true exactly once when an already committed recording fails.
    /// During preparation the caller retries instead of surfacing an error.
    @discardableResult
    public func invalidate(_ reason: Failure, expectedEpoch: UInt64? = nil, at now: TimeInterval? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return recordFailureLocked(reason, expectedEpoch: expectedEpoch, at: now) && committed
    }

    private func recordFailureLocked(_ reason: Failure, expectedEpoch: UInt64?, at now: TimeInterval?) -> Bool {
        guard failure == nil, !stopped, expectedEpoch == nil || expectedEpoch == stabilityEpoch else { return false }
        failure = reason
        if let now, now.isFinite, settlingEndedAt == nil { settlingEndedAt = now }
        return true
    }

    /// Report whether this write was accepted as a live, pre-commit failure.
    /// A late failure still uses the existing outward reason, but cannot defer.
    package func invalidateForVerification(_ reason: Failure, expectedEpoch: UInt64? = nil,
                                           at now: TimeInterval, deadline: TimeInterval) -> Bool {
        lock.withLock {
            guard recordFailureLocked(reason, expectedEpoch: expectedEpoch, at: now) else { return false }
            return !committed && now.isFinite && now < deadline
                && (pendingSince == nil || settlingBudgetAllowsLocked(at: now, deadline: deadline))
        }
    }

    public func stop(at now: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if let now, now.isFinite, settlingEndedAt == nil { settlingEndedAt = now }
    }

    public func decision(at now: TimeInterval, deadline: TimeInterval,
                         engineRunning: Bool) -> Decision {
        lock.lock(); defer { lock.unlock() }
        return decisionLocked(at: now, deadline: deadline, engineRunning: engineRunning)
    }

    /// Called on the serialized processing queue immediately before releasing
    /// pre-roll. A racing route change or cancellation wins over readiness.
    public func commit(at now: TimeInterval, deadline: TimeInterval,
                       engineRunning: Bool, expectedEpoch: UInt64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return commitLocked(at: now, deadline: deadline, engineRunning: engineRunning, expectedEpoch: expectedEpoch)
    }

    /// Sample the live clock after acquiring the lock, at the commit decision.
    package func commitBeforeDeadline(_ deadline: TimeInterval, engineRunning: Bool, expectedEpoch: UInt64,
                                      now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return commitLocked(at: now(), deadline: deadline,
                            engineRunning: engineRunning, expectedEpoch: expectedEpoch)
    }

    private func commitLocked(at now: TimeInterval, deadline: TimeInterval,
                              engineRunning: Bool, expectedEpoch: UInt64?) -> Bool {
        guard !committed, !configuring, pendingSince == nil,
              expectedEpoch == nil || expectedEpoch == stabilityEpoch,
              decisionLocked(at: now, deadline: deadline, engineRunning: engineRunning) == .ready else {
            return false
        }
        committed = true
        return true
    }

    /// After preparation, a stopped data stream must not look like a healthy
    /// recording. Silence still produces PCM and is deliberately accepted.
    /// The lifecycle watchdog feeds a failure back through invalidate(), which
    /// emits the recording interruption at most once.
    public func recordingFailure(at now: TimeInterval, engineRunning: Bool,
                                 maximumGap: TimeInterval = MicrophoneStartupGate.recordingGap) -> Failure? {
        lock.lock(); defer { lock.unlock() }
        guard committed, !stopped, failure == nil else { return nil }
        guard engineRunning else { return .engineStopped }
        guard now.isFinite, maximumGap.isFinite, maximumGap > 0,
              let lastBufferAt else { return .unstableBuffers }
        // The caller can sample now before a newer buffer acquires this lock.
        guard now >= lastBufferAt else { return nil }
        return now - lastBufferAt >= maximumGap ? .buffersInterrupted : nil
    }

    private func decisionLocked(at now: TimeInterval, deadline: TimeInterval,
                                engineRunning: Bool) -> Decision {
        if stopped { return .stopped }
        if let failure { return .failed(failure) }
        guard now.isFinite, deadline.isFinite else { return .failed(.unstableBuffers) }
        if !committed, pendingSince != nil {
            guard settlingBudgetAllowsLocked(at: now, deadline: deadline) else {
                failure = .configurationChanged
                settlingEndedAt = now
                return .failed(.configurationChanged)
            }
            return .waiting
        }
        if !engineRunning { return .failed(.engineStopped) }
        if committed { return .ready }
        if now >= deadline {
            return .failed(everReceivedBuffer ? .unstableBuffers : .noBuffers)
        }
        guard !configuring, let stableSince, let lastBufferAt,
              consecutiveBuffers >= 2, now >= lastBufferAt,
              lastBufferAt - stableSince >= stableDuration,
              now - lastBufferAt <= maximumGap else { return .waiting }
        return .ready
    }
}

/// Join all stop requests to the same asynchronous finalization. Returning a
/// second receipt before classifier/admission drain completes would report
/// incomplete health counters and could let an abandoned attempt leak PCM.
public final class MicrophoneStopLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var result: Int?
    private var callbacks: [(Int) -> Void] = []

    public init() {}

    /// Exactly one caller performs teardown. Completed receipts are replayed
    /// outside the lock, so callbacks may safely make a reentrant stop request.
    public func begin(completion: ((Int) -> Void)?) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            completion?(result)
            return false
        }
        if let completion { callbacks.append(completion) }
        let ownsTeardown = !started
        started = true
        lock.unlock()
        return ownsTeardown
    }

    public func finish(losses: Int) {
        lock.lock()
        guard started, result == nil else { lock.unlock(); return }
        result = losses
        let waiting = callbacks
        callbacks.removeAll()
        lock.unlock()
        for callback in waiting { callback(losses) }
    }
}

/// Retain retired engines while AVFAudio's private I/O listeners may still
/// reference them. All hardware operations stay on the lifecycle lane.
public final class MicrophoneEngineLifetime<Resource: AnyObject>: @unchecked Sendable {
    public struct Lease {
        public let token: UUID
        public let resource: Resource
        fileprivate let generation: Int
        fileprivate let takeID: UUID?
    }

    package enum VerificationFailure {
        case deviceResolution(MicrophoneSelectionError)
        case binding, preStartSelection, revalidationSelection, readinessSelection
    }

    package enum Purpose { case capture, continuation, warm }

    package enum AcquisitionError: Error {
        case factoryFailed, retiredEngineReturned
    }

    package enum Disposition: Equatable, Sendable {
        case normal, replacementPending, verificationDeferred, terminal

        package var message: String? {
            switch self {
            case .normal, .verificationDeferred: nil
            case .replacementPending: "マイクの入力形式が変わりました。もう一度録音を開始してください"
            case .terminal: "マイクの安全な状態を確認できません。アプリを再起動してください"
            }
        }
    }

    package enum StartHistory {
        case notCalled, calling, started

        fileprivate var diagnosticValue: String {
            switch self {
            case .notCalled: "false"
            case .calling: "unknown"
            case .started: "true"
            }
        }
    }

    package struct CleanupEvidence {
        let stopped: Bool
        let hadTap: Bool
        let removed: Bool?
        let runningAtCleanup: Bool?

        package init(stopped: Bool, hadTap: Bool, removed: Bool? = nil, runningAtCleanup: Bool? = nil) {
            self.stopped = stopped
            self.hadTap = hadTap
            self.removed = removed
            self.runningAtCleanup = runningAtCleanup
        }
    }

    private struct LeaseHistory {
        var preflightStopped = false
        var installCalled = false
        var verificationFailure: VerificationFailure?
        var start = StartHistory.notCalled
        var preCommitFormatException = false
    }

    private enum State: Equatable {
        case available, retiring(replaceable: Bool), pending, verifying, verificationDeferred(takeID: UUID?), terminal
    }

    private let lock = NSLock()
    private let makeResource: () -> Resource?
    private let telemetry: (LocalDiagnosticEvent) -> Void
    private var state = State.available
    private var resource: Resource?
    private var retired: Resource?
    private var activeToken: UUID?
    private var generation = 1
    private var cleanupStarted = false
    private var history = LeaseHistory()

    public var isQuarantined: Bool {
        lock.withLock {
            if case .verificationDeferred = state { return true }
            return state == .terminal || state == .pending || isRetiring
        }
    }

    package var disposition: Disposition {
        lock.withLock { dispositionLocked }
    }

    private var dispositionLocked: Disposition {
        switch state {
        case .pending: .replacementPending
        case .verificationDeferred: .verificationDeferred
        case .terminal: .terminal
        default: .normal
        }
    }

    private var isRetiring: Bool {
        if case .retiring = state { return true }
        return false
    }

    public func isCurrent(token: UUID) -> Bool {
        lock.withLock {
            activeToken == token && !cleanupStarted && (state == .available || state == .verifying)
        }
    }

    private func owns(_ lease: Lease) -> Bool {
        activeToken == lease.token && generation == lease.generation && resource === lease.resource
    }

    package func beginCleanup(_ lease: Lease) -> Bool {
        lock.withLock {
            guard owns(lease), !cleanupStarted else { return false }
            cleanupStarted = true
            return true
        }
    }

    package func ownsCleanup(_ lease: Lease) -> Bool {
        lock.withLock { owns(lease) && cleanupStarted }
    }

    // Hardware operations and these updates are serialized by the lifecycle lane.
    package func recordPreflightStopped(_ stopped: Bool, for lease: Lease) {
        lock.withLock {
            guard owns(lease), !cleanupStarted, !isRetiring else { return }
            history.preflightStopped = stopped
        }
    }

    package func recordInstall(for lease: Lease) {
        lock.withLock {
            guard owns(lease), !cleanupStarted else { return }
            history.installCalled = true
        }
    }

    package func isVerifying(_ lease: Lease) -> Bool {
        lock.withLock { owns(lease) && !cleanupStarted && state == .verifying }
    }

    package func recordVerificationFailure(_ cause: VerificationFailure, for lease: Lease) {
        lock.withLock {
            guard owns(lease), !cleanupStarted, state == .verifying,
                  history.verificationFailure == nil else { return }
            history.verificationFailure = cause
        }
    }

    package func recordStart(_ start: StartHistory, for lease: Lease) {
        lock.withLock {
            guard owns(lease), !cleanupStarted else { return }
            history.start = start
        }
    }

    package func needsIndependentStopReadback(_ lease: Lease, hadTap: Bool) -> Bool {
        lock.withLock {
            owns(lease) && cleanupStarted &&
                (attemptsDeferralLocked || usesRetiringStopProofLocked(hadTap: hadTap))
        }
    }

    private var attemptsDeferralLocked: Bool {
        state == .verifying && history.verificationFailure != nil
    }

    // Only the permanently retiring first generation may substitute readback
    // for the raw stop result. Reusable engines require both.
    private func usesRetiringStopProofLocked(hadTap: Bool) -> Bool {
        state == .retiring(replaceable: true) && !hadTap && history.start == .notCalled
    }

    package func retire(_ lease: Lease, preCommitFormatException: Bool) {
        lock.withLock {
            guard owns(lease), !cleanupStarted, state == .available || state == .verifying else { return }
            history.preCommitFormatException = preCommitFormatException
            state = .retiring(replaceable: generation == 1 && preCommitFormatException)
        }
    }

    public init(makeResource: @escaping () -> Resource?,
                telemetry: @escaping (LocalDiagnosticEvent) -> Void = LocalDiagnostics.record) {
        self.makeResource = makeResource
        self.telemetry = telemetry
    }

    public func acquire() -> Lease? { try? acquire(for: .warm, canAcquire: true) }

    package func acquire(for purpose: Purpose, takeID: UUID? = nil,
                         canAcquire: @autoclosure () -> Bool) throws -> Lease? {
        var telemetry: [LocalDiagnosticEvent] = []
        var wasReplacement = false
        defer { for event in telemetry { self.telemetry(event) } }
        let token = UUID()
        let reservation = try lock.withLock { () -> (accepted: Bool, existing: Lease?) in
            guard activeToken == nil, canAcquire() else { return (false, nil) }
            switch state {
            case .available: break
            case .pending where purpose == .capture:
                state = .verifying
                generation = 2
                wasReplacement = true
                telemetry.append(.micReplacementAttempt)
            case .verificationDeferred(let owner):
                guard purpose == .capture || (purpose == .continuation && takeID != nil && takeID == owner)
                else { return (false, nil) }
                guard generation == 2, let resource else {
                    state = .terminal
                    telemetry.append(.micUnrecovered)
                    throw AcquisitionError.factoryFailed
                }
                guard let retired, resource !== retired else {
                    state = .terminal
                    telemetry.append(.micUnrecovered)
                    throw AcquisitionError.retiredEngineReturned
                }
                state = .verifying
                wasReplacement = true
                history = LeaseHistory()
                activeToken = token
                return (true, Lease(token: token, resource: resource, generation: generation, takeID: takeID))
            default: return (false, nil)
            }
            history = LeaseHistory()
            activeToken = token
            return (true, nil)
        }
        guard reservation.accepted else { return nil }
        if let existing = reservation.existing { return existing }

        // The reservation rejects reentrant/concurrent acquisition while the
        // factory is outside the lock.
        let existing = lock.withLock { resource }
        let candidate = existing ?? makeResource()
        return try lock.withLock {
            do {
                guard let candidate else { throw AcquisitionError.factoryFailed }
                guard candidate !== retired else { throw AcquisitionError.retiredEngineReturned }
                resource = candidate
                return Lease(token: token, resource: candidate, generation: generation, takeID: takeID)
            } catch {
                state = .terminal
                activeToken = nil
                if wasReplacement { telemetry.append(.micUnrecovered) }
                throw error
            }
        }
    }

    package func cleanupEndsTake(_ lease: Lease) -> Bool {
        lock.withLock { owns(lease) && (isRetiring || state == .verifying) }
    }

    package func finishVerification(_ lease: Lease) {
        let recovered = lock.withLock { () -> Bool in
            guard owns(lease), state == .verifying, !cleanupStarted else { return false }
            state = .available
            return true
        }
        if recovered { telemetry(.micRecoverySuccess) }
    }

    @discardableResult package func finishCleanup(_ lease: Lease, evidence: CleanupEvidence,
                                                   record: ((String) -> Void)? = nil) -> Disposition {
        let (disposition, diagnostic, telemetry) = lock.withLock { () -> (Disposition, String?, [LocalDiagnosticEvent]) in
            var telemetry: [LocalDiagnosticEvent] = []
            guard owns(lease), cleanupStarted else { return (dispositionLocked, nil, telemetry) }
            let succeeded: Bool
            let deferring = attemptsDeferralLocked
            if deferring {
                let tapProven = evidence.hadTap
                    ? history.installCalled && evidence.removed == true
                    : !history.installCalled && history.start == .notCalled
                succeeded = evidence.stopped && evidence.runningAtCleanup == false && tapProven
            } else if usesRetiringStopProofLocked(hadTap: evidence.hadTap) {
                succeeded = history.preflightStopped && evidence.runningAtCleanup == false
            } else {
                succeeded = evidence.stopped && (!evidence.hadTap || evidence.removed == true)
            }
            switch state {
            case .retiring(let replaceable):
                if succeeded && replaceable {
                    retired = resource
                    resource = nil
                    state = .pending
                } else {
                    state = .terminal
                    // `.retiring` is only entered on a MicrophoneGraphError,
                    // never on normal take teardowns, so every transition to
                    // `.terminal` here is a permanent unrecovered failure.
                    telemetry.append(.micUnrecovered)
                }
            case .verifying:
                if deferring && succeeded {
                    state = .verificationDeferred(takeID: lease.takeID)
                    telemetry.append(.micVerificationDeferral)
                } else {
                    state = .terminal
                    telemetry.append(.micUnrecovered)
                }
            case .available where !succeeded:
                state = .terminal
                telemetry.append(.micUnrecovered)
            default: break
            }
            let disposition = dispositionLocked
            let diagnostic = record.map { _ in
                let removed = evidence.hadTap ? (evidence.removed.map { String($0) } ?? "unknown") : "not_required"
                let running = evidence.runningAtCleanup.map { String($0) } ?? "unknown"
                return "mic_cleanup_disposition generation=\(generation) preCommitFormatException=\(history.preCommitFormatException)"
                    + " hadTap=\(evidence.hadTap) engineStarted=\(history.start.diagnosticValue) stopped=\(evidence.stopped)"
                    + " removed=\(removed) preflightStopped=\(history.preflightStopped) runningAtCleanup=\(running)"
                    + " succeeded=\(succeeded) disposition=\(disposition)"
            }
            activeToken = nil
            cleanupStarted = false
            history = LeaseHistory()
            return (disposition, diagnostic, telemetry)
        }
        for event in telemetry { self.telemetry(event) }
        if let diagnostic { record?(diagnostic) }
        return disposition
    }

    /// Retained for callers that return an ordinary lease without hardware.
    @discardableResult public func release(token: UUID) -> Bool {
        lock.withLock {
            guard activeToken == token, resource != nil, state == .available, !cleanupStarted else { return false }
            activeToken = nil
            history = LeaseHistory()
            return true
        }
    }
}
