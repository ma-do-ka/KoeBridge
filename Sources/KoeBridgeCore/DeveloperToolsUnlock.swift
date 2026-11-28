import Foundation

/// Hidden entry point for the developer-tools settings group (bench recording).
/// The sequence is the Konami command, matched by physical key code so the
/// keyboard layout does not matter. This type only tracks progress; the app
/// target owns the event monitor, and the unlock state is persisted via
/// `DeveloperToolsUnlockStore`.
public struct DeveloperToolsUnlockSequence: Sendable {
    /// Up, up, down, down, left, right, left, right, B, A.
    public static let keyCodes: [UInt16] = [
        126, 126, 125, 125, 123, 124, 123, 124, 11, 0
    ]

    public private(set) var progress = 0

    public init() {}

    public mutating func reset() {
        progress = 0
    }

    /// Observes one key-down and reports whether it completed the command.
    /// Progress restarts after a match so the next key begins a new attempt.
    @discardableResult
    public mutating func advance(keyCode: UInt16) -> Bool {
        let sequence = Self.keyCodes
        if keyCode == sequence[progress] {
            progress += 1
            guard progress == sequence.count else { return false }
            progress = 0
            return true
        }
        // A non-matching key clears the partial sequence. The first key may
        // still begin a fresh attempt, so a mismatching ↑ restarts progress at
        // 1, not 2: repeating ↑ does not build a shortcut into the sequence.
        progress = keyCode == sequence[0] ? 1 : 0
        return false
    }
}

/// UserDefaults-backed unlock flag. Missing means locked, so a fresh install
/// never shows the developer-tools group.
public enum DeveloperToolsUnlockStore {
    public static let defaultsKey = "developerToolsUnlocked"

    public static func isUnlocked(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    public static func setUnlocked(_ unlocked: Bool, defaults: UserDefaults = .standard) {
        defaults.set(unlocked, forKey: defaultsKey)
    }

    /// Re-locks while unlocked and unlocks while locked; returns the new state.
    @discardableResult
    public static func toggle(defaults: UserDefaults = .standard) -> Bool {
        let next = !isUnlocked(defaults: defaults)
        setUnlocked(next, defaults: defaults)
        return next
    }
}

extension SettingsSection {
    /// The bench-recording page stays hidden from the sidebar, search index,
    /// and programmatic navigation until the hidden unlock is active.
    public func isAvailable(developerToolsUnlocked: Bool) -> Bool {
        self != .bench || developerToolsUnlocked
    }
}
