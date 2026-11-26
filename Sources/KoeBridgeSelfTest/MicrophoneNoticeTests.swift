import Foundation
import KoeBridgeCore

struct MicrophoneNoticeTests {
    func copyCatalogIsExactForEveryState() {
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
        check(rows.map(\.0) == MicrophoneNoticeState.allCases)
        for (state, title, message, primary, secondary) in rows {
            let notice = MicrophoneNotice(state: state)
            check(notice.title == title)
            check(notice.message == message)
            check(notice.primaryAction == primary)
            check(notice.secondaryAction == secondary)
        }
    }

    func recordingDeviceCopyFollowsRemovalEvidence() {
        let disconnected = MicrophoneNotice(state: .recordingDeviceDisconnected, deviceRemovalProven: true)
        check(disconnected.title == "録音中にマイクが切断されました")
        check(disconnected.message == "マイクの接続が切れたため録音を停止しました。接続を確認してから再開してください。")

        let interrupted = MicrophoneNotice(state: .recordingDeviceDisconnected)
        check(interrupted.title == "録音中にマイク入力が中断されました")
        check(interrupted.message == "マイク入力が変更または中断されたため録音を停止しました。入力を確認してから再開してください。")

        let meetingDisconnected = MicrophoneNotice(state: .recordingDeviceDisconnected, context: .meeting,
                                                   deviceRemovalProven: true)
        check(meetingDisconnected.title == "マイク切断により会議モードを終了しました")
        check(meetingDisconnected.message == "マイクの接続が切れたため会議モードを終了しました。接続を確認してから再開してください。")

        let meetingInterrupted = MicrophoneNotice(state: .recordingDeviceDisconnected, context: .meeting)
        check(meetingInterrupted.title == "マイク入力の中断により会議モードを終了しました")
        check(meetingInterrupted.message == "マイク入力が変更または中断されたため会議モードを終了しました。入力を確認してから再開してください。")
    }

    func stateMetadataMatchesTaxonomy() {
        check(MicrophoneNoticeState.tapGraphQuarantined.priority == 1)
        check(MicrophoneNoticeState.permissionDenied.priority == 2)
        check(MicrophoneNoticeState.selectedDeviceMissing.priority == 3)
        check(MicrophoneNoticeState.noInputDevice.priority == 3)
        check(MicrophoneNoticeState.ambiguousDevice.priority == 3)
        check(MicrophoneNoticeState.recordingDeviceDisconnected.priority == 4)
        check(MicrophoneNoticeState.startUnavailable.priority == 5)
        check(MicrophoneNoticeState.inputFormatUnconfirmed.priority == 5)
        check(MicrophoneNoticeState.buffersUnstable.priority == 5)
        check(MicrophoneNoticeState.unclassifiedStartFailure.priority == 6)
        let requiredStates: [MicrophoneNoticeState] = [.tapGraphQuarantined, .permissionDenied, .selectedDeviceMissing,
                                                       .noInputDevice, .ambiguousDevice, .recordingDeviceDisconnected]
        for state in MicrophoneNoticeState.allCases {
            let required = requiredStates.contains(state)
            check((state.persistence == .required) == required)
            check(state.severity == (state == .tapGraphQuarantined ? .critical : .warning))
        }
    }

    func coreErrorIdentitiesClassifyWithoutReadingErrorText() {
        check(MicrophoneNoticeClassifier.state(for: MicrophoneSelectionError.noSystemInput) == .noInputDevice)
        check(MicrophoneNoticeClassifier.state(for: MicrophoneSelectionError.selectedDeviceMissing) == .selectedDeviceMissing)
        check(MicrophoneNoticeClassifier.state(for: MicrophoneSelectionError.ambiguousDevice) == .ambiguousDevice)
        check(MicrophoneNoticeClassifier.state(for: MicrophoneStartupGate.Failure.unstableBuffers) == .buffersUnstable)
        check(MicrophoneNoticeClassifier.state(for: MicrophoneStartupGate.Failure.formatChanged) == .inputFormatUnconfirmed)
        #if os(macOS)
        check(MicrophoneNoticeClassifier.state(for: MicrophoneGraphError.quarantined) == .tapGraphQuarantined)
        check(MicrophoneNoticeClassifier.state(for: MicrophoneGraphError.formatException) == .inputFormatUnconfirmed)
        check(MicrophoneNoticeClassifier.state(for: MicrophoneGraphError.unknownException) == .unclassifiedStartFailure)
        #endif
        let unknown = NSError(domain: "unknown.domain", code: 77, userInfo: [NSLocalizedDescriptionKey: "misleading text"])
        check(MicrophoneNoticeClassifier.state(for: unknown) == .unclassifiedStartFailure)
    }

