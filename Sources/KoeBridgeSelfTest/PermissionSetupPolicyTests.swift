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
}
