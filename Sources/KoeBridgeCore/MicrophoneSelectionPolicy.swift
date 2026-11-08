import Foundation

/// Device identifiers are private, in-memory routing data. Persist the stable
/// UID, never the Core Audio numeric ID (which can change on reconnection).
public struct MicrophoneDeviceOption: Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public let deviceID: UInt32
    public var id: String { uid }
    public init(uid: String, name: String, deviceID: UInt32) {
        self.uid = uid; self.name = name; self.deviceID = deviceID
    }
}

public struct MicrophoneSelectionTarget: Equatable, Sendable {
    public let uid: String
    public let deviceID: UInt32
    public let followsSystem: Bool
}

public enum MicrophoneSelectionError: Error, Equatable, Sendable, LocalizedError {
    case noSystemInput, selectedDeviceMissing, ambiguousDevice
    public var errorDescription: String? {
        switch self {
        case .noSystemInput: return "システムの入力マイクが見つかりません"
        case .selectedDeviceMissing: return "選択したマイクが接続されていません。設定で確認してください"
        case .ambiguousDevice: return "マイクを一意に特定できませんでした"
        }
    }
}

public enum MicrophoneSelectionPolicy {
    /// An empty preference means follow the system, not "remember today's mic".
    public static let systemDefault = ""

    public static func resolve(uid: String, devices: [MicrophoneDeviceOption],
                               systemDefaultID: UInt32?) throws -> MicrophoneSelectionTarget {
        let matches: [MicrophoneDeviceOption]
        if uid.isEmpty {
            guard let systemDefaultID, systemDefaultID != 0 else {
                throw MicrophoneSelectionError.noSystemInput
            }
            matches = devices.filter { $0.deviceID == systemDefaultID && !$0.uid.isEmpty }
        } else {
            matches = devices.filter { $0.uid == uid && $0.deviceID != 0 }
        }
        guard !matches.isEmpty else {
            throw uid.isEmpty ? MicrophoneSelectionError.noSystemInput : .selectedDeviceMissing
        }
        guard matches.count == 1, let device = matches.first else {
            throw MicrophoneSelectionError.ambiguousDevice
        }
        return MicrophoneSelectionTarget(uid: device.uid, deviceID: device.deviceID,
                                         followsSystem: uid.isEmpty)
    }

    /// A reconnect can reuse the numeric ID for a different device. Both values
    /// must match, and an explicit choice never falls back to the system mic.
    public static func isStillSelected(_ target: MicrophoneSelectionTarget,
                                       devices: [MicrophoneDeviceOption],
                                       systemDefaultID: UInt32?, actualUnitDeviceID: UInt32?) -> Bool {
        guard actualUnitDeviceID == target.deviceID,
              devices.filter({ $0.uid == target.uid && $0.deviceID == target.deviceID }).count == 1 else {
            return false
        }
        return !target.followsSystem || systemDefaultID == target.deviceID
    }
}
