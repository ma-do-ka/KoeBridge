/// Lifecycle of one on-device recognition request. Kept separate from the
/// Speech framework so cancellation and delayed callbacks can be exercised
/// without a microphone or a permission prompt.
public struct LocalRecognitionState: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, authorizing, recognizing, finishing, completed, failed, cancelled
    }

    public private(set) var phase: Phase = .idle
    public private(set) var transcript = ""
    public private(set) var failure: String?

    public init() {}

    public var acceptsAudio: Bool { phase == .recognizing }
    public var acceptsUpdates: Bool { phase == .recognizing || phase == .finishing }
    public var isFinal: Bool { phase == .completed }

    @discardableResult public mutating func beginAuthorization() -> Bool {
        guard phase == .idle else { return false }
        phase = .authorizing
        return true
    }

    @discardableResult public mutating func beginRecognition() -> Bool {
        guard phase == .authorizing else { return false }
        phase = .recognizing
        return true
    }

    /// Returns true only for the first request to finish an active recording.
    @discardableResult public mutating func endAudio() -> Bool {
        guard phase == .recognizing else { return false }
        phase = .finishing
        return true
    }

    @discardableResult public mutating func receive(_ text: String, isFinal: Bool) -> Bool {
        guard acceptsUpdates else { return false }
        transcript = text
        if isFinal { phase = .completed }
        return true
    }

    public mutating func receiveFailure(_ message: String) {
        // Speech can deliver a final result and an error together. Preserve
        // the accepted final; no later callback may replace a terminal state.
        guard acceptsUpdates else { return }
        failure = message
        phase = .failed
    }

    public mutating func cancel() {
        phase = .cancelled
        // Keep the last accepted text available for manual recovery.
    }
}
