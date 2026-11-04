/// Suppress Carbon key-repeat and stale hotkey events after a shortcut switch.
/// Recording is toggled once per complete physical press/release cycle.
public struct HotKeyPressGate {
    private var registeredID: UInt32?
    private var held = false

    public init() {}

    public mutating func activate(_ id: UInt32?) {
        registeredID = id
        held = false
    }

    public func isRegistered(_ id: UInt32) -> Bool { registeredID == id }

    /// true only for the first press of the currently registered hotkey.
    public mutating func receive(id: UInt32, pressed: Bool) -> Bool {
        guard registeredID == id else { return false }
        if !pressed {
            held = false
            return false
        }
        guard !held else { return false }
        held = true
        return true
    }

    /// Carbon's release event can be lost when the keyboard route changes.
    /// Re-arm only after the operating system CONFIRMS that the key is up;
    /// a held key (including auto-repeat) may never be treated as a new tap.
    @discardableResult
    public mutating func recoverMissedRelease(id: UInt32, physicalKeyStillDown: Bool) -> Bool {
        guard registeredID == id, held, !physicalKeyStillDown else { return false }
        held = false
        return true
    }

}
