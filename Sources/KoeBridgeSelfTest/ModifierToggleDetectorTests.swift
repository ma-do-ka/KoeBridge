
import KoeBridgeCore

struct ModifierToggleDetectorTests {
    func rightCommandSolitaryTapTogglesOnlyOnRelease() {
        var d = ModifierToggleDetector(targetKeyCode: 54)
        let toggleResult0 = d.flagsChanged(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false)
        check(!toggleResult0)
        check(d.isHeld)
        let toggleResult1 = d.flagsChanged(keyCode: 54, targetFlagPresent: false, otherModifierPresent: false)
        check(toggleResult1)
        check(!d.isHeld)
    }

    func modifierUsedInShortcutDoesNotToggle() {
        var d = ModifierToggleDetector(targetKeyCode: 54)
        _ = d.flagsChanged(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false)
        d.otherKeyDown() // e.g. right Cmd + V
        let toggleResult2 = d.flagsChanged(keyCode: 54, targetFlagPresent: false, otherModifierPresent: false)
        check(!toggleResult2)
        check(!d.isHeld)
    }

    func secondModifierDuringHoldCancels() {
        var d = ModifierToggleDetector(targetKeyCode: 54)
        _ = d.flagsChanged(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false)
        let toggleResult3 = d.flagsChanged(keyCode: 56, targetFlagPresent: false, otherModifierPresent: true)
        check(!toggleResult3)
        let toggleResult4 = d.flagsChanged(keyCode: 54, targetFlagPresent: false, otherModifierPresent: false)
        check(!toggleResult4)
    }

    func modifierAlreadyCombinedAtPressDoesNotToggle() {
        var d = ModifierToggleDetector(targetKeyCode: 54)
        _ = d.flagsChanged(keyCode: 54, targetFlagPresent: true, otherModifierPresent: true)
        let toggleResult5 = d.flagsChanged(keyCode: 54, targetFlagPresent: false, otherModifierPresent: false)
        check(!toggleResult5)
    }

    func twoSeparateCleanTapsEachToggle() {
        var d = ModifierToggleDetector(targetKeyCode: 54)
        for _ in 0..<2 {
            _ = d.flagsChanged(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false)
            let toggleResult6 = d.flagsChanged(keyCode: 54, targetFlagPresent: false, otherModifierPresent: false)
            check(toggleResult6)
        }
    }

    func spuriousReleaseAndReset() {
        var d = ModifierToggleDetector(targetKeyCode: 63)
        let toggleResult7 = d.flagsChanged(keyCode: 63, targetFlagPresent: false, otherModifierPresent: false)
        check(!toggleResult7)
        _ = d.flagsChanged(keyCode: 63, targetFlagPresent: true, otherModifierPresent: false)
        d.reset()
        let toggleResult8 = d.flagsChanged(keyCode: 63, targetFlagPresent: false, otherModifierPresent: false)
        check(!toggleResult8)
    }

    func familyFlagStillSetByOtherSideOnRelease() {
        var d = ModifierToggleDetector(targetKeyCode: 54)
        _ = d.flagsChanged(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false)
        _ = d.flagsChanged(keyCode: 55, targetFlagPresent: true, otherModifierPresent: false)
        let toggleResult9 = d.flagsChanged(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false)
        check(!toggleResult9)
    }
}
