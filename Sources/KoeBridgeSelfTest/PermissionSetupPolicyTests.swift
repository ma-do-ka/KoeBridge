import KoeBridgeCore

struct PermissionSetupPolicyTests {
    func neverClaimsSetupDoneWithoutBothGrants() {
        for access in [false, true] {
            for postEvent in [false, true] {
                for mic in [false, true] {
                    check(PermissionSetupPolicy.shouldShowSetup(
                        accessibilityGranted: access, postEventGranted: postEvent,
                        microphoneGranted: mic) == !(access && postEvent && mic))
                }
            }
        }
    }
    func directInputRequiresActualProcessPermissionAndTarget() {
        for access in [false, true] {
            for postEvent in [false, true] {
                for target in [false, true] {
                    check(PermissionSetupPolicy.mayAttemptDirectInput(
                        accessibilityGranted: access, postEventGranted: postEvent,
                        targetCaptured: target) == (access && postEvent && target))
                }
            }
        }
    }
    func requestActionsCoverFullDecisionMatrix() {
        for (granted, expected) in [
            (false, PermissionRequestAction.openAccessibilitySettings),
            (true, PermissionRequestAction.none)
        ] {
            check(PermissionSetupPolicy.accessibilityAction(granted: granted) == expected)
        }
        for (accessibility, postEvent, expected) in [
            (false, false, PermissionRequestAction.needsAccessibilityFirst),
            (false, true, PermissionRequestAction.needsAccessibilityFirst),
            (true, false, PermissionRequestAction.openAccessibilitySettings),
            (true, true, PermissionRequestAction.none)
        ] {
            check(PermissionSetupPolicy.postEventAction(
                accessibilityGranted: accessibility, postEventGranted: postEvent) == expected)
        }
        for (status, expected) in [
            (0, PermissionRequestAction.showMicrophonePrompt),
            (1, PermissionRequestAction.openMicrophoneSettings),
            (2, PermissionRequestAction.openMicrophoneSettings),
            (3, PermissionRequestAction.none)
        ] {
            check(PermissionSetupPolicy.microphoneAction(status: status) == expected)
        }
    }
}
