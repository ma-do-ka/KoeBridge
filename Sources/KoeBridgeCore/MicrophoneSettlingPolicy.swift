import Foundation

/// Phase 1 only: retain a healthy graph, otherwise use the ordinary attempt retry.
public struct MicrophoneSettlingPolicy: Equatable, Sendable {
    public let debounceDuration: TimeInterval
    public let maxCoalesceDuration: TimeInterval
    public let maxRevalidations: Int
    public let maxChurnNotifications: Int
    public let maxSettlingDuration: TimeInterval
    public let minimumCommitRunway: TimeInterval

    public init(debounceDuration: TimeInterval = 0.06, maxCoalesceDuration: TimeInterval = 0.25,
                maxRevalidations: Int = 4, maxChurnNotifications: Int = 16,
                maxSettlingDuration: TimeInterval = 1.25, minimumCommitRunway: TimeInterval = 0.20) {
        precondition(debounceDuration.isFinite && debounceDuration >= 0)
        precondition(maxCoalesceDuration.isFinite && maxCoalesceDuration >= debounceDuration)
        precondition(maxRevalidations > 0 && maxChurnNotifications > 0)
        precondition(maxSettlingDuration.isFinite && maxSettlingDuration > 0)
        precondition(minimumCommitRunway.isFinite && minimumCommitRunway > 0)
        self.debounceDuration = debounceDuration
        self.maxCoalesceDuration = maxCoalesceDuration
        self.maxRevalidations = maxRevalidations
        self.maxChurnNotifications = maxChurnNotifications
        self.maxSettlingDuration = maxSettlingDuration
        self.minimumCommitRunway = minimumCommitRunway
    }
}
