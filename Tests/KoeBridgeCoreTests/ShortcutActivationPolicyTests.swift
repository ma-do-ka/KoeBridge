import Testing
@testable import KoeBridgeCore

struct ShortcutActivationPolicyTests {
    @Test func togglePressRelease() {
        var p = ShortcutActivationPolicy(mode: .toggle)
        #expect(p.pressed(at: 0) == .toggle)
        #expect(p.pressed(at: 0.1) == nil)
        #expect(p.released(at: 1) == nil)
        #expect(p.pressed(at: 2) == .toggle)
    }
    @Test func holdBeginCommit() {
        var p = ShortcutActivationPolicy(mode: .hold)
        #expect(p.pressed(at: 0) == .begin)
        #expect(p.released(at: 0.1) == .commit)
    }
    @Test func holdIgnoresRepeatAndStrayRelease() {
        var p = ShortcutActivationPolicy(mode: .hold)
        #expect(p.released(at: 0) == nil)
        #expect(p.pressed(at: 1) == .begin)
        #expect(p.pressed(at: 2) == nil)
        #expect(p.released(at: 3) == .commit)
        #expect(p.released(at: 4) == nil)
    }
    @Test func hybridShortTapLocks() {
        var p = ShortcutActivationPolicy(mode: .hybrid)
        #expect(p.pressed(at: 0) == .begin)
        #expect(p.released(at: 0.399) == nil)
        #expect(p.released(at: 1) == nil)
        #expect(p.pressed(at: 2) == .commit)
    }
    @Test func hybridLongPressCommits() {
        var p = ShortcutActivationPolicy(mode: .hybrid)
        #expect(p.pressed(at: 0) == .begin)
        #expect(p.released(at: ShortcutActivationPolicy.hybridHoldThreshold) == .commit)
        #expect(p.pressed(at: 1) == .begin)
        #expect(p.released(at: 2) == .commit)
    }
    @Test func pressWhileLockedCommitsAndUnlocks() {
        var p = ShortcutActivationPolicy(mode: .hybrid)
        #expect(p.pressed(at: 0) == .begin)
        #expect(p.released(at: 0.1) == nil)
        #expect(p.pressed(at: 1) == .commit)
        #expect(p.pressed(at: 1.1) == nil)
        #expect(p.released(at: 1.2) == nil)
        #expect(p.pressed(at: 2) == .begin)
    }
    @Test func resetClearsLockAndDownState() {
        var p = ShortcutActivationPolicy(mode: .hybrid)
        #expect(p.pressed(at: 0) == .begin)
        #expect(p.released(at: 0.1) == nil)
        p.reset()
        #expect(p.pressed(at: 1) == .begin)
        p.reset()
        #expect(p.released(at: 2) == nil)
        #expect(p.pressed(at: 3) == .begin)
    }
    @Test func modifierEdgesDebounceAndRecover() {
        var d = ModifierToggleDetector(targetKeyCode: 54)
        #expect(d.activationEdge(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false) == true)
        d.otherKeyDown()
        #expect(d.activationEdge(keyCode: 55, targetFlagPresent: true, otherModifierPresent: false) == nil)
        #expect(d.activationEdge(keyCode: 54, targetFlagPresent: false, otherModifierPresent: false) == false)
        #expect(d.activationEdge(keyCode: 54, targetFlagPresent: false, otherModifierPresent: false) == nil)
        #expect(d.activationEdge(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false) == true)
        #expect(d.isHeld)
        _ = d.recoverPhysicalRelease()
        #expect(!d.isHeld)
        #expect(d.activationEdge(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false) == true)
    }
    @Test func physicalReleaseClearsActivationState() {
        var d = ModifierToggleDetector(targetKeyCode: 54)
        #expect(d.activationEdge(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false) == true)
        #expect(d.recoverPhysicalRelease())
        #expect(d.activationEdge(keyCode: 54, targetFlagPresent: true, otherModifierPresent: true) == nil)
        #expect(d.activationEdge(keyCode: 54, targetFlagPresent: false, otherModifierPresent: true) == nil)
    }
    @Test func completedTapTogglesExactlyOnce() {
        var d = ModifierToggleDetector(targetKeyCode: 54)
        var p = ShortcutActivationPolicy(mode: .toggle)
        #expect(!d.flagsChanged(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false))
        #expect(d.flagsChanged(keyCode: 54, targetFlagPresent: false, otherModifierPresent: false))
        #expect(p.pressed(at: 1) == .toggle)
        #expect(p.released(at: 1) == nil)
        #expect(!d.flagsChanged(keyCode: 54, targetFlagPresent: false, otherModifierPresent: false))
    }
}
