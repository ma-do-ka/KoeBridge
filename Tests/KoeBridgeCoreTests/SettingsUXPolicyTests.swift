import Foundation
import Testing
@testable import KoeBridgeCore

struct SettingsUXPolicyTests {
    @Test func continuationHintOnlyWhenContentBelowViewport() {
        #expect(SettingsUXPolicy.hasMoreBelow(contentHeight: 1200, viewportHeight: 500, offsetY: 0))
        #expect(SettingsUXPolicy.hasMoreBelow(contentHeight: 1200, viewportHeight: 500, offsetY: 400))
        #expect(!SettingsUXPolicy.hasMoreBelow(contentHeight: 1200, viewportHeight: 500, offsetY: 700))
        #expect(!SettingsUXPolicy.hasMoreBelow(contentHeight: 450, viewportHeight: 500, offsetY: 0))
        #expect(!SettingsUXPolicy.hasMoreBelow(contentHeight: 500, viewportHeight: 500, offsetY: 0))
        #expect(!SettingsUXPolicy.hasMoreBelow(contentHeight: 510, viewportHeight: 500, offsetY: 0))
    }

    @Test func continuationHintRejectsInvalidGeometryAndTinyRemainders() {
        #expect(!SettingsUXPolicy.hasMoreBelow(contentHeight: .nan, viewportHeight: 500, offsetY: 0))
        #expect(!SettingsUXPolicy.hasMoreBelow(contentHeight: 1200, viewportHeight: 0, offsetY: 0))
        #expect(!SettingsUXPolicy.hasMoreBelow(contentHeight: 1200, viewportHeight: 500, offsetY: .infinity))
        #expect(!SettingsUXPolicy.hasMoreBelow(contentHeight: 1200, viewportHeight: 500, offsetY: 685))
        #expect(SettingsUXPolicy.hasMoreBelow(contentHeight: 1200, viewportHeight: 500, offsetY: -20))
    }

    @Test func permissionRefreshResultDoesNotPretendToGrantPermissions() {
        let original = PermissionStateSnapshot(accessibilityGranted: true,
                                               postEventGranted: false, microphoneStatusRaw: 0)
        let newPermission = PermissionStateSnapshot(accessibilityGranted: true,
                                                   postEventGranted: true, microphoneStatusRaw: 0)
        let newMicrophone = PermissionStateSnapshot(accessibilityGranted: true,
                                                   postEventGranted: false, microphoneStatusRaw: 3)
        #expect(SettingsUXPolicy.refreshResult(before: original, after: original) == .unchanged)
        #expect(SettingsUXPolicy.refreshResult(before: original, after: newPermission) == .changed)
        #expect(SettingsUXPolicy.refreshResult(before: original, after: newMicrophone) == .changed)
    }
}
