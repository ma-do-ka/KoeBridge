#if os(macOS)
import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Combine
import KoeBridgeCore

/// HAL is read on a worker/lifecycle queue. This never changes the system's
/// default device. Names/UIDs are shown locally but never enter diagnostics.
enum MicrophoneDevices {
    struct Snapshot: Sendable {
        var devices: [MicrophoneDeviceOption]
        var defaultID: UInt32?
    }

    static func enumerate(readSize: (inout UInt32) -> OSStatus,
                          readData: (inout UInt32, UnsafeMutableRawPointer) -> OSStatus) throws -> [AudioObjectID] {
        var size: UInt32 = 0
        let stride = MemoryLayout<AudioObjectID>.stride
        guard readSize(&size) == noErr, size <= 65_536, Int(size).isMultiple(of: stride) else {
            throw DeviceError.enumerationFailed
        }
        guard size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        let status = ids.withUnsafeMutableBytes { readData(&size, $0.baseAddress!) }
        guard status == noErr, Int(size).isMultiple(of: stride), Int(size) / stride <= ids.count else {
            throw DeviceError.enumerationFailed
        }
        return Array(ids.prefix(Int(size) / stride))
    }

    static func snapshot() throws -> Snapshot {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ids = try enumerate(readSize: { AudioObjectGetPropertyDataSize(system, &address, 0, nil, &$0) },
                                readData: { AudioObjectGetPropertyData(system, &address, 0, nil, &$0, $1) })
        let devices = ids.compactMap { id -> MicrophoneDeviceOption? in
            guard uint32(id, kAudioDevicePropertyDeviceIsAlive) == 1,
                  hasInputStream(id),
                  let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
            return MicrophoneDeviceOption(uid: uid,
                                          name: string(id, kAudioObjectPropertyName) ?? "名称不明のマイク",
                                          deviceID: id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Duplicate UIDs are ambiguous and cannot be represented by a Picker tag.
        let counts = Dictionary(grouping: devices, by: \.uid)
        return Snapshot(devices: devices.filter { counts[$0.uid]?.count == 1 },
                        defaultID: MicrophoneRouteSnapshot.defaultInputDeviceID())
    }

    static func isBluetooth(deviceID: AudioObjectID) -> Bool {
        guard let transport = uint32(deviceID, kAudioDevicePropertyTransportType) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Do this before reading the hardware format or installing a tap.
    /// Read-back is mandatory: a successful SetProperty alone is not proof.
    static func bind(_ target: MicrophoneSelectionTarget, to node: AVAudioInputNode,
                     diagnostics: MicrophonePreparationDiagnostics? = nil) throws {
        guard let unit = node.audioUnit else { throw DeviceError.noAudioUnit }
        // A retained engine may still be bound to the previous explicit mic.
        // Rebind to the resolved system default too when needed, and avoid an
        // unnecessary device write when the requested device is already bound.
        diagnostics?.begin(.deviceBefore)
        let before = currentID(node)
        diagnostics?.end(.deviceBefore, code: before == nil ? 0 : 1, matched: before == target.deviceID)
        if before != target.deviceID {
            var id = AudioDeviceID(target.deviceID)
            diagnostics?.begin(.deviceSet)
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &id,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            diagnostics?.end(.deviceSet, code: Int(status))
            guard status == noErr else { throw DeviceError.selectionFailed(status) }
        }
        diagnostics?.begin(.deviceAfter)
        let after = currentID(node)
        diagnostics?.end(.deviceAfter, code: after == nil ? 0 : 1, matched: after == target.deviceID)
        guard after == target.deviceID else { throw DeviceError.selectionNotApplied }
    }

    static func isStillSelected(_ target: MicrophoneSelectionTarget, node: AVAudioInputNode) -> Bool {
        let id = target.deviceID
        guard uint32(id, kAudioDevicePropertyDeviceIsAlive) == 1,
              hasInputStream(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return false }
        return MicrophoneSelectionPolicy.isStillSelected(target,
            devices: [MicrophoneDeviceOption(uid: uid, name: "", deviceID: id)],
            systemDefaultID: target.followsSystem ? MicrophoneRouteSnapshot.defaultInputDeviceID() : nil,
            actualUnitDeviceID: currentID(node))
    }

    static func currentID(_ node: AVAudioInputNode) -> UInt32? {
        guard let unit = node.audioUnit else { return nil }
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &id, &size) == noErr,
              id != 0, size == UInt32(MemoryLayout<AudioDeviceID>.size) else { return nil }
        return id
    }

    private static func hasInputStream(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                mScope: kAudioDevicePropertyScopeInput,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size >= 4
    }
    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0; var size: UInt32 = 4
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && size == 4 ? value : nil
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value as String
    }
    enum DeviceError: LocalizedError {
        case enumerationFailed, noAudioUnit, selectionFailed(OSStatus), selectionNotApplied
        var errorDescription: String? {
            switch self {
            case .enumerationFailed: return "マイクの一覧を取得できませんでした"
            case .noAudioUnit: return "マイクの入力装置を初期化できませんでした"
            case .selectionFailed: return "選択したマイクを開けませんでした"
            case .selectionNotApplied: return "選択したマイクへの切り替えを確認できませんでした"
            }
        }
    }
}

@MainActor final class MicrophoneDeviceStore: ObservableObject {
    static let shared = MicrophoneDeviceStore()
    @Published private(set) var devices: [MicrophoneDeviceOption] = []
    @Published private(set) var selectedUID: String
    @Published private(set) var defaultID: UInt32?
    @Published private(set) var loaded = false
    private var refreshing = false
    private let defaults = UserDefaults.standard
    private init() { selectedUID = UserDefaults.standard.string(forKey: "microphoneInputUID") ?? "" }

    var systemLabel: String {
        guard let device = devices.first(where: { $0.deviceID == defaultID }) else {
            return "システム設定に従う"
        }
        return "システム設定に従う（\(device.name)）"
    }
    var selectedDeviceMissing: Bool {
        loaded && !selectedUID.isEmpty && !devices.contains { $0.uid == selectedUID }
    }
    func select(_ uid: String) {
        guard !VoiceController.shared.busy,
              uid.isEmpty || devices.contains(where: { $0.uid == uid }) else { return }
        selectedUID = uid
        defaults.set(uid, forKey: "microphoneInputUID")
    }
    /// Called only while the settings page is visible. No idle mic activation.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let snapshot = await Task.detached(priority: .utility) { try? MicrophoneDevices.snapshot() }.value
        guard let snapshot, !Task.isCancelled else { return }
        devices = snapshot.devices; defaultID = snapshot.defaultID; loaded = true
    }
}
#endif
