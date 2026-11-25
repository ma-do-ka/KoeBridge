import Foundation

public enum MicrophoneNoticePersistence: String, Equatable, Sendable {
    case required, conditional
}

public enum MicrophoneNoticeSeverity: String, Equatable, Sendable {
    case critical, warning
}

public enum MicrophoneNoticeContext: String, Equatable, Sendable {
    case standard, meeting
}

public enum MicrophoneNoticeFailureTiming: String, Equatable, Sendable {
    case retryInProgress, finalFailure
}

public enum MicrophoneNoticeAction: String, Equatable, Sendable {
    case restartApplication = "アプリを再起動"
    case openSystemSettings = "システム設定を開く"
    case openMicrophoneSettings = "マイク設定を開く"
    case openSoundSettings = "サウンド設定を開く"
    case retryRecording = "もう一度試す"
    case dismiss = "閉じる"

    public var title: String { rawValue }
}

public enum MicrophoneNoticeState: String, CaseIterable, Equatable, Sendable {
    case tapGraphQuarantined = "MIC-01"
    case permissionDenied = "MIC-02"
    case selectedDeviceMissing = "MIC-03"
    case noInputDevice = "MIC-04"
    case ambiguousDevice = "MIC-05"
    case recordingDeviceDisconnected = "MIC-06"
    case startUnavailable = "MIC-07"
    case inputFormatUnconfirmed = "MIC-08"
    case buffersUnstable = "MIC-09"
    case unclassifiedStartFailure = "MIC-10"

    public var persistence: MicrophoneNoticePersistence {
        switch self {
        case .tapGraphQuarantined, .permissionDenied, .selectedDeviceMissing,
             .noInputDevice, .ambiguousDevice, .recordingDeviceDisconnected:
            return .required
        case .startUnavailable, .inputFormatUnconfirmed, .buffersUnstable, .unclassifiedStartFailure:
            return .conditional
        }
    }

    public var priority: Int {
        switch self {
        case .tapGraphQuarantined: return 1
        case .permissionDenied: return 2
        case .selectedDeviceMissing, .noInputDevice, .ambiguousDevice: return 3
        case .recordingDeviceDisconnected: return 4
        case .startUnavailable, .inputFormatUnconfirmed, .buffersUnstable: return 5
        case .unclassifiedStartFailure: return 6
        }
    }

    public var severity: MicrophoneNoticeSeverity {
        self == .tapGraphQuarantined ? .critical : .warning
    }

    public var allowsManualDismiss: Bool {
        switch self {
        case .recordingDeviceDisconnected, .startUnavailable, .inputFormatUnconfirmed,
             .buffersUnstable, .unclassifiedStartFailure:
            return true
        case .tapGraphQuarantined, .permissionDenied, .selectedDeviceMissing,
             .noInputDevice, .ambiguousDevice:
            return false
        }
    }

    public var title: String {
        switch self {
        case .tapGraphQuarantined: return "マイクを再利用できません"
        case .permissionDenied: return "マイクへのアクセスが許可されていません"
        case .selectedDeviceMissing: return "選択したマイクが未接続です"
        case .noInputDevice: return "使えるマイクが見つかりません"
        case .ambiguousDevice: return "マイクを特定できません"
        case .recordingDeviceDisconnected: return "録音中にマイクが切断されました"
        case .startUnavailable, .unclassifiedStartFailure: return "マイクを開始できませんでした"
        case .inputFormatUnconfirmed: return "マイクの入力形式を確認できません"
        case .buffersUnstable: return "マイクの準備が安定しません"
        }
    }

    public var message: String {
        switch self {
        case .tapGraphQuarantined:
            return "マイクの安全な状態を確認できません。アプリを再起動してください。"
        case .permissionDenied:
            return "macOS のシステム設定で、このアプリのマイク使用を許可してください。"
        case .selectedDeviceMissing:
            return "接続を確認するか、設定で別のマイクを選んでください。自動では切り替えません。"
        case .noInputDevice:
            return "マイクを接続するか、macOS のサウンド設定で入力デバイスを確認してください。"
        case .ambiguousDevice:
            return "同じ名前のマイクが重複している可能性があります。設定で選び直してください。"
        case .recordingDeviceDisconnected:
            return "マイクの接続が切れたため録音を停止しました。接続を確認してから再開してください。"
        case .startUnavailable:
            return "他のアプリが使用中か、マイクが応答していません。確認してからもう一度お試しください。"
        case .inputFormatUnconfirmed:
            return "マイクを再接続するか、設定で別のマイクを選んでからもう一度お試しください。"
        case .buffersUnstable:
            return "接続直後などで音声入力が不安定です。少し待ってからもう一度お試しください。"
        case .unclassifiedStartFailure:
            return "マイクの開始に失敗しました。接続や設定を確認して、もう一度お試しください。"
        }
    }

