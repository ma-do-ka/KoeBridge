import Foundation

public enum ShortcutActivationMode: String, CaseIterable, Sendable {
    case toggle, hold, hybrid
}

public enum ShortcutActivationAction: Equatable, Sendable {
    case toggle, begin, commit
}

public struct ShortcutActivationPolicy {
    public static let hybridHoldThreshold: TimeInterval = 0.4
    public var mode: ShortcutActivationMode
    private var downAt: TimeInterval?
    private var locked = false

    public init(mode: ShortcutActivationMode = .toggle) { self.mode = mode }

    public mutating func pressed(at time: TimeInterval) -> ShortcutActivationAction? {
        guard downAt == nil else { return nil }
        downAt = time
        if mode == .hybrid && locked {
            locked = false
            committingLock = true
            return .commit
        }
        switch mode {
        case .toggle: return .toggle
        case .hold, .hybrid: return .begin
        }
    }

    public mutating func released(at time: TimeInterval) -> ShortcutActivationAction? {
        guard let start = downAt else { return nil }
        downAt = nil
        switch mode {
        case .toggle: return nil
        case .hold: return .commit
        case .hybrid:
            // A press that committed a lock must not lock again on release.
            if committingLock { committingLock = false; return nil }
            if time - start >= Self.hybridHoldThreshold { return .commit }
            locked = true
            return nil
        }
    }

    private var committingLock = false

    public mutating func reset() {
        downAt = nil
        locked = false
        committingLock = false
    }
}

public enum MouseTriggerButton: String, CaseIterable, Sendable {
    case none, middle, sideBack, sideForward

    public var buttonNumber: Int64? {
        switch self {
        case .none: return nil
        case .middle: return 2
        case .sideBack: return 3
        case .sideForward: return 4
        }
    }
}
