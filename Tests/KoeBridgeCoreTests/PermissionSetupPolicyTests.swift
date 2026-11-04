import Testing
@testable import KoeBridgeCore

struct PermissionSetupPolicyTests {
    @Test func setupDoesNotHideMissingPermissions() {
        for accessibility in [false, true] {
            for postEvent in [false, true] {
                for microphone in [false, true] {
                    #expect(PermissionSetupPolicy.shouldShowSetup(
                        accessibilityGranted: accessibility, postEventGranted: postEvent,
                        microphoneGranted: microphone)
                        == !(accessibility && postEvent && microphone))
                }
            }
        }
    }
    @Test func inputMustHaveBothGrantAndFocusedField() {
        for accessibility in [false, true] {
            for postEvent in [false, true] {
                for field in [false, true] {
                    #expect(PermissionSetupPolicy.mayAttemptDirectInput(
                        accessibilityGranted: accessibility, postEventGranted: postEvent,
                        targetCaptured: field)
                        == (accessibility && postEvent && field))
                }
            }
        }
    }
}
