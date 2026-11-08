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
        guard completedAttempts > 0, completedAttempts < maximumAttempts else { return nil }
        let delay = min(0.8, 0.2 * Double(completedAttempts))
        guard remaining(at: elapsed) > delay else { return nil }
        return delay
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

    private let lock = NSLock()
    private let stableDuration: TimeInterval
    private let maximumGap: TimeInterval
    private var firstBufferAt: TimeInterval?
    private var lastBufferAt: TimeInterval?
    private var stableSince: TimeInterval?
    private var consecutiveBuffers = 0
    private var failure: Failure?
    private var committed = false
    private var stopped = false

    public init(stableDuration: TimeInterval = 0.15,
                maximumGap: TimeInterval = 0.35) {
        precondition(stableDuration.isFinite && stableDuration >= 0)
        precondition(maximumGap.isFinite && maximumGap > stableDuration)
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
        return failure == nil && (committed || !stopped)
    }

    public var firstBufferTime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return firstBufferAt
    }

    public func observeConvertedBuffer(frames: Int, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard frames > 0, now.isFinite, failure == nil, !stopped else { return }
        if let last = lastBufferAt, now < last { return }
        if firstBufferAt == nil { firstBufferAt = now }
        if let last = lastBufferAt, now - last <= maximumGap {
            consecutiveBuffers += 1
        } else {
            consecutiveBuffers = 1
            stableSince = now
        }
        lastBufferAt = now
    }

    /// Return true exactly once when an already committed recording fails.
    /// During preparation the caller retries instead of surfacing an error.
    @discardableResult
    public func invalidate(_ reason: Failure) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil, !stopped else { return false }
        failure = reason
        return committed
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
    }

    public func decision(at now: TimeInterval, deadline: TimeInterval,
                         engineRunning: Bool) -> Decision {
        lock.lock(); defer { lock.unlock() }
        return decisionLocked(at: now, deadline: deadline, engineRunning: engineRunning)
    }

    /// Called on the serialized processing queue immediately before releasing
    /// pre-roll. A racing route change or cancellation wins over readiness.
    public func commit(at now: TimeInterval, deadline: TimeInterval,
                       engineRunning: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !committed,
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
                                 maximumGap: TimeInterval = 1.0) -> Failure? {
        lock.lock(); defer { lock.unlock() }
        guard committed, !stopped, failure == nil else { return nil }
        guard engineRunning else { return .engineStopped }
        guard now.isFinite, maximumGap.isFinite, maximumGap > 0,
              let lastBufferAt, now >= lastBufferAt else { return .unstableBuffers }
        return now - lastBufferAt >= maximumGap ? .buffersInterrupted : nil
    }

    private func decisionLocked(at now: TimeInterval, deadline: TimeInterval,
                                engineRunning: Bool) -> Decision {
        if stopped { return .stopped }
        if let failure { return .failed(failure) }
        guard now.isFinite, deadline.isFinite else { return .failed(.unstableBuffers) }
        if !engineRunning { return .failed(.engineStopped) }
        if committed { return .ready }
        if now >= deadline {
            return .failed(firstBufferAt == nil ? .noBuffers : .unstableBuffers)
        }
        guard let stableSince, let lastBufferAt,
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

/// Own one audio engine for the lifetime of this owner, independently of a
/// recording attempt. The macOS caller keeps this owner in a process-wide static.
/// Releasing a lease NEVER releases the resource: AVFAudio's asynchronous I/O
/// property listeners may still be handling a route change after engine.stop().
/// This is bounded (one engine), not a timer-based quarantine or an engine pool.
/// Engine operations themselves must remain on the microphone lifecycle queue.
public final class MicrophoneEngineLifetime<Resource: AnyObject>: @unchecked Sendable {
    public struct Lease {
        public let token: UUID
        public let resource: Resource
        fileprivate init(token: UUID, resource: Resource) {
            self.token = token
            self.resource = resource
        }
    }

    private let lock = NSLock()
    private let makeResource: () -> Resource
    private var resource: Resource?
    private var activeToken: UUID?

    public init(makeResource: @escaping () -> Resource) {
        self.makeResource = makeResource
    }

    /// A caller must stop its engine, remove its tap and drain queued conversion
    /// work before release. A simultaneous start fails closed instead of stealing
    /// an engine still owned by another attempt. Creation is lazy and exactly once.
    public func acquire() -> Lease? {
        lock.lock(); defer { lock.unlock() }
        guard activeToken == nil else { return nil }
        let retained: Resource
        if let resource { retained = resource }
        else {
            retained = makeResource()
            resource = retained
        }
        let token = UUID()
        activeToken = token
        return Lease(token: token, resource: retained)
    }

    /// Tokens prevent a late stop from returning a newer take's lease.
    /// A successful return is NOT permission to deallocate the resource.
    @discardableResult public func release(token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard activeToken == token else { return false }
        activeToken = nil
        return true
    }
}
