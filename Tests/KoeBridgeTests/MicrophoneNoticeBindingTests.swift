#if os(macOS)
import AVFoundation
import Foundation
import Testing
@testable import KoeBridge
import KoeBridgeCore

struct MicrophoneNoticeBindingTests {
    @Test func captureErrorIdentitiesBindToNoticeStates() {
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneCapture.CaptureError.noInput) == .noInputDevice)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneCapture.CaptureError.alreadyStarted) == .unclassifiedStartFailure)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneCapture.CaptureError.engineInUse) == .startUnavailable)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneCapture.CaptureError.notReady(.unstableBuffers)) == .buffersUnstable)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneCapture.CaptureError.notReady(.noBuffers)) == .buffersUnstable)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneCapture.CaptureError.notReady(.formatChanged)) == .inputFormatUnconfirmed)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneCapture.CaptureError.notReady(.inputRouteChanged)) == .buffersUnstable)
    }

    @Test func deviceErrorIdentitiesBindToNoticeStates() {
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneDevices.DeviceError.enumerationFailed) == .unclassifiedStartFailure)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneDevices.DeviceError.noAudioUnit) == .startUnavailable)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneDevices.DeviceError.selectionFailed(-50)) == .startUnavailable)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneDevices.DeviceError.selectionNotApplied) == .startUnavailable)
    }

    @Test func engineDispositionOverridesTheUnderlyingErrorButNeverCancellation() {
        let selection = MicrophoneDevices.DeviceError.selectionNotApplied
        #expect(MicrophoneNoticeBinding.state(for: selection, disposition: .terminal) == .tapGraphQuarantined)
        #expect(MicrophoneNoticeBinding.state(for: selection, disposition: .replacementPending) == .inputFormatUnconfirmed)
        #expect(MicrophoneNoticeBinding.state(for: selection, disposition: .verificationDeferred) == .startUnavailable)
        #expect(MicrophoneNoticeBinding.state(for: selection, disposition: .normal) == .startUnavailable)
        #expect(MicrophoneNoticeBinding.state(for: CancellationError(), disposition: .terminal) == nil)
    }
}
#endif
