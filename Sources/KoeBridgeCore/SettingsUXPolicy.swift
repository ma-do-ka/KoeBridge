import Foundation

/// Pure UI policy. Never alters OS permissions or persisted settings.
public enum SettingsUXPolicy {
    /// Keep a bottom continuation hint only while meaningful content remains.
    /// Mac scroll bars may be hidden by system preferences even when requested.
    public static func hasMoreBelow(contentHeight: Double, viewportHeight: Double,
                                    offsetY: Double) -> Bool {
        guard contentHeight.isFinite, viewportHeight.isFinite, offsetY.isFinite,
              viewportHeight > 0 else { return false }
        let remaining = contentHeight - viewportHeight - max(offsetY, 0)
        return contentHeight > viewportHeight + 12 && remaining > 24
    }

    public static func refreshResult(before: PermissionStateSnapshot,
                                     after: PermissionStateSnapshot) -> PermissionRefreshResult {
        before == after ? .unchanged : .changed
    }
}

public struct PermissionStateSnapshot: Equatable, Sendable {
    public let accessibilityGranted: Bool
    public let postEventGranted: Bool
    /// Raw macOS status; using an Int keeps this policy independent of AVFoundation.
    public let microphoneStatusRaw: Int

    public init(accessibilityGranted: Bool, postEventGranted: Bool, microphoneStatusRaw: Int) {
        self.accessibilityGranted = accessibilityGranted
        self.postEventGranted = postEventGranted
        self.microphoneStatusRaw = microphoneStatusRaw
    }
}

public enum PermissionRefreshResult: Equatable, Sendable {
    case changed
    case unchanged
}
