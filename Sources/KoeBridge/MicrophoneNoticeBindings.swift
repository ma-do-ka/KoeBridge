#if os(macOS)
import Foundation
import KoeBridgeCore

extension MicrophoneCapture.CaptureError: MicrophoneNoticeErrorIdentity {
    var microphoneNoticeState: MicrophoneNoticeState {
        switch self {
        case .noInput: return .noInputDevice
        case .alreadyStarted: return .unclassifiedStartFailure
        case .engineInUse: return .startUnavailable
        case .notReady(let failure): return failure.microphoneNoticeState
        }
    }
}

extension MicrophoneDevices.DeviceError: MicrophoneNoticeErrorIdentity {
    var microphoneNoticeState: MicrophoneNoticeState {
        switch self {
        case .enumerationFailed: return .unclassifiedStartFailure
        case .noAudioUnit, .selectionFailed, .selectionNotApplied: return .startUnavailable
        }
    }
}

enum MicrophoneNoticeBinding {
    static func state(
        for error: Error,
        disposition: MicrophoneCapture.EngineLifetime.Disposition
    ) -> MicrophoneNoticeState? {
        guard !MicrophoneNoticeClassifier.isCancellation(error) else { return nil }
        switch disposition {
        case .terminal: return .tapGraphQuarantined
        case .replacementPending: return .inputFormatUnconfirmed
        case .normal, .verificationDeferred: break
        }
        return MicrophoneNoticeClassifier.state(for: error)
    }
}
#endif
