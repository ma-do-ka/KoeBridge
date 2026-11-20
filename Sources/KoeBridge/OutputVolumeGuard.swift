#if os(macOS)
import AudioToolbox
import Foundation
import KoeBridgeCore

/// All calls, listener deliveries and trailing debounce checks share the microphone
/// lifecycle queue. Meeting captures do not acquire an owner.
final class OutputVolumeGuard: @unchecked Sendable {
    static let preferenceKey = "outputVolumeGuardEnabled"
    private let queue = MicrophoneCapture.warmLifecycleQueue
    private var policy: OutputVolumeGuardPolicy
    private var evidence: MicrophoneEvidenceWriter?
    private var listeners = [Property: AudioObjectPropertyListenerBlock]()
    private var lastWrite = [Property: TimeInterval]()
    private var trailing: DispatchWorkItem?

    struct Hardware {
        typealias Listen = (UInt32, inout AudioObjectPropertyAddress, DispatchQueue,
                            @escaping AudioObjectPropertyListenerBlock) -> OSStatus
        var defaultDevice = MicrophoneRouteSnapshot.defaultOutputObject
        var sample = OutputVolumeHAL.sample
        var lower = OutputVolumeHAL.lower
        var add: Listen = { AudioObjectAddPropertyListenerBlock($0, &$1, $2, $3) }
        var remove: Listen = { AudioObjectRemovePropertyListenerBlock($0, &$1, $2, $3) }
    }

    private let hardware: Hardware
    init(enabled: Bool, hardware: Hardware = Hardware()) {
        self.hardware = hardware
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
        var address: AudioObjectPropertyAddress {
            OutputVolumeHAL.address(selector, element, scope: scope)
        }
    }

    private static func snapshot(_ hardware: Hardware, device: UInt32?, evidence: MicrophoneEvidenceWriter?) -> OutputVolumeReading? {
        let result = device.flatMap { $0 == kAudioObjectUnknown ? nil : hardware.sample($0, true)?.reading }
        if result?.maximum == nil { evidence?.enqueue("output_volume_guard inert=snapshot_unavailable") }
        return result
    }

    func changePreference(_ enabled: Bool, evidence: MicrophoneEvidenceWriter?) {
        queue.async { [self] in
            self.evidence = evidence
            policy.setEnabled(enabled) {
                Self.snapshot(hardware, device: hardware.defaultDevice(), evidence: evidence)
            }
            if policy.isMonitoring { check() } else { removeMonitoring() }
        }
    }

    func begin(_ owner: UUID, device: @autoclosure () -> UInt32?, evidence: MicrophoneEvidenceWriter?) {
        self.evidence = evidence
        policy.begin(owner) { Self.snapshot(hardware, device: device(), evidence: evidence) }
        check()
    }

    func handover(from warm: UUID, to take: UUID) {
        policy.handover(from: warm, to: take)
        check()
    }

    func end(_ owner: UUID) {
        policy.end(owner)
        if !policy.isMonitoring { removeMonitoring() }
    }

    private func removeMonitoring() {
        updateListeners([])
        trailing?.cancel()
        trailing = nil
        lastWrite.removeAll()
        evidence = nil
    }

    func check() {
        guard policy.isMonitoring else { return }
        var wanted: Set<Property> = [Property(AudioObjectID(kAudioObjectSystemObject),
            OutputVolumeHAL.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal))]
        guard let device = hardware.defaultDevice() else {
            updateListeners(wanted.union(listeners.keys))
            return
        }
        guard device != kAudioObjectUnknown else {
            policy.disconnected()
            updateListeners(wanted)
            return
        }
        wanted.insert(Property(device, OutputVolumeHAL.address(kAudioDevicePropertyStreamConfiguration)))
        wanted.insert(Property(device, OutputVolumeHAL.address(.virtualMain)))
        // HAL wildcards also cover elements which appear on a profile switch.
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            wanted.insert(Property(device, OutputVolumeHAL.address(selector, kAudioObjectPropertyElementWildcard)))
        }
        guard let current = hardware.sample(device, false) else {
            updateListeners(wanted)
            return
        }
        for element in current.reading.volumes.keys {
            wanted.insert(Property(device, OutputVolumeHAL.address(element)))
        }
        updateListeners(wanted)
        let writes = policy.corrections(for: current.reading, settable: current.settable)
        // Handle individual channels before aggregate controls. The setter
        // rechecks the scalar to account for aliases changed by an earlier write.
        for element in writes.keys.sorted(by: { Self.order($0) < Self.order($1) }) {
            guard let ceiling = writes[element] else { continue }
            let key = Property(device, OutputVolumeHAL.address(element))
            let now = ProcessInfo.processInfo.systemUptime
            if let previous = lastWrite[key], now - previous < 0.25 {
                scheduleCheck(after: 0.25 - (now - previous))
                continue
            }
            do {
                guard let before = try hardware.lower(current.reading, element, ceiling) else { continue }
                lastWrite[key] = ProcessInfo.processInfo.systemUptime
                evidence?.enqueue("output_volume_guard device=\(device) element=\(element) from=\(before) to=\(ceiling)")
            } catch {
                lastWrite[key] = ProcessInfo.processInfo.systemUptime
                return
            }
        }
    }

    private static func order(_ element: OutputVolumeElement) -> UInt64 {
        switch element {
        case .virtualMain: return UInt64.max
        case .scalar(0): return UInt64.max - 1
        case .scalar(let channel): return UInt64(channel)
        }
    }

    private func scheduleCheck(after delay: TimeInterval) {
        guard trailing == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.trailing = nil
            self?.check()
        }
        trailing = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func updateListeners(_ wanted: Set<Property>) {
        for key in Set(listeners.keys).subtracting(wanted) {
            var address = key.address
            guard let listener = listeners[key] else { continue }
            let status = hardware.remove(key.device, &address, queue, listener)
            if status == noErr || status == kAudioHardwareBadObjectError {
                listeners.removeValue(forKey: key)
            }
        }
        for key in wanted where listeners[key] == nil {
            var address = key.address
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.check() }
            if hardware.add(key.device, &address, queue, listener) == noErr {
                listeners[key] = listener
            }
        }
    }
}
#endif