    public var primaryAction: MicrophoneNoticeAction {
        switch self {
        case .tapGraphQuarantined: return .restartApplication
        case .permissionDenied: return .openSystemSettings
        case .selectedDeviceMissing, .ambiguousDevice, .recordingDeviceDisconnected,
             .inputFormatUnconfirmed:
            return .openMicrophoneSettings
        case .noInputDevice: return .openSoundSettings
        case .startUnavailable, .buffersUnstable, .unclassifiedStartFailure:
            return .retryRecording
        }
    }

    public var secondaryAction: MicrophoneNoticeAction? {
        switch self {
        case .tapGraphQuarantined: return nil
        case .permissionDenied, .selectedDeviceMissing, .noInputDevice, .ambiguousDevice:
            return .retryRecording
        case .recordingDeviceDisconnected, .startUnavailable, .inputFormatUnconfirmed,
             .buffersUnstable, .unclassifiedStartFailure:
            return .dismiss
        }
    }

    public var menuBarTooltip: String {
        switch self {
        case .tapGraphQuarantined:
            return "マイク利用不可（アプリの再起動が必要です）"
        case .permissionDenied:
            return "マイク利用不可（マイク権限を確認してください）"
        case .selectedDeviceMissing, .noInputDevice, .ambiguousDevice:
            return "マイク利用不可（接続・マイク設定を確認してください）"
        case .recordingDeviceDisconnected, .startUnavailable, .inputFormatUnconfirmed,
             .buffersUnstable, .unclassifiedStartFailure:
            return "マイク開始に失敗しました（クリックして詳細を確認）"
        }
    }
}

public struct MicrophoneNotice: Equatable, Sendable {
    public let state: MicrophoneNoticeState
    public let context: MicrophoneNoticeContext

    public init(state: MicrophoneNoticeState, context: MicrophoneNoticeContext = .standard) {
        self.state = state
        self.context = context
    }

    public var title: String {
        guard state == .recordingDeviceDisconnected, context == .meeting else { return state.title }
        return "マイク切断により会議モードを終了しました"
    }

    public var message: String {
        guard state == .recordingDeviceDisconnected, context == .meeting else { return state.message }
        return "マイクの接続が切れたため会議モードを終了しました。接続を確認してから再開してください。"
    }

    public var primaryAction: MicrophoneNoticeAction { state.primaryAction }
    public var secondaryAction: MicrophoneNoticeAction? { state.secondaryAction }
    public var menuBarTooltip: String { state.menuBarTooltip }
}

public struct MicrophoneNoticeStore: Equatable, Sendable {
    public private(set) var current: MicrophoneNotice?

    public init() {}

    @discardableResult
    public mutating func recordFailure(
        _ state: MicrophoneNoticeState,
        timing: MicrophoneNoticeFailureTiming,
        context: MicrophoneNoticeContext = .standard
    ) -> Bool {
        guard timing == .finalFailure else { return false }
        if let current, current.state.priority < state.priority { return false }
        let next = MicrophoneNotice(state: state, context: context)
        if let current, current == next { return false }
        current = next
        return true
    }

    @discardableResult
    public mutating func recordSuccessfulStart() -> Bool {
        guard current != nil else { return false }
        current = nil
        return true
    }

    @discardableResult
    public mutating func dismissCurrent() -> Bool {
        guard let current, current.state.allowsManualDismiss else { return false }
        self.current = nil
        return true
    }
}

public protocol MicrophoneNoticeErrorIdentity {
    var microphoneNoticeState: MicrophoneNoticeState { get }
}

public enum MicrophoneNoticeClassifier {
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == 3072)
            || (error.domain == NSURLErrorDomain && error.code == -999)
    }

    public static func state(for error: Error) -> MicrophoneNoticeState? {
        guard !isCancellation(error) else { return nil }
        if let identified = error as? MicrophoneNoticeErrorIdentity {
            return identified.microphoneNoticeState
        }
        return .unclassifiedStartFailure
    }
}

extension MicrophoneSelectionError: MicrophoneNoticeErrorIdentity {
    public var microphoneNoticeState: MicrophoneNoticeState {
        switch self {
        case .noSystemInput: return .noInputDevice
        case .selectedDeviceMissing: return .selectedDeviceMissing
        case .ambiguousDevice: return .ambiguousDevice
        }
    }
}

extension MicrophoneStartupGate.Failure: MicrophoneNoticeErrorIdentity {
    public var microphoneNoticeState: MicrophoneNoticeState {
        self == .formatChanged ? .inputFormatUnconfirmed : .buffersUnstable
    }
}

#if os(macOS)
extension MicrophoneGraphError: MicrophoneNoticeErrorIdentity {
    package var microphoneNoticeState: MicrophoneNoticeState {
        switch self {
        case .quarantined: return .tapGraphQuarantined
        case .formatException: return .inputFormatUnconfirmed
        case .unknownException, .unexpectedTopology: return .unclassifiedStartFailure
        }
    }
}
#endif
