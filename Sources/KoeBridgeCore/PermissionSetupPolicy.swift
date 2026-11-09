public enum PermissionRequestAction: Equatable, Sendable {
    case none
    case openAccessibilitySettings
    case openMicrophoneSettings
    case needsAccessibilityFirst
    case showMicrophonePrompt
}

/// Pure permission gating decisions. macOS alone decides all grants.
/// Accessibility and CGEvent posting are distinct privacy capabilities.
public enum PermissionSetupPolicy {
    public static func accessibilityAction(granted: Bool) -> PermissionRequestAction {
        granted ? .none : .openAccessibilitySettings
    }

    public static func postEventAction(accessibilityGranted: Bool,
                                       postEventGranted: Bool) -> PermissionRequestAction {
        guard accessibilityGranted else { return .needsAccessibilityFirst }
        return postEventGranted ? .none : .openAccessibilitySettings
    }

    /// Uses AVAuthorizationStatus raw values without importing AVFoundation.
    public static func microphoneAction(status: Int) -> PermissionRequestAction {
        switch status {
        case 0: return .showMicrophonePrompt // notDetermined
        case 3: return .none // authorized
        default: return .openMicrophoneSettings // restricted (1), denied (2)
        }
    }

    public static func shouldShowSetup(accessibilityGranted: Bool,
                                       postEventGranted: Bool,
                                       microphoneGranted: Bool) -> Bool {
        !(accessibilityGranted && postEventGranted && microphoneGranted)
    }

    public static func mayAttemptDirectInput(accessibilityGranted: Bool,
                                             postEventGranted: Bool,
                                             targetCaptured: Bool) -> Bool {
        accessibilityGranted && postEventGranted && targetCaptured
    }
}
