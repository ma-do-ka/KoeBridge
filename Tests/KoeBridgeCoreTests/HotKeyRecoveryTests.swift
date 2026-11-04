import Testing
@testable import KoeBridgeCore

struct HotKeyRecoveryTests {
    @Test func explicitPhysicalReleaseReconcilesMissingCarbonUp() {
        var gate = HotKeyPressGate()
        gate.activate(42)
        let first = gate.receive(id: 42, pressed: true)
        let repeatPress = gate.receive(id: 42, pressed: true)
        let stillDown = gate.recoverMissedRelease(id: 42, physicalKeyStillDown: true)
        let secondRepeat = gate.receive(id: 42, pressed: true)
        let recovered = gate.recoverMissedRelease(id: 42, physicalKeyStillDown: false)
        let next = gate.receive(id: 42, pressed: true)
        #expect(first && !repeatPress && !stillDown && !secondRepeat && recovered && next)
    }

    @Test func oldRegistrationsCannotAffectNewHotkeys() {
        var gate = HotKeyPressGate()
        gate.activate(1)
        let first = gate.receive(id: 1, pressed: true)
        gate.activate(2)
        #expect(!gate.isRegistered(1))
        #expect(gate.isRegistered(2))
        let old = gate.recoverMissedRelease(id: 1, physicalKeyStillDown: false)
        let next = gate.receive(id: 2, pressed: true)
        #expect(first && !old && next)
    }

    @Test func missedRightCommandUpCanBeReconciledWithoutDoubleToggle() {
        var detector = ModifierToggleDetector(targetKeyCode: 54)
        let press = detector.flagsChanged(keyCode: 54, targetFlagPresent: true,
                                          otherModifierPresent: false)
        let recovered = detector.recoverPhysicalRelease()
        let repeatedRecovery = detector.recoverPhysicalRelease()
        let nextPress = detector.flagsChanged(keyCode: 54, targetFlagPresent: true,
                                              otherModifierPresent: false)
        let nextRelease = detector.flagsChanged(keyCode: 54, targetFlagPresent: false,
                                                otherModifierPresent: false)
        #expect(!press && recovered && !repeatedRecovery && !nextPress && nextRelease)
    }

    @Test func noAccidentalToggleAfterCancelledModifierTap() {
        var detector = ModifierToggleDetector(targetKeyCode: 54)
        _ = detector.flagsChanged(keyCode: 54, targetFlagPresent: true, otherModifierPresent: false)
        detector.otherKeyDown()
        let recovered = detector.recoverPhysicalRelease()
        #expect(!recovered)
        #expect(!detector.isHeld)
    }

}
