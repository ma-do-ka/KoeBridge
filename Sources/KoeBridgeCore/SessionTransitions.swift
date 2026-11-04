/// State decision for a single F8 press. In v0.3.9 the finalizer belongs
/// to its own take, and cannot reserve or block a subsequent recording.
public enum VoiceSessionPhase: Equatable, Sendable {
    case idle, preparing, recording, finalizing
}

public enum VoiceShortcutAction: Equatable, Sendable {
    case start, discard, stop
}

public struct VoiceSessionTransitions: Sendable {
    public init() {}
    public func shortcut(phase: VoiceSessionPhase) -> VoiceShortcutAction {
        switch phase {
        case .idle, .finalizing: return .start
        case .preparing: return .discard
        case .recording: return .stop
        }
    }
}
