import Foundation
import Testing
@testable import KoeBridgeCore

struct MicrophoneNoticeTests {
    @Test func copyCatalogIsExactForEveryState() {
        let rows: [(MicrophoneNoticeState, String, String, MicrophoneNoticeAction, MicrophoneNoticeAction?)] = [
            (.tapGraphQuarantined, "マイクを再利用できません", "マイクの安全な状態を確認できません。アプリを再起動してください。", .restartApplication, nil),
            (.permissionDenied, "マイクへのアクセスが許可されていません", "macOS のシステム設定で、このアプリのマイク使用を許可してください。", .openSystemSettings, .retryRecording),
            (.selectedDeviceMissing, "選択したマイクが未接続です", "接続を確認するか、設定で別のマイクを選んでください。自動では切り替えません。", .openMicrophoneSettings, .retryRecording),
            (.noInputDevice, "使えるマイクが見つかりません", "マイクを接続するか、macOS のサウンド設定で入力デバイスを確認してください。", .openSoundSettings, .retryRecording),
            (.ambiguousDevice, "マイクを特定できません", "同じ名前のマイクが重複している可能性があります。設定で選び直してください。", .openMicrophoneSettings, .retryRecording),
            (.recordingDeviceDisconnected, "録音中にマイク入力が中断されました", "マイク入力が変更または中断されたため録音を停止しました。入力を確認してから再開してください。", .openMicrophoneSettings, .dismiss),
            (.startUnavailable, "マイクを開始できませんでした", "他のアプリが使用中か、マイクが応答していません。確認してからもう一度お試しください。", .retryRecording, .dismiss),
            (.inputFormatUnconfirmed, "マイクの入力形式を確認できません", "マイクを再接続するか、設定で別のマイクを選んでからもう一度お試しください。", .openMicrophoneSettings, .dismiss),
            (.buffersUnstable, "マイクの準備が安定しません", "接続直後などで音声入力が不安定です。少し待ってからもう一度お試しください。", .retryRecording, .dismiss),
            (.unclassifiedStartFailure, "マイクを開始できませんでした", "マイクの開始に失敗しました。接続や設定を確認して、もう一度お試しください。", .retryRecording, .dismiss)
        ]
        #expect(rows.map(\.0) == MicrophoneNoticeState.allCases)
        for (state, title, message, primary, secondary) in rows {
            let notice = MicrophoneNotice(state: state)
            #expect(notice.title == title)
            #expect(notice.message == message)
            #expect(notice.primaryAction == primary)
            #expect(notice.secondaryAction == secondary)
        }
    }

    @Test func recordingDeviceCopyFollowsRemovalEvidence() {
        let disconnected = MicrophoneNotice(state: .recordingDeviceDisconnected, deviceRemovalProven: true)
        #expect(disconnected.title == "録音中にマイクが切断されました")
        #expect(disconnected.message == "マイクの接続が切れたため録音を停止しました。接続を確認してから再開してください。")

        let interrupted = MicrophoneNotice(state: .recordingDeviceDisconnected)
        #expect(interrupted.title == "録音中にマイク入力が中断されました")
        #expect(interrupted.message == "マイク入力が変更または中断されたため録音を停止しました。入力を確認してから再開してください。")

        let meetingDisconnected = MicrophoneNotice(state: .recordingDeviceDisconnected, context: .meeting,
                                                   deviceRemovalProven: true)
        #expect(meetingDisconnected.title == "マイク切断により会議モードを終了しました")
        #expect(meetingDisconnected.message == "マイクの接続が切れたため会議モードを終了しました。接続を確認してから再開してください。")

        let meetingInterrupted = MicrophoneNotice(state: .recordingDeviceDisconnected, context: .meeting)
        #expect(meetingInterrupted.title == "マイク入力の中断により会議モードを終了しました")
        #expect(meetingInterrupted.message == "マイク入力が変更または中断されたため会議モードを終了しました。入力を確認してから再開してください。")
        #expect(meetingInterrupted.primaryAction == .openMicrophoneSettings)
        #expect(meetingInterrupted.secondaryAction == .dismiss)
    }

