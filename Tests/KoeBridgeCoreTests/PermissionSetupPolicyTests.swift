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
    @Test func requestActionsCoverFullDecisionMatrix() {
        for (granted, expected) in [
            (false, PermissionRequestAction.openAccessibilitySettings),
            (true, PermissionRequestAction.none)
        ] {
            #expect(PermissionSetupPolicy.accessibilityAction(granted: granted) == expected)
        }
        for (accessibility, postEvent, expected) in [
            (false, false, PermissionRequestAction.needsAccessibilityFirst),
            (false, true, PermissionRequestAction.needsAccessibilityFirst),
            (true, false, PermissionRequestAction.openAccessibilitySettings),
            (true, true, PermissionRequestAction.none)
        ] {
            #expect(PermissionSetupPolicy.postEventAction(
                accessibilityGranted: accessibility, postEventGranted: postEvent) == expected)
        }
        for (status, expected) in [
            (0, PermissionRequestAction.showMicrophonePrompt),
            (1, PermissionRequestAction.openMicrophoneSettings),
            (2, PermissionRequestAction.openMicrophoneSettings),
            (3, PermissionRequestAction.none)
        ] {
            #expect(PermissionSetupPolicy.microphoneAction(status: status) == expected)
        }
    }
}
