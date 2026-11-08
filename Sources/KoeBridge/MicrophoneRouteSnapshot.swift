#if os(macOS)
import Foundation
import CoreAudio

/// Read-only HAL snapshot. Device IDs stay in memory; diagnostics record only
/// transport categories/presence. No device names, UIDs, media titles or URLs.
/// Run on the microphone lifecycle lane, not on the UI or real-time callback.
struct MicrophoneRouteSnapshot: Sendable {
    let inputDeviceID: UInt32?
    let outputDeviceID: UInt32?
    let inputTransport: String
    let outputTransport: String

    static func current(inputDeviceID: UInt32? = nil) -> Self {
        let input = inputDeviceID ?? defaultInputDeviceID()
        let output = deviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        return Self(inputDeviceID: input, outputDeviceID: output,
                    inputTransport: transport(of: input), outputTransport: transport(of: output))
    }

    static func defaultInputDeviceID() -> UInt32? {
        deviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    var diagnosticFields: String {
        let sameID: String
        if let inputDeviceID, let outputDeviceID { sameID = inputDeviceID == outputDeviceID ? "1" : "0" }
        else { sameID = "unknown" }
        // Equal IDs indicate one Core Audio object, NOT proof of a physical
        // headset match. Separate IDs can still belong to the same headset.
        return "input_present=\(inputDeviceID == nil ? 0 : 1) output_present=\(outputDeviceID == nil ? 0 : 1) input_transport=\(inputTransport) output_transport=\(outputTransport) same_device_id=\(sameID)"
    }

    private static func deviceID(selector: AudioObjectPropertySelector) -> UInt32? {
        guard let value = uint32(object: AudioObjectID(kAudioObjectSystemObject), selector: selector),
              value != kAudioObjectUnknown else { return nil }
        return value
    }

    private static func transport(of device: UInt32?) -> String {
        guard let device, let value = uint32(object: device, selector: kAudioDevicePropertyTransportType) else {
            return "unknown"
        }
        switch value {
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth_le"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBuiltIn: return "built_in"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        default: return "other"
        }
    }

    private static func uint32(object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let result = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard result == 0, size == UInt32(MemoryLayout<UInt32>.size) else { return nil }
        return value
    }
}
#endif
