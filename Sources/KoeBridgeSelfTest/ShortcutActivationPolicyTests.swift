import KoeBridgeCore

struct ShortcutActivationPolicyTests {
    func togglePressRelease() {
        var p = ShortcutActivationPolicy(mode: .toggle)
        check(p.pressed(at: 0) == .toggle)
        check(p.pressed(at: 0.1) == nil)
        check(p.released(at: 1) == nil)
        check(p.pressed(at: 2) == .toggle)
    }
    func holdBeginCommit() {
        var p = ShortcutActivationPolicy(mode: .hold)
        check(p.pressed(at: 0) == .begin)
        check(p.released(at: 0.1) == .commit)
    }
    func holdIgnoresRepeatAndStrayRelease() {
        var p = ShortcutActivationPolicy(mode: .hold)
        check(p.released(at: 0) == nil)
        check(p.pressed(at: 1) == .begin)
        check(p.pressed(at: 2) == nil)
        check(p.released(at: 3) == .commit)
        check(p.released(at: 4) == nil)
    }
    func hybridShortTapLocks() {
        var p = ShortcutActivationPolicy(mode: .hybrid)
        check(p.pressed(at: 0) == .begin)
        check(p.released(at: 0.399) == nil)
        check(p.released(at: 1) == nil)
        check(p.pressed(at: 2) == .commit)
    }
    func hybridLongPressCommits() {
        var p = ShortcutActivationPolicy(mode: .hybrid)
        check(p.pressed(at: 0) == .begin)
        check(p.released(at: ShortcutActivationPolicy.hybridHoldThreshold) == .commit)
        check(p.pressed(at: 1) == .begin)
        check(p.released(at: 2) == .commit)
    }
    func pressWhileLockedCommitsAndUnlocks() {
        var p = ShortcutActivationPolicy(mode: .hybrid)
        check(p.pressed(at: 0) == .begin)
        check(p.released(at: 0.1) == nil)
        check(p.pressed(at: 1) == .commit)
        check(p.pressed(at: 1.1) == nil)
        check(p.released(at: 1.2) == nil)
        check(p.pressed(at: 2) == .begin)
    }
    func resetClearsLockAndDownState() {
        var p = ShortcutActivationPolicy(mode: .hybrid)
        check(p.pressed(at: 0) == .begin)
        check(p.released(at: 0.1) == nil)
        p.reset()
        check(p.pressed(at: 1) == .begin)
        p.reset()
        check(p.released(at: 2) == nil)
        check(p.pressed(at: 3) == .begin)
    }
    func modifierEdgesDebounceAndRecover() {
        var d = ModifierToggleDetector(targetKeyCode: 54)
        check(d.activationEdge(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false) == true)
        d.otherKeyDown()
        check(d.activationEdge(keyCode: 55, targetFlagPresent: true, otherModifierPresent: false) == nil)
        check(d.activationEdge(keyCode: 54, targetFlagPresent: false, otherModifierPresent: false) == false)
        check(d.activationEdge(keyCode: 54, targetFlagPresent: false, otherModifierPresent: false) == nil)
        check(d.activationEdge(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false) == true)
        check(d.isHeld)
        _ = d.recoverPhysicalRelease()
        check(!d.isHeld)
        check(d.activationEdge(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false) == true)
    }
    func physicalReleaseClearsActivationState() {
        var d = ModifierToggleDetector(targetKeyCode: 54)
        check(d.activationEdge(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false) == true)
        check(d.recoverPhysicalRelease())
        check(d.activationEdge(keyCode: 54, targetFlagPresent: true, otherModifierPresent: true) == nil)
        check(d.activationEdge(keyCode: 54, targetFlagPresent: false, otherModifierPresent: true) == nil)
    }
    func completedTapTogglesExactlyOnce() {
        var d = ModifierToggleDetector(targetKeyCode: 54)
        var p = ShortcutActivationPolicy(mode: .toggle)
        check(!d.flagsChanged(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false))
        check(d.flagsChanged(keyCode: 54, targetFlagPresent: false, otherModifierPresent: false))
        check(p.pressed(at: 1) == .toggle)
        check(p.released(at: 1) == nil)
        check(!d.flagsChanged(keyCode: 54, targetFlagPresent: false, otherModifierPresent: false))
    }
}