    func cancellationIdentitiesNeverBecomePersistentNotices() {
        check(MicrophoneNoticeClassifier.state(for: CancellationError()) == nil)
        check(MicrophoneNoticeClassifier.state(for: NSError(domain: NSCocoaErrorDomain, code: 3072)) == nil)
        check(MicrophoneNoticeClassifier.state(for: NSError(domain: NSURLErrorDomain, code: -999)) == nil)
    }

    func retryFailureDoesNotSetAndFinalFailurePersistsUntilSuccessfulStart() {
        var store = MicrophoneNoticeStore()
        check(!store.recordFailure(.buffersUnstable, timing: .retryInProgress))
        check(store.current == nil)
        check(store.recordFailure(.buffersUnstable, timing: .finalFailure))
        check(store.current?.state == .buffersUnstable)
        check(!store.recordFailure(.buffersUnstable, timing: .retryInProgress))
        check(store.current?.state == .buffersUnstable)
        check(store.recordSuccessfulStart())
        check(store.current == nil)
    }

    func removalEvidenceIsRetainedByTheStore() {
        var store = MicrophoneNoticeStore()
        let disconnectProvenStored = store.recordFailure(.recordingDeviceDisconnected, timing: .finalFailure,
                                                         deviceRemovalProven: true)
        check(disconnectProvenStored)
        check(store.current?.deviceRemovalProven == true)
        check(store.current?.title == "録音中にマイクが切断されました")

        store = MicrophoneNoticeStore()
        let interruptedStored = store.recordFailure(.recordingDeviceDisconnected, timing: .finalFailure)
        check(interruptedStored)
        check(store.current?.deviceRemovalProven == false)
        check(store.current?.title == "録音中にマイク入力が中断されました")
    }

    func priorityProtectsHigherStatesAndLatestSamePriorityWins() {
        var store = MicrophoneNoticeStore()
        check(store.recordFailure(.tapGraphQuarantined, timing: .finalFailure))
        check(!store.recordFailure(.unclassifiedStartFailure, timing: .finalFailure))
        check(store.current?.state == .tapGraphQuarantined)

        store = MicrophoneNoticeStore()
        check(store.recordFailure(.unclassifiedStartFailure, timing: .finalFailure))
        check(store.recordFailure(.selectedDeviceMissing, timing: .finalFailure))
        check(store.current?.state == .selectedDeviceMissing)

        store = MicrophoneNoticeStore()
        check(store.recordFailure(.startUnavailable, timing: .finalFailure))
        check(store.recordFailure(.buffersUnstable, timing: .finalFailure))
        check(store.current?.state == .buffersUnstable)
    }

    func manualDismissOnlyAppliesToDismissibleStates() {
        for state in MicrophoneNoticeState.allCases {
            var store = MicrophoneNoticeStore()
            check(store.recordFailure(state, timing: .finalFailure))
            check(store.dismissCurrent() == state.allowsManualDismiss)
            check((store.current == nil) == state.allowsManualDismiss)
        }
    }

    func menuBarTooltipsMatchCatalogGroups() {
        check(MicrophoneNotice(state: .tapGraphQuarantined).menuBarTooltip == "マイク利用不可（アプリの再起動が必要です）")
        check(MicrophoneNotice(state: .permissionDenied).menuBarTooltip == "マイク利用不可（マイク権限を確認してください）")
        check(MicrophoneNotice(state: .selectedDeviceMissing).menuBarTooltip == "マイク利用不可（接続・マイク設定を確認してください）")
        check(MicrophoneNotice(state: .noInputDevice).menuBarTooltip == "マイク利用不可（接続・マイク設定を確認してください）")
        check(MicrophoneNotice(state: .ambiguousDevice).menuBarTooltip == "マイク利用不可（接続・マイク設定を確認してください）")
        for state in [MicrophoneNoticeState.recordingDeviceDisconnected, .startUnavailable,
                      .inputFormatUnconfirmed, .buffersUnstable, .unclassifiedStartFailure] {
            check(MicrophoneNotice(state: state).menuBarTooltip == "マイク開始に失敗しました（クリックして詳細を確認）")
        }
    }
}
