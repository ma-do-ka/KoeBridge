import Foundation

/// Bounded, opt-in evidence only. This object NEVER changes capture decisions,
/// queries hardware, reads audio samples, or logs device names/UIDs or text.
/// The tap updates counters only; formatting and file I/O belong to the sink.
public final class MicrophonePreparationDiagnostics: @unchecked Sendable {
    public static let maximumEvents = 128
    public enum Stage: String, Sendable {
        case requested, lifecycle, deviceList = "device_list", selection
        case routeSnapshot = "route_snapshot", engineLease = "engine_lease"
        case inputNode = "input_node", deviceBefore = "device_before"
        case deviceSet = "device_set", deviceAfter = "device_after"
        case formats, converter, tapInstall = "tap_install"
        case enginePrepare = "engine_prepare", engineStart = "engine_start"
        case awaitPCM = "await_pcm", ready, startFailed = "start_failed"
        case configurationChanged = "configuration_changed"
        case inputRouteChanged = "input_route_changed", formatChanged = "format_changed"
        case conversionFailed = "conversion_failed", bufferDropped = "buffer_dropped"
        case startupBufferOverflow = "startup_buffer_overflow", engineStopped = "engine_stopped"
        case noBuffers = "no_buffers", buffersInterrupted = "buffers_interrupted"
        case unstableBuffers = "unstable_buffers", stopRequested = "stop_requested"
        case stopGate = "stop_gate", engineStop = "engine_stop", tapRemove = "tap_remove"
        case processingDrain = "processing_drain", leaseRelease = "lease_release"
        case classifierFinish = "classifier_finish", stopped
    }
    public enum Kind: String, Sendable { case begin, end, note, waiting }
    public struct Entry: Sendable {
        public let sequence: Int
        public let elapsedMS: Int
        public let stage: Stage
        public let kind: Kind
        public let pending: Bool
        public let stageMS: Int
        public let code: Int?
        public let matched: Bool?
        public let inputBuffers: Int
        public let convertedBuffers: Int
        public let discardedStartupMS: Int
        public let zeroStartupBuffers: Int
        public let inputRate: Int
        public let inputChannels: Int
        public let firstBufferMS: Int?
        public let lastBufferAgeMS: Int?
        public var rendered: String {
            var fields = ["seq=\(sequence)", "t_ms=\(elapsedMS)", "stage=\(stage.rawValue)",
                          "event=\(kind.rawValue)", "pending=\(pending ? 1 : 0)", "stage_ms=\(stageMS)",
                          "input_buffers=\(inputBuffers)", "converted_buffers=\(convertedBuffers)",
                          "discarded_startup_ms=\(discardedStartupMS)", "zero_startup_buffers=\(zeroStartupBuffers)",
                          "input_rate=\(inputRate)", "input_channels=\(inputChannels)"]
            if let code { fields.append("code=\(code)") }
            if let matched { fields.append("matches=\(matched ? 1 : 0)") }
            if let firstBufferMS { fields.append("first_buffer_ms=\(firstBufferMS)") }
            if let lastBufferAgeMS { fields.append("last_buffer_age_ms=\(lastBufferAgeMS)") }
            return fields.joined(separator: " ")
        }
    }
    private let lock = NSLock()
    private let clock: @Sendable () -> TimeInterval
    private let sink: @Sendable (Entry) -> Void
    private let beganAt: TimeInterval
    private var stage: Stage = .requested
    private var stageAt: TimeInterval
    private var pending = false
    private var sequence = 0
    private var inputBuffers = 0
    private var convertedBuffers = 0
    private var discardedStartupMS = 0
    private var zeroStartupBuffers = 0
    private var inputRate = 0
    private var inputChannels = 0
    private var firstAt: TimeInterval?
    private var lastAt: TimeInterval?
    private var closed = false
    private var noted = Set<Stage>()

    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sink: @escaping @Sendable (Entry) -> Void) {
        self.clock = clock; self.sink = sink
        let now = clock(); beganAt = now; stageAt = now
    }
    public func begin(_ stage: Stage) { emit(stage, kind: .begin) }
    public func end(_ stage: Stage, code: Int? = nil, matched: Bool? = nil) {
        emit(stage, kind: .end, code: code, matched: matched)
    }
    /// Notifications must not hide the OS call currently blocking the lifecycle lane.
    public func note(_ stage: Stage, code: Int? = nil) {
        emit(stage, kind: .note, code: code, once: true)
    }
    public func poll() { emit(nil, kind: .waiting) }
    public func finish() { emit(.stopped, kind: .end, finish: true) }

    /// Real-time callback: no task creation, strings, sink calls, or sample inspection.
    public func observeInput(frames: Int, at now: TimeInterval) {
        guard frames > 0, now.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if inputBuffers < Int.max { inputBuffers += 1 }
        if firstAt == nil { firstAt = now }
        if now >= (lastAt ?? now) { lastAt = now }
    }
    public func observeConverted(frames: Int) {
        guard frames > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if !closed, convertedBuffers < Int.max { convertedBuffers += 1 }
    }
    /// Conversion-queue measurements only; neither method inspects PCM or emits events.
    public func observeStartupBuffer(isExactlyZero: Bool) {
        lock.lock(); defer { lock.unlock() }
        if !closed, isExactlyZero, zeroStartupBuffers < Int.max { zeroStartupBuffers += 1 }
    }
    public func discardStartup(duration: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        discardedStartupMS = Self.milliseconds(duration)
    }
    public func format(sampleRate: Double, channels: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        inputRate = sampleRate.isFinite && sampleRate >= 0 && sampleRate <= 1_000_000
            ? Int(sampleRate.rounded()) : -1
        inputChannels = Int(channels)
    }
    private static func milliseconds(_ duration: TimeInterval) -> Int {
        guard duration.isFinite else { return -1 }
        return Int(min(86_400_000, max(0, duration * 1_000)))
    }
    private func emit(_ requested: Stage?, kind: Kind, code: Int? = nil,
                      matched: Bool? = nil, once: Bool = false, finish: Bool = false) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if finish { closed = true }
        guard sequence < Self.maximumEvents else { lock.unlock(); return }
        let now = clock()
        let eventStage = requested ?? stage
        if once && !noted.insert(eventStage).inserted { lock.unlock(); return }
        if kind == .begin { stage = eventStage; stageAt = now; pending = true }
        else if kind == .end && eventStage == stage { pending = false }
        sequence += 1
        let entry = Entry(sequence: sequence, elapsedMS: Self.milliseconds(now - beganAt),
                          stage: eventStage, kind: kind, pending: pending,
                          stageMS: Self.milliseconds(now - stageAt), code: code, matched: matched,
                          inputBuffers: inputBuffers, convertedBuffers: convertedBuffers,
                          discardedStartupMS: discardedStartupMS, zeroStartupBuffers: zeroStartupBuffers,
                          inputRate: inputRate, inputChannels: inputChannels,
                          firstBufferMS: firstAt.map { Self.milliseconds($0 - beganAt) },
                          lastBufferAgeMS: lastAt.map { Self.milliseconds(now - $0) })
        lock.unlock()
        // A sink may be reentrant. Sequence numbers preserve event order when
        // asynchronous main-actor writes are scheduled in a different order.
        sink(entry)
    }
}
