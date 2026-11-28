#if os(macOS)
import AudioToolbox
import Foundation
import KoeBridgeCore
import Synchronization

final class OutputVolumeGuard: @unchecked Sendable {
    static let snapshotWaitMilliseconds = 40
    static let preferenceKey = "outputVolumeGuardEnabled"
    let queue = DispatchQueue(label: "dev.koebridge.output-volume-guard")
    private let notifications = DispatchQueue(label: "dev.koebridge.output-volume-events")

    // Only metadata and FIFO submission go under stateLock. Snapshot reads,
    // listener management and native writes never hold this lock.
    private let stateLock = NSLock()
    private var enabled: Bool
    private var owner: UUID?
    private var attempt: UUID?
    // Both starts use the serial microphone lifecycle lane. After a timeout,
    // a warm handover need not wait a second time for the same slow read.
    private var snapshotHandoffGeneration: UInt64?
    private let generation = Atomic<UInt64>(0)
    private var snapshotGeneration: UInt64 = 0
    private var live: (() -> Bool)?

    // Guard queue only.
    private var policy: OutputVolumeGuardPolicy
    private var evidence: MicrophoneEvidenceWriter?
    private var listeners = [Property: AudioObjectPropertyListenerBlock]()
    private var retired = [Property: AudioObjectPropertyListenerBlock]()
    private var cleanup: DispatchWorkItem?
    private var cleanupDelay = 0.25
    private var lastWrite = [Property: TimeInterval]()
    private struct Control: Hashable {
        let uid: String
        let property: Property
    }
    private struct PendingWrite {
        let written: Float
        var reflected = false
        var lower: Float?

        mutating func observe(_ value: Float) {
            guard (0...1).contains(value) else { return }
            if value == written { reflected = true }
            if value < written { lower = min(lower ?? value, value) }
        }
    }
    // Guard and HAL notification lanes share outstanding observations. There is
    // no time limit on HAL reflection. A debounce wakeup is never a receipt.
    private var pending = [Control: PendingWrite]() // observationLock
    private var trailing: DispatchWorkItem?

    struct Hardware {
        typealias Listen = (UInt32, inout AudioObjectPropertyAddress, DispatchQueue,
                            @escaping AudioObjectPropertyListenerBlock) -> OSStatus
        var defaultDevice = MicrophoneRouteSnapshot.defaultOutputObject
        var sample = OutputVolumeHAL.sample
        var finalReads = OutputVolumeHAL.FinalReads()
        var scalar = OutputVolumeHAL.scalar
        var set = OutputVolumeHAL.set
        var add: Listen = { AudioObjectAddPropertyListenerBlock($0, &$1, $2, $3) }
        var remove: Listen = { AudioObjectRemovePropertyListenerBlock($0, &$1, $2, $3) }
    }

    private let hardware: Hardware
    init(enabled: Bool, hardware: Hardware = Hardware()) {
        self.hardware = hardware
        self.enabled = enabled
        policy = OutputVolumeGuardPolicy(enabled: enabled)
    }

    private struct Property: Hashable {
        let device: AudioObjectID
        let selector: UInt32
        let scope: UInt32
        let element: UInt32
        init(_ device: UInt32, _ address: AudioObjectPropertyAddress) {
            self.device = device
            selector = address.mSelector
            scope = address.mScope
            element = address.mElement
        }
        var address: AudioObjectPropertyAddress { OutputVolumeHAL.address(selector, element, scope: scope) }
    }

    private func permits(_ epoch: UInt64) -> Bool {
        let isLive = stateLock.withLock { enabled ? live : nil }
        return generation.load(ordering: .sequentiallyConsistent) == epoch && isLive?() == true
    }

    private func snapshot(_ session: UInt64, device: () -> UInt32?, writer: MicrophoneEvidenceWriter?) -> OutputVolumeReading? {
        guard stateLock.withLock({ enabled && owner != nil && snapshotGeneration == session }) else { return nil }
        let result = device().flatMap { $0 == kAudioObjectUnknown ? nil : hardware.sample($0, true)?.reading }
        if result?.maximum == nil { writer?.enqueue("output_volume_guard inert=snapshot_unavailable") }
        return result
    }

    func changePreference(_ value: Bool, evidence: MicrophoneEvidenceWriter?) {
        stateLock.withLock {
            guard enabled != value else { return }
            enabled = value
            snapshotGeneration &+= 1
            let session = snapshotGeneration
            let epoch = generation.wrappingAdd(1, ordering: .sequentiallyConsistent).newValue
            queue.async { [self] in
                resetMonitoring(clearDebounce: false)
                self.evidence = evidence
                policy.setEnabled(value) {
                    permits(epoch) ? snapshot(session, device: hardware.defaultDevice, writer: evidence) : nil
                }
                evaluate(epoch)
            }
        }
    }

