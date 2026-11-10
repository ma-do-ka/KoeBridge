import Foundation

/// OS-agnostic tap-to-toggle state machine for one *physical* modifier key.
/// The caller must supply events in timestamp order from the same event tap.
/// A toggle is emitted only on release after a solitary press; any other key
/// or modifier used while the key is held cancels that tap.
public struct ModifierToggleDetector {
    public let targetKeyCode: Int
    public private(set) var isHeld = false
    private var eligible = false

    public init(targetKeyCode: Int) { self.targetKeyCode = targetKeyCode }

    /// - Parameters:
    ///   - targetFlagPresent: Is the modifier family bit set in the current event?
    ///   - otherModifierPresent: Is any different modifier family currently down?
    /// - Returns: true only when a complete clean tap should toggle dictation.
    public mutating func flagsChanged(
        keyCode: Int, targetFlagPresent: Bool, otherModifierPresent: Bool
    ) -> Bool {
        if keyCode != targetKeyCode {
            if isHeld { eligible = false }
            return false
        }
        if !isHeld {
            guard targetFlagPresent else { return false }
            isHeld = true
            eligible = !otherModifierPresent
            return false
        }
        // Match by physical keyCode instead of the shared family flag. E.g.,
        // releasing right Command while left Command is down can still leave
        // the Command family flag set.
        isHeld = false
        let shouldToggle = eligible && !otherModifierPresent
        eligible = false
        return shouldToggle
    }

    /// Immediate edges for activation modes. Shares the physical-key debounce with
    /// completed-tap detection. Once begun, always balance the release, even if
    /// another key was used in the meantime.
    public mutating func activationEdge(keyCode: Int, targetFlagPresent: Bool,
                                        otherModifierPresent: Bool) -> Bool? {
        let wasHeld = isHeld
        _ = flagsChanged(keyCode: keyCode, targetFlagPresent: targetFlagPresent,
                         otherModifierPresent: otherModifierPresent)
        if !wasHeld && isHeld && !otherModifierPresent {
            activationHeld = true
            return true
        }
        if wasHeld && !isHeld && activationHeld {
            activationHeld = false
            return false
        }
        return nil
    }

    private var activationHeld = false

    public mutating func otherKeyDown() {
        if isHeld { eligible = false }
    }

    /// Called when a platform-specific key-state probe confirms a release
    /// even though macOS did not deliver its flagsChanged event.
    public mutating func recoverPhysicalRelease() -> Bool {
        activationHeld = false
        guard isHeld else { return false }
        let shouldToggle = eligible
        reset()
        return shouldToggle
    }

    public mutating func reset() {
        isHeld = false
        eligible = false
        activationHeld = false
    }
}
