/// Final decision after CoreAudio device selection and exact read-back.
/// A non-zero setter status is never accepted by itself; only an exact
/// requested-device read-back may authorize the capture path.
public enum MicrophoneBindingOutcome: Equatable, Sendable {
    case ready
    case selectionFailed(Int32)
    case selectionNotApplied
}

public enum MicrophoneBindingPolicy {
    public static func outcome(requestedID: UInt32, readBackID: UInt32?,
                               setStatus: Int32) -> MicrophoneBindingOutcome {
        guard requestedID != 0 else { return .selectionNotApplied }
        if readBackID == requestedID { return .ready }
        if setStatus != 0 { return .selectionFailed(setStatus) }
        return .selectionNotApplied
    }
}