    func begin(_ id: UUID, attempt attemptID: UUID? = nil, device: @escaping () -> UInt32?,
               evidence: MicrophoneEvidenceWriter?, startupDeadline: TimeInterval? = nil,
               live isLive: @escaping () -> Bool = { true }) {
        // Budget queueing and the actual read together. On timeout capture is
        // allowed to start; its first successful read can then be post-switch.
        let deadline = DispatchTime.now() + .milliseconds(Self.snapshotWaitMilliseconds)
        let ready: DispatchSemaphore? = stateLock.withLock {
            guard isLive() else { return nil }
            let previous = owner
            if previous != id { snapshotGeneration &+= 1 }
            let session = snapshotGeneration
            let hasTime = startupDeadline.map {
                $0 - ProcessInfo.processInfo.systemUptime >= Double(Self.snapshotWaitMilliseconds) / 1_000
            } ?? true
            let ready = enabled && snapshotHandoffGeneration != session && hasTime ? DispatchSemaphore(value: 0) : nil
            if ready != nil { snapshotHandoffGeneration = session }
            owner = id
            attempt = attemptID ?? id
            live = isLive
            let epoch = generation.wrappingAdd(1, ordering: .sequentiallyConsistent).newValue
            queue.async { [self] in
                if let previous, previous != id { policy.end(previous) }
                self.evidence = evidence
                policy.begin(id) { snapshot(session, device: device, writer: evidence) }
                stateLock.withLock {
                    if snapshotGeneration == session {
                        snapshotHandoffGeneration = policy.snapshot == nil ? nil : session
                    }
                }
                ready?.signal() // HAL listener management and writes are outside the handoff
                resetMonitoring(clearDebounce: previous != id)
                evaluate(epoch)
            }
            return ready
        }
        guard let ready, ready.wait(timeout: .now()) == .timedOut else { return }
        // macOS may coalesce an ordinary semaphore timeout. Request a strict
        // wakeup at the same absolute deadline; scheduling the timer cannot
        // extend that deadline, even if its delivery queue is busy.
        let timeout = DispatchSource.makeTimerSource(flags: .strict, queue: .global(qos: .userInteractive))
        timeout.schedule(deadline: deadline, leeway: .nanoseconds(0))
        timeout.setEventHandler { ready.signal() }
        timeout.activate()
        _ = ready.wait(timeout: deadline)
        timeout.cancel()
    }

    func handover(from warm: UUID, to take: UUID, attempt attemptID: UUID? = nil,
                  live isLive: @escaping () -> Bool = { true }) {
        stateLock.withLock {
            guard owner == warm, isLive() else { return }
            owner = take
            attempt = attemptID ?? take
            live = isLive
            let epoch = generation.wrappingAdd(1, ordering: .sequentiallyConsistent).newValue
            queue.async { [self] in
                resetMonitoring(clearDebounce: false)
                policy.handover(from: warm, to: take)
                evaluate(epoch)
            }
        }
    }

    /// Retry gaps have no write authority, but retain the logical take's snapshot.
    func pause(_ id: UUID, attempt attemptID: UUID) {
        stateLock.withLock {
            guard owner == id, attempt == attemptID else { return }
            attempt = nil
            live = nil
            generation.wrappingAdd(1, ordering: .sequentiallyConsistent)
            queue.async { [self] in resetMonitoring(clearDebounce: false) }
        }
    }

    func end(_ id: UUID) {
        stateLock.withLock {
            guard owner == id else { return }
            owner = nil
            snapshotGeneration &+= 1
            attempt = nil
            live = nil
            generation.wrappingAdd(1, ordering: .sequentiallyConsistent)
            queue.async { [self] in
                policy.end(id)
                evidence = nil
                resetMonitoring()
            }
        }
    }

    private func resetMonitoring(clearDebounce: Bool = true) {
        updateListeners([], epoch: 0)
        trailing?.cancel()
        trailing = nil
        if clearDebounce {
            observationLock.withLock { pending.removeAll() }
            lastWrite.removeAll()
        }
    }

    func check() {
        stateLock.withLock {
            guard enabled, live?() == true else { return }
            let epoch = generation.load(ordering: .sequentiallyConsistent)
            queue.async { [self] in evaluate(epoch) }
        }
    }