    @Test func stateMetadataMatchesTaxonomy() {
        #expect(MicrophoneNoticeState.tapGraphQuarantined.priority == 1)
        #expect(MicrophoneNoticeState.permissionDenied.priority == 2)
        #expect(MicrophoneNoticeState.selectedDeviceMissing.priority == 3)
        #expect(MicrophoneNoticeState.noInputDevice.priority == 3)
        #expect(MicrophoneNoticeState.ambiguousDevice.priority == 3)
        #expect(MicrophoneNoticeState.recordingDeviceDisconnected.priority == 4)
        #expect(MicrophoneNoticeState.startUnavailable.priority == 5)
        #expect(MicrophoneNoticeState.inputFormatUnconfirmed.priority == 5)
        #expect(MicrophoneNoticeState.buffersUnstable.priority == 5)
        #expect(MicrophoneNoticeState.unclassifiedStartFailure.priority == 6)
        let requiredStates: [MicrophoneNoticeState] = [.tapGraphQuarantined, .permissionDenied, .selectedDeviceMissing,
                                                       .noInputDevice, .ambiguousDevice, .recordingDeviceDisconnected]
        for state in MicrophoneNoticeState.allCases {
            let required = requiredStates.contains(state)
            #expect((state.persistence == .required) == required)
            #expect(state.severity == (state == .tapGraphQuarantined ? .critical : .warning))
        }
        for state in [MicrophoneNoticeState.recordingDeviceDisconnected, .startUnavailable,
                      .inputFormatUnconfirmed, .buffersUnstable, .unclassifiedStartFailure] {
            #expect(state.allowsManualDismiss)
        }
        for state in [MicrophoneNoticeState.tapGraphQuarantined, .permissionDenied, .selectedDeviceMissing,
                      .noInputDevice, .ambiguousDevice] {
            #expect(!state.allowsManualDismiss)
        }
    }

