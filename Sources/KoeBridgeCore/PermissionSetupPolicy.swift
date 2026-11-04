/// Pure permission gating decisions. macOS alone decides all grants.
/// Accessibility and CGEvent posting are distinct privacy capabilities.
public enum PermissionSetupPolicy {
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
