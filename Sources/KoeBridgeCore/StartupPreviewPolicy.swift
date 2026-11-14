import Foundation

/// Display-only probation for the first eligible hypothesis of one take.
/// The caller applies acoustic admission first and drives ticks; no timers or ASR state live here.
public struct StartupPreviewPolicy: Sendable {
    public enum Decision: Equatable, Sendable { case suppress, publish(String) }
    public private(set) var generation: UInt64 = 0
    public private(set) var hasPublished = false
    private var firstEligibleAt: TimeInterval?
    private var pendingAt: TimeInterval?
    private var pending: String?

    public init() {}

    public var nextPublicationAt: TimeInterval? {
        guard !hasPublished, let firstEligibleAt, let pendingAt, pending != nil else { return nil }
        return min(firstEligibleAt + 1.0, pendingAt + 0.25)
    }

    public mutating func interim(_ text: String, at now: TimeInterval) -> Decision {
        guard now.isFinite else { return .suppress }
        generation &+= 1
        if hasPublished { return .publish(text) }
        // An empty revision cancels the current hypothesis, but not the overall cap.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pending = nil; pendingAt = nil
            return .suppress
        }
        if firstEligibleAt == nil { firstEligibleAt = now }
        if let pending, text.hasPrefix(pending) { return publish(text) }
        pending = text; pendingAt = now
        if let firstEligibleAt, now - firstEligibleAt >= 1.0 { return publish(text) }
        return .suppress
    }

    public mutating func final(_ text: String) -> Decision {
        generation &+= 1
        return publish(text)
    }

    public mutating func tick(at now: TimeInterval, generation expected: UInt64) -> Decision {
        guard expected == generation, !hasPublished, now.isFinite,
              let deadline = nextPublicationAt, now >= deadline, let pending else { return .suppress }
        return publish(pending)
    }

    /// Stop, failure, replacement and discard invalidate every scheduled tick.
    public mutating func reset() {
        generation &+= 1
        hasPublished = false
        firstEligibleAt = nil; pendingAt = nil; pending = nil
    }

    private mutating func publish(_ text: String) -> Decision {
        hasPublished = true
        pending = nil; pendingAt = nil
        return .publish(text)
    }
}