    @Test func coreErrorIdentitiesClassifyWithoutReadingErrorText() {
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneSelectionError.noSystemInput) == .noInputDevice)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneSelectionError.selectedDeviceMissing) == .selectedDeviceMissing)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneSelectionError.ambiguousDevice) == .ambiguousDevice)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneStartupGate.Failure.unstableBuffers) == .buffersUnstable)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneStartupGate.Failure.noBuffers) == .buffersUnstable)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneStartupGate.Failure.formatChanged) == .inputFormatUnconfirmed)
        #if os(macOS)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneGraphError.quarantined) == .tapGraphQuarantined)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneGraphError.formatException) == .inputFormatUnconfirmed)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneGraphError.unknownException) == .unclassifiedStartFailure)
        #expect(MicrophoneNoticeClassifier.state(for: MicrophoneGraphError.unexpectedTopology) == .unclassifiedStartFailure)
        #endif
        let unknown = NSError(domain: "unknown.domain", code: 77, userInfo: [NSLocalizedDescriptionKey: "misleading text"])
        #expect(MicrophoneNoticeClassifier.state(for: unknown) == .unclassifiedStartFailure)
    }

    @Test func cancellationIdentitiesNeverBecomePersistentNotices() {
        #expect(MicrophoneNoticeClassifier.state(for: CancellationError()) == nil)
        #expect(MicrophoneNoticeClassifier.state(for: NSError(domain: NSCocoaErrorDomain, code: 3072)) == nil)
        #expect(MicrophoneNoticeClassifier.state(for: NSError(domain: NSURLErrorDomain, code: -999)) == nil)
    }

    @Test func retryFailureDoesNotSetAndFinalFailurePersistsUntilSuccessfulStart() {
        var store = MicrophoneNoticeStore()
        let ignored = store.recordFailure(.buffersUnstable, timing: .retryInProgress)
        #expect(!ignored)
        #expect(store.current == nil)
        let stored = store.recordFailure(.buffersUnstable, timing: .finalFailure)
        #expect(stored)
        #expect(store.current?.state == .buffersUnstable)
        #expect(store.current?.context == .standard)
        let ignoredAfterStored = store.recordFailure(.buffersUnstable, timing: .retryInProgress)
        #expect(ignoredAfterStored == false)
        #expect(store.current?.state == .buffersUnstable)
        let successfulStart = store.recordSuccessfulStart()
        #expect(successfulStart)
        #expect(store.current == nil)
        let repeatedSuccessfulStart = store.recordSuccessfulStart()
        #expect(!repeatedSuccessfulStart)
    }

    @Test func removalEvidenceIsRetainedByTheStore() {
        var store = MicrophoneNoticeStore()
        let disconnectProvenStored = store.recordFailure(.recordingDeviceDisconnected, timing: .finalFailure,
                                                         deviceRemovalProven: true)
        #expect(disconnectProvenStored)
        #expect(store.current?.deviceRemovalProven == true)
        #expect(store.current?.title == "録音中にマイクが切断されました")

        store = MicrophoneNoticeStore()
        let interruptedStored = store.recordFailure(.recordingDeviceDisconnected, timing: .finalFailure)
        #expect(interruptedStored)
        #expect(store.current?.deviceRemovalProven == false)
        #expect(store.current?.title == "録音中にマイク入力が中断されました")
    }

    @Test func priorityProtectsHigherStatesAndLatestSamePriorityWins() {
        var store = MicrophoneNoticeStore()
        let quarantinedStored = store.recordFailure(.tapGraphQuarantined, timing: .finalFailure)
        #expect(quarantinedStored)
        let unclassifiedStored = store.recordFailure(.unclassifiedStartFailure, timing: .finalFailure)
        #expect(!unclassifiedStored)
        #expect(store.current?.state == .tapGraphQuarantined)

        store = MicrophoneNoticeStore()
        let initialUnclassifiedStored = store.recordFailure(.unclassifiedStartFailure, timing: .finalFailure)
        #expect(initialUnclassifiedStored)
        let selectedDeviceStored = store.recordFailure(.selectedDeviceMissing, timing: .finalFailure)
        #expect(selectedDeviceStored)
        #expect(store.current?.state == .selectedDeviceMissing)

        store = MicrophoneNoticeStore()
        let startUnavailableStored = store.recordFailure(.startUnavailable, timing: .finalFailure)
        #expect(startUnavailableStored)
        let buffersUnstableStored = store.recordFailure(.buffersUnstable, timing: .finalFailure)
        #expect(buffersUnstableStored)
        #expect(store.current?.state == .buffersUnstable)
    }

    @Test func manualDismissOnlyAppliesToDismissibleStates() {
        for state in MicrophoneNoticeState.allCases {
            var store = MicrophoneNoticeStore()
            let stored = store.recordFailure(state, timing: .finalFailure)
            #expect(stored)
            let dismissed = store.dismissCurrent()
            #expect(dismissed == state.allowsManualDismiss)
            #expect((store.current == nil) == state.allowsManualDismiss)
        }
    }

    @Test func menuBarTooltipsMatchCatalogGroups() {
        #expect(MicrophoneNotice(state: .tapGraphQuarantined).menuBarTooltip == "マイク利用不可（アプリの再起動が必要です）")
        #expect(MicrophoneNotice(state: .permissionDenied).menuBarTooltip == "マイク利用不可（マイク権限を確認してください）")
        #expect(MicrophoneNotice(state: .selectedDeviceMissing).menuBarTooltip == "マイク利用不可（接続・マイク設定を確認してください）")
        #expect(MicrophoneNotice(state: .noInputDevice).menuBarTooltip == "マイク利用不可（接続・マイク設定を確認してください）")
        #expect(MicrophoneNotice(state: .ambiguousDevice).menuBarTooltip == "マイク利用不可（接続・マイク設定を確認してください）")
        for state in [MicrophoneNoticeState.recordingDeviceDisconnected, .startUnavailable,
                      .inputFormatUnconfirmed, .buffersUnstable, .unclassifiedStartFailure] {
            #expect(MicrophoneNotice(state: state).menuBarTooltip == "マイク開始に失敗しました（クリックして詳細を確認）")
        }
    }
}
