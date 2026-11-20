#if os(macOS)
import AudioToolbox
import CoreAudio
import KoeBridgeCore

/// Read-only discovery and a single downward-only setter. No audio engine or
/// input-device operations, and no persistent device identifiers leave this layer.
enum OutputVolumeHAL {
    struct Sample {
        let reading: OutputVolumeReading
        let settable: Set<OutputVolumeElement>
    }

    static func address(_ selector: AudioObjectPropertySelector, _ element: UInt32 = 0,
                        scope: UInt32 = kAudioObjectPropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func address(_ element: OutputVolumeElement) -> AudioObjectPropertyAddress {
        switch element {
        case .virtualMain: return address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        case .scalar(let channel): return address(kAudioDevicePropertyVolumeScalar, channel)
        }
    }

    private enum ReadError: Error { case unavailable }

    private static func read<T>(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress,
                                initial: T) throws -> T {
        var value = initial
        return try withUnsafeMutableBytes(of: &value) { bytes in
            var size = UInt32(bytes.count)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bytes.baseAddress!) == noErr,
                  size == bytes.count else { throw ReadError.unavailable }
            return bytes.load(as: T.self)
        }
    }

    private static func channelCount(_ device: AudioDeviceID) throws -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration)
        guard AudioObjectHasProperty(device, &property) else { return 0 }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr,
              size >= MemoryLayout<UInt32>.size, size <= 65_536 else { throw ReadError.unavailable }
        let capacity = Int(size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, storage) == noErr,
              size >= MemoryLayout<UInt32>.size, size <= capacity else { throw ReadError.unavailable }
        let count = Int(storage.load(as: UInt32.self))
        guard count > 0 else { return 0 }
        guard let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers),
              offset + count * MemoryLayout<AudioBuffer>.stride <= size else { throw ReadError.unavailable }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        let channels = buffers.reduce(UInt64(0)) { $0 + UInt64($1.mNumberChannels) }
        guard channels <= 4096 else { throw ReadError.unavailable }
        return UInt32(channels)
    }

    private static func alive(_ device: UInt32) throws -> Bool {
        var property = address(kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal)
        return try read(device, &property, initial: UInt32(0)) != 0
    }

    private static func muted(_ device: UInt32, channels: UInt32) throws -> Bool {
        for channel in 0...channels {
            var property = address(kAudioDevicePropertyMute, channel)
            if AudioObjectHasProperty(device, &property),
               try read(device, &property, initial: UInt32(0)) != 0 { return true }
        }
        return false
    }

    private static func isSettable(_ device: UInt32, _ property: inout AudioObjectPropertyAddress) throws -> Bool {
        var flag = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &property, &flag) == noErr else { throw ReadError.unavailable }
        return flag.boolValue
    }

    static func sample(_ device: UInt32, snapshot: Bool) -> Sample? {
        guard let uid = MicrophoneDevices.uid(of: device) else { return nil }
        do {
            guard try alive(device) else { return nil }
            let channels = try channelCount(device)
            let mute = try muted(device, channels: channels)
            var volumes = [OutputVolumeElement: Float]()
            var settable = Set<OutputVolumeElement>()
            for element in [.virtualMain] + (0...channels).map(OutputVolumeElement.scalar) {
                var property = address(element)
                guard AudioObjectHasProperty(device, &property) else { continue }
                if snapshot {
                    volumes[element] = try? read(device, &property, initial: Float32(0))
                } else {
                    guard let value = try? read(device, &property, initial: Float32(0)) else { continue }
                    volumes[element] = value
                    if (try? isSettable(device, &property)) == true { settable.insert(element) }
                }
            }
            guard MicrophoneRouteSnapshot.defaultOutputDeviceID() == device else { return nil }
            return Sample(reading: .init(uid: uid, device: device, muted: mute, volumes: volumes), settable: settable)
        } catch { return nil }
    }

    static func scalar(_ device: UInt32, _ address: AudioObjectPropertyAddress) throws -> Float {
        var property = address
        let value = try read(device, &property, initial: Float32(0))
        guard (0...1).contains(value) else { throw ReadError.unavailable }
        return value
    }

    struct FinalReads {
        var defaultDevice = MicrophoneRouteSnapshot.defaultOutputDeviceID
        var uid = MicrophoneDevices.uid
        var alive = OutputVolumeHAL.alive
        var muted: (UInt32) throws -> Bool = { try OutputVolumeHAL.muted($0, channels: channelCount($0)) }
        var settable = OutputVolumeHAL.isSettable
        var scalar = OutputVolumeHAL.scalar
    }

    /// Executed in the same guard-queue turn as the setter, including when
    /// reconciling a concurrent lowering. Core Audio has no conditional setter.
    static func finalValue(_ reading: OutputVolumeReading, _ element: OutputVolumeElement,
                           reads: FinalReads) throws -> Float? {
        let device = reading.device
        var property = address(element)
        guard reads.defaultDevice() == device, try reads.alive(device), reads.uid(device) == reading.uid,
              try !reads.muted(device), try reads.settable(device, &property) else { return nil }
        let value = try reads.scalar(device, property)
        guard reads.defaultDevice() == device else { return nil }
        return value
    }

    static func set(_ device: UInt32, _ address: AudioObjectPropertyAddress, _ scalar: Float,
                    submit: (() throws -> Void) throws -> Bool) throws -> Bool {
        var property = address
        var value = scalar
        return try submit {
            guard AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
            else { throw ReadError.unavailable }
        }
    }
}
#endif
