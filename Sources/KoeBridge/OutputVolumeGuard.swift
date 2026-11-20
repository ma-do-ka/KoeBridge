#if os(macOS)
import AudioToolbox
import Foundation
import KoeBridgeCore

final class OutputVolumeGuard: @unchecked Sendable {
    static let preferenceKey = "outputVolumeGuardEnabled"
    let queue = DispatchQueue(label: "dev.koebridge.output-volume-guard")
    private let notifications = DispatchQueue(label: "dev.koebridge.output-volume-events")

    // Only metadata and FIFO submission go under stateLock. No HAL call can
    // hold up a lifecycle checkpoint, cancellation or preference change.
    private let stateLock = NSLock()
    private var enabled: Bool
    private var owner: UUID?
    private var attempt: UUID?
    private var generation: UInt64 = 0
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
    private struct Repair {
        let uid: String
        let device: UInt32
        let written: Float
        let acknowledged: Bool
        let acknowledgeBy: TimeInterval
        let lowered: Float
    }
    private var repairs = [OutputVolumeElement: Repair]()
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
        stateLock.withLock { generation == epoch && enabled && live?() == true }
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
            generation &+= 1
            let epoch = generation
            queue.async { [self] in
                resetMonitoring()
                self.evidence = evidence
                policy.setEnabled(value) {
                    permits(epoch) ? snapshot(session, device: hardware.defaultDevice, writer: evidence) : nil
                }
                evaluate(epoch)
            }
        }
    }

    func begin(_ id: UUID, attempt attemptID: UUID? = nil, device: @escaping () -> UInt32?,
               evidence: MicrophoneEvidenceWriter?, live isLive: @escaping () -> Bool = { true }) {
        stateLock.withLock {
            guard isLive() else { return }
            let previous = owner
            if previous != id { snapshotGeneration &+= 1 }
            let session = snapshotGeneration
            owner = id
            attempt = attemptID ?? id
            live = isLive
            generation &+= 1
            let epoch = generation
            queue.async { [self] in
                resetMonitoring(clearDebounce: previous != id)
                if let previous, previous != id { policy.end(previous) }
                self.evidence = evidence
                policy.begin(id) { snapshot(session, device: device, writer: evidence) }
                evaluate(epoch)
            }
        }
    }

    func handover(from warm: UUID, to take: UUID) {
        stateLock.withLock {
            guard owner == warm else { return }
            owner = take
            attempt = nil
            live = nil
            generation &+= 1
            queue.async { [self] in
                resetMonitoring(clearDebounce: false)
                policy.handover(from: warm, to: take)
            }
        }
    }

    /// Retry gaps have no write authority, but retain the logical take's snapshot.
    func pause(_ id: UUID, attempt attemptID: UUID) {
        stateLock.withLock {
            guard owner == id, attempt == attemptID else { return }
            attempt = nil
            live = nil
            generation &+= 1
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
            generation &+= 1
            queue.async { [self] in
                policy.end(id)
                resetMonitoring()
            }
        }
    }

    private func resetMonitoring(clearDebounce: Bool = true) {
        updateListeners([], epoch: 0)
        trailing?.cancel()
        trailing = nil
        repairs.removeAll()
        if clearDebounce { lastWrite.removeAll() }
        evidence = nil
    }

    func check() {
        stateLock.withLock {
            guard enabled, live?() == true else { return }
            let epoch = generation
            queue.async { [self] in evaluate(epoch) }
        }
    }

    private func evaluate(_ epoch: UInt64) {
        guard permits(epoch), policy.isMonitoring else { return }
        var wanted: Set<Property> = [Property(AudioObjectID(kAudioObjectSystemObject),
            OutputVolumeHAL.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal))]
        guard let device = hardware.defaultDevice() else {
            updateListeners(wanted.union(listeners.keys), epoch: epoch)
            return
        }
        guard device != kAudioObjectUnknown else {
            repairs.removeAll()
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
        // Keep a witnessed lowering through a delayed HAL acknowledgement or a
        // failed repair. Any other readback, route or mute invalidates the claim.
        for (element, repair) in repairs {
            guard repair.device == device, repair.uid == current.reading.uid, !current.reading.muted,
                  current.settable.contains(element), let value = current.reading.volumes[element] else {
                repairs.removeValue(forKey: element)
                continue
            }
            if value == repair.written {
                writes[element] = repair.lowered
            } else if !repair.acknowledged, value > repair.written,
                      ProcessInfo.processInfo.systemUptime < repair.acknowledgeBy {
                writes.removeValue(forKey: element)
                scheduleCheck(after: max(0, repair.acknowledgeBy - ProcessInfo.processInfo.systemUptime), epoch: epoch)
            } else { repairs.removeValue(forKey: element) }
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
                let pending = repairs[element]
                let witnessed = try write(current.reading, element: element, ceiling: ceiling,
                                          expected: pending?.written, epoch: epoch)
                repairs[element] = witnessed
                if let witnessed, witnessed.acknowledged {
                    // One immediate reconciliation, with a fresh final check.
                    // Further contention or a HAL error goes through the debounce.
                    repairs[element] = try write(current.reading, element: element, ceiling: witnessed.lowered,
                                                 expected: witnessed.written, epoch: epoch)
                }
                if repairs[element] != nil { scheduleCheck(after: 0.25, epoch: epoch) }
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

    private func observe(_ device: UInt32, addresses: UnsafeBufferPointer<AudioObjectPropertyAddress>, epoch: UInt64) {
        observationLock.withLock {
            guard let w = window, w.epoch == epoch else { return }
            if addresses.contains(where: { address in
                (device == kAudioObjectSystemObject && address.mSelector == kAudioHardwarePropertyDefaultOutputDevice)
                    || (device == w.key.device && (address.mSelector == kAudioDevicePropertyMute
                        || address.mSelector == kAudioDevicePropertyStreamConfiguration))
            }) {
                window?.invalidated = true
                return
            }
            guard device == w.key.device, addresses.contains(where: { Property(device, $0) == w.key }),
                  let value = try? hardware.scalar(device, w.key.address),
                  (0..<w.ceiling).contains(value) else { return }
            window?.lower = value
        }
    }

    /// Skip a contested observation instead of waiting between final reads and
    /// syscall admission. The listener submits another check after sampling.
    private func admitSet(_ epoch: UInt64) -> Bool {
        guard observationLock.try() else { return false }
        defer { observationLock.unlock() }
        return window?.invalidated == false && window?.lower == nil && permits(epoch)
    }

    private func write(_ reading: OutputVolumeReading, element: OutputVolumeElement,
                       ceiling: Float, expected: Float?, epoch: UInt64) throws -> Repair? {
        let property = OutputVolumeHAL.address(element)
        let key = Property(reading.device, property)
        observationLock.withLock { window = Window(key: key, ceiling: ceiling, epoch: epoch) }
        defer { observationLock.withLock { window = nil } }
        var verifiedValue: Float?
        let submitted = try hardware.set(reading.device, property, ceiling) {
            guard self.permits(epoch),
                  let value = try OutputVolumeHAL.finalValue(reading, element, reads: self.hardware.finalReads),
                  value > ceiling, expected == nil || expected == value else { return false }
            verifiedValue = value
            return self.admitSet(epoch)
        }
        guard submitted, let before = verifiedValue else { return nil }
        lastWrite[key] = ProcessInfo.processInfo.systemUptime
        evidence?.enqueue("output_volume_guard device=\(reading.device) element=\(element) from=\(before) to=\(ceiling)")
        let after = try? hardware.scalar(reading.device, property)
        if let after, after < ceiling { return nil }
        return observationLock.withLock {
            guard let lower = window?.lower, window?.invalidated == false else { return nil }
            return Repair(uid: reading.uid, device: reading.device, written: ceiling, acknowledged: after == ceiling,
                          acknowledgeBy: ProcessInfo.processInfo.systemUptime + 0.25, lowered: lower)
        }
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