    private func evaluate(_ epoch: UInt64) {
        guard permits(epoch), policy.isMonitoring else { return }
        defer {
            if observationLock.withLock({ !pending.isEmpty }), permits(epoch) {
                scheduleCheck(after: 0.25, epoch: epoch)
            }
        }
        var wanted: Set<Property> = [Property(AudioObjectID(kAudioObjectSystemObject),
            OutputVolumeHAL.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal))]
        guard let device = hardware.defaultDevice() else {
            updateListeners(wanted.union(listeners.keys), epoch: epoch)
            return
        }
        guard device != kAudioObjectUnknown else {
            policy.disconnected()
            updateListeners(wanted, epoch: epoch)
            return
        }
        wanted.insert(Property(device, OutputVolumeHAL.address(kAudioDevicePropertyStreamConfiguration)))
        wanted.insert(Property(device, OutputVolumeHAL.address(.virtualMain)))
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            wanted.insert(Property(device, OutputVolumeHAL.address(selector, kAudioObjectPropertyElementWildcard)))
        }
        guard let current = hardware.sample(device, false) else {
            updateListeners(wanted, epoch: epoch)
            return
        }
        for element in current.reading.volumes.keys {
            wanted.insert(Property(device, OutputVolumeHAL.address(element)))
        }
        guard permits(epoch) else { return }
        updateListeners(wanted, epoch: epoch)
        var writes = policy.corrections(for: current.reading, settable: current.settable)
        for (element, value) in current.reading.volumes {
            let key = Control(uid: current.reading.uid, property: Property(device, OutputVolumeHAL.address(element)))
            guard let outstanding = readPending(key, sampled: value) else { continue }
            writes.removeValue(forKey: element)
            if outstanding.reflected, let lower = outstanding.lower, value > lower,
               !current.reading.muted, current.settable.contains(element) {
                writes[element] = lower
            }
        }
        for element in writes.keys.sorted(by: { Self.order($0) < Self.order($1) }) {
            guard permits(epoch), let ceiling = writes[element] else { return }
            let key = Property(device, OutputVolumeHAL.address(element))
            let now = ProcessInfo.processInfo.systemUptime
            if let previous = lastWrite[key], now - previous < 0.25 {
                scheduleCheck(after: 0.25 - (now - previous), epoch: epoch)
                continue
            }
            do {
                if let receipt = try write(current.reading, element: element, ceiling: ceiling, epoch: epoch) {
                    if receipt.reflected, let lower = receipt.lower {
                        _ = try write(current.reading, element: element, ceiling: lower, epoch: epoch)
                    }
                }
            } catch {
                lastWrite[key] = ProcessInfo.processInfo.systemUptime
                scheduleCheck(after: 0.25, epoch: epoch)
            }
        }
    }

    // HAL notifications contain addresses, not values. A separate delivery
    // queue can sample a lowering while the setter is executing on our queue.
    private let observationLock = NSLock()
    private struct Window {
        let key: Property
        let ceiling: Float
        let epoch: UInt64
        var lower: Float?
        var invalidated = false
    }
    private var window: Window?

    // A lower value read during a delayed write remains attached to that
    // device/element through retries, temporary mute, disconnect and handover.
    // Once the requested write has reflected, either a lower readback is
    // already safe or the witnessed lower value becomes the only write target.
    private func readPending(_ key: Control, sampled: Float? = nil) -> PendingWrite? {
        observationLock.withLock {
            guard var record = pending[key] else { return nil }
            if let sampled { record.observe(sampled) }
            guard let value = try? hardware.scalar(key.property.device, key.property.address) else {
                pending[key] = record
                return record
            }
            record.observe(value)
            if record.reflected && (record.lower.map { value <= $0 } ?? true) {
                pending.removeValue(forKey: key)
                return nil
            }
            pending[key] = record
            return record
        }
    }

    private func observe(_ device: UInt32, addresses: UnsafeBufferPointer<AudioObjectPropertyAddress>, epoch: UInt64) {
        observationLock.withLock {
            let w = window
            if let w, w.epoch == epoch, addresses.contains(where: { address in
                (device == kAudioObjectSystemObject && address.mSelector == kAudioHardwarePropertyDefaultOutputDevice)
                    || (device == w.key.device && (address.mSelector == kAudioDevicePropertyMute
                        || address.mSelector == kAudioDevicePropertyStreamConfiguration))
            }) { window?.invalidated = true }

            for address in addresses {
                let property = Property(device, address)
                let inWindow = w?.epoch == epoch && w?.key == property
                guard inWindow || pending.keys.contains(where: { $0.property == property }),
                      let uid = hardware.finalReads.uid(device),
                      let value = try? hardware.scalar(device, address), (0...1).contains(value) else { continue }
                let key = Control(uid: uid, property: property)
                pending[key]?.observe(value)
                if inWindow, let w, value < w.ceiling { window?.lower = min(w.lower ?? value, value) }
            }
        }
    }

    // The final atomic load is the start of a write. It and every invalidating
    // increment have a single total order. Invalidation never drains a passed
    // gate; that Set may complete later. HAL has no conditional Set for an
    // external change that neither a listener nor a readback observes.
    private func submit(_ key: Control, value: Float, epoch: UInt64,
                        perform: () throws -> Void) throws -> Bool {
        guard permits(epoch) else { return false }
        let old: PendingWrite?
        do {
            guard observationLock.try() else { return false }
            defer { observationLock.unlock() }
            guard window?.invalidated == false, window?.lower == nil else { return false }
            old = pending[key]
            if let old {
                guard old.reflected, let lower = old.lower, value <= lower else { return false }
            }
            pending[key] = PendingWrite(written: value)
        }

        func rollBackPendingWrite(setFailed: Bool) {
            observationLock.withLock {
                let witnessed = pending[key]?.lower
                pending[key] = old
                if let witnessed {
                    if old == nil && setFailed { pending[key] = PendingWrite(written: value, reflected: true) }
                    pending[key]?.observe(witnessed)
                }
            }
        }

        guard generation.load(ordering: .sequentiallyConsistent) == epoch else {
            rollBackPendingWrite(setFailed: false)
            return false
        }
        do {
            try perform()
            return true
        } catch {
            rollBackPendingWrite(setFailed: true)
            throw error
        }
    }

    private func write(_ reading: OutputVolumeReading, element: OutputVolumeElement,
                       ceiling: Float, epoch: UInt64) throws -> PendingWrite? {
        let property = OutputVolumeHAL.address(element)
        let key = Control(uid: reading.uid, property: Property(reading.device, property))
        observationLock.withLock { window = Window(key: key.property, ceiling: ceiling, epoch: epoch) }
        defer { observationLock.withLock { window = nil } }
        var verifiedValue: Float?
        let submitted = try hardware.set(reading.device, property, ceiling) { perform in
            guard self.permits(epoch),
                  let value = try OutputVolumeHAL.finalValue(reading, element, reads: self.hardware.finalReads) else { return false }
            self.observationLock.withLock { self.pending[key]?.observe(value) }
            guard value > ceiling else { return false }
            verifiedValue = value
            return try self.submit(key, value: ceiling, epoch: epoch, perform: perform)
        }
        guard submitted, let before = verifiedValue else { return nil }
        lastWrite[key.property] = ProcessInfo.processInfo.systemUptime
        LocalDiagnostics.record(.volumeGuardActivation)
        evidence?.enqueue("output_volume_guard device=\(reading.device) element=\(element) from=\(before) to=\(ceiling)")
        return readPending(key)
    }

    private static func order(_ element: OutputVolumeElement) -> UInt64 {
        switch element {
        case .virtualMain: return UInt64.max
        case .scalar(0): return UInt64.max - 1
        case .scalar(let channel): return UInt64(channel)
        }
    }

    private func scheduleCheck(after delay: TimeInterval, epoch: UInt64) {
        guard trailing == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.trailing = nil
            self?.evaluate(epoch)
        }
        trailing = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func updateListeners(_ wanted: Set<Property>, epoch: UInt64) {
        for key in Set(listeners.keys).subtracting(wanted) {
            retired[key] = listeners.removeValue(forKey: key)
        }
        retryRemovals()
        for key in wanted where listeners[key] == nil && retired[key] == nil {
            var address = key.address
            let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
                guard let self, self.permits(epoch) else { return }
                self.observe(key.device, addresses: UnsafeBufferPointer(start: addresses, count: Int(count)), epoch: epoch)
                self.queue.async { [weak self] in self?.evaluate(epoch) }
            }
            if hardware.add(key.device, &address, notifications, block) == noErr { listeners[key] = block }
        }
    }

    private func retryRemovals() {
        for (key, block) in retired {
            var address = key.address
            let status = hardware.remove(key.device, &address, notifications, block)
            if status == noErr || status == kAudioHardwareBadObjectError { retired.removeValue(forKey: key) }
        }
        if retired.isEmpty {
            cleanup?.cancel()
            cleanup = nil
            cleanupDelay = 0.25
        } else if cleanup == nil {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                cleanup = nil
                retryRemovals()
                check() // rebind supported properties after an old registration finally retired
            }
            cleanup = item
            queue.asyncAfter(deadline: .now() + cleanupDelay, execute: item)
            cleanupDelay = min(8, cleanupDelay * 2)
        }
    }
}
#endif
