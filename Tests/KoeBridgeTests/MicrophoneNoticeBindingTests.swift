#if os(macOS)
import AVFoundation
import Foundation
import Testing
@testable import KoeBridge
import KoeBridgeCore

struct MicrophoneNoticeBindingTests {
    @Test func captureErrorIdentitiesBindToNoticeStates() {
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneCapture.CaptureError.noInput) == .inputFormatUnconfirmed)
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

    @Test func rawEngineStartOSErrorsBindToStartUnavailable() {
        for domain in [NSOSStatusErrorDomain, "OSStatus"] {
            let startFailure = NSError(domain: domain, code: -50)
            #expect(MicrophoneNoticeBinding.state(for: startFailure, disposition: .normal) == .startUnavailable)
            #expect(MicrophoneNoticeBinding.state(for: startFailure, disposition: .verificationDeferred) == .startUnavailable)
            #expect(MicrophoneNoticeBinding.state(for: startFailure, disposition: .replacementPending) == .inputFormatUnconfirmed)
            #expect(MicrophoneNoticeBinding.state(for: startFailure, disposition: .terminal) == .tapGraphQuarantined)
        }
    }

    @Test func permissionNoticeSuppressesOnlyTheMicrophoneWarningInThePermissionsCard() {
        #expect(StatusPopoverPermissionCardPolicy.suppressesMicrophoneWarning(noticeState: .permissionDenied))
        #expect(!StatusPopoverPermissionCardPolicy.suppressesMicrophoneWarning(noticeState: .startUnavailable))
        #expect(StatusPopoverPermissionCardPolicy.needsAttention(
            noticeState: .permissionDenied, automationGranted: false, guideNeedsAttention: true))
        #expect(!StatusPopoverPermissionCardPolicy.needsAttention(
            noticeState: .permissionDenied, automationGranted: true, guideNeedsAttention: true))
        #expect(StatusPopoverPermissionCardPolicy.title(
            noticeState: .permissionDenied, automationGranted: true, guideNeedsAttention: true) == "自動入力の権限は正常")
        #expect(StatusPopoverPermissionCardPolicy.title(
            noticeState: .permissionDenied, automationGranted: false, guideNeedsAttention: true) == "権限の確認が必要です")
        #expect(StatusPopoverPermissionCardPolicy.needsAttention(
            noticeState: .startUnavailable, automationGranted: true, guideNeedsAttention: true))
        #expect(StatusPopoverPermissionCardPolicy.title(
            noticeState: nil, automationGranted: true, guideNeedsAttention: false) == "権限はすべて正常")
    }

    @Test func restartHelperPassesTheProcessIDAndBundlePathAsSeparateArguments() {
        let bundlePath = "/tmp/KoeBridge fixture; definitely not shell.app"
        let arguments = ApplicationRelauncher.arguments(processID: 4321, bundlePath: bundlePath)
        #expect(ApplicationRelauncher.executablePath == "/bin/sh")
        #expect(arguments.count == 5)
        #expect(arguments[0] == "-c")
        #expect(arguments[2] == "koebridge-restart")
        #expect(arguments[3] == "4321")
        #expect(arguments[4] == bundlePath)
        #expect(arguments[1].contains("$1"))
        #expect(arguments[1].contains("$2"))
        #expect(!arguments[1].contains(bundlePath))
        #expect(!arguments[1].contains("4321"))
    }
}
#endif
