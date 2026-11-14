#if os(macOS)
import AppKit
import Sparkle
import KoeBridgeCore

/// App-owned Japanese UI. Sparkle continues to own validation and installation.
@MainActor final class KoeBridgeUpdateUserDriver: NSObject, SPUUserDriver {
    private let setStatus: (String) -> Void
    private let setCanCancel: (Bool) -> Void
    private let setCanRetryTermination: (Bool) -> Void
    private let presentAlert: (NSAlert) -> NSApplication.ModalResponse
    private var activeAlert: NSAlert?
    private var presentationGeneration: UInt = 0
    private var userInitiated = false
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var cancellation: (() -> Void)? {
        didSet { setCanCancel(cancellation != nil) }
    }
    private var retryTerminatingApplication: (() -> Void)? {
        didSet { setCanRetryTermination(retryTerminatingApplication != nil) }
    }

    // The presenter seam permits testing decisions and mapped error bodies without UI.
    init(setStatus: @escaping (String) -> Void,
         setCanCancel: @escaping (Bool) -> Void,
         setCanRetryTermination: @escaping (Bool) -> Void,
         presentAlert: @escaping (NSAlert) -> NSApplication.ModalResponse = {
             NSApp.activate(ignoringOtherApps: true)
             return $0.runModal()
         }) {
        self.setStatus = setStatus
        self.setCanCancel = setCanCancel
        self.setCanRetryTermination = setCanRetryTermination
        self.presentAlert = presentAlert
        super.init()
    }

    private func alert(_ title: String, body: String, buttons: [String],
                       style: NSAlert.Style = .informational) -> NSApplication.ModalResponse? {
        dismissActiveAlert()
        let generation = presentationGeneration
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = style
        for title in buttons { alert.addButton(withTitle: title) }
        if alert.buttons.count > 1 { alert.buttons[1].keyEquivalent = "\u{1b}" }
        activeAlert = alert
        defer { if activeAlert === alert { activeAlert = nil } }
        let response = presentAlert(alert)
        // Sparkle may tear down or replace UI from the modal run loop. Do not
        // answer an obsolete decision or change a newer cycle's status afterwards.
        return generation == presentationGeneration ? response : nil
    }

    private func dismissActiveAlert() {
        presentationGeneration &+= 1
        if let activeAlert {
            if NSApp.modalWindow === activeAlert.window { NSApp.abortModal() }
            activeAlert.window.orderOut(nil)
            self.activeAlert = nil
        }
    }

    func presentInformationalAlert(title: String, body: String, primaryButton: String,
                                   secondaryButton: String?) -> NSApplication.ModalResponse? {
        alert(title, body: body, buttons: [primaryButton] + (secondaryButton.map { [$0] } ?? []))
    }

    private func clearActions() {
        cancellation = nil
        retryTerminatingApplication = nil
    }

    func cancelUpdate() {
        guard let cancel = cancellation else { return }
        cancellation = nil // A Sparkle cancellation handler is consumed only once.
        setStatus("更新をキャンセルしました")
        cancel()
    }

    func retryTermination() {
        guard let retry = retryTerminatingApplication else { return }
        setStatus("アプリを終了して更新を再試行しています…")
        retry()
    }

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        clearActions()
        guard let response = alert("更新を自動的に確認しますか？",
            body: "新しいバージョンがあるか定期的に確認します。ダウンロードとインストールには確認が必要です。",
            buttons: ["自動で確認する", "今はしない"]) else { return }
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: response == .alertFirstButtonReturn,
            automaticUpdateDownloading: NSNumber(value: false), sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
        clearActions()
        self.cancellation = cancellation
        setStatus("署名付きの更新情報を確認しています…")
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        clearActions()
        userInitiated = state.userInitiated
        let version = appcastItem.displayVersionString
        let notes = "更新内容の詳細は公式リリースページで確認できます。"
        if appcastItem.isInformationOnlyUpdate {
            guard let result = alert("新しいバージョンがあります",
                body: "バージョン \(version) の案内が利用できます。この更新はアプリ内でインストールできません。",
                buttons: ["案内を開く", "あとで"]) else { return }
            if result == .alertFirstButtonReturn, let url = appcastItem.infoURL {
                NSWorkspace.shared.open(url)
            }
            setStatus("更新の案内を確認しました")
            reply(.dismiss) // Information-only items must never receive .install.
            return
        }
        let action: String
        switch state.stage {
        case .notDownloaded: action = "ダウンロードしてインストール"
        case .downloaded: action = "インストール"
        case .installing: action = "インストールして再起動"
        @unknown default: action = "更新を続ける"
        }
        let installationNotice = state.stage == .installing
            ? "\nKoeBridgeを終了して更新し、再起動します。あとで行う場合も、次回のアプリ終了時に更新されることがあります。" : ""
        var buttons = [action, "あとで"]
        if !appcastItem.isCriticalUpdate { buttons.append("このバージョンをスキップ") }
        guard let result = alert("新しいバージョンがあります",
            body: "バージョン \(version) に更新できます。\n\(notes)\(installationNotice)", buttons: buttons) else { return }
        if result == .alertFirstButtonReturn {
            setStatus("署名を検証して更新を準備しています…")
            reply(.install)
        } else if result == .alertThirdButtonReturn {
            setStatus("このバージョンの更新をスキップしました")
            reply(.skip)
        } else {
            setStatus("更新を見送りました。あとで更新を確認できます")
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // No feed notes are shipped today. Never render remote HTML or error prose.
        // The update decision always includes a Japanese pointer to the release page.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        DiagnosticLog.record("updater release notes failed: \(error.localizedDescription)")
        setStatus(UserFacingErrorMessage.message(for: error, operation: "更新内容の取得"))
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        clearActions()
        let message = "このMacに適用できる新しい更新はありません"
        setStatus(message)
        if userInitiated { _ = alert("更新の確認", body: message, buttons: ["閉じる"]) }
        acknowledgement()
    }

    func showStartError(_ error: Error) {
        showUpdaterError(error, acknowledgement: {})
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        clearActions()
        DiagnosticLog.record("updater UI error: \(error.localizedDescription)")
        let message = KoeBridgeInAppUpdater.errorMessage(for: error)
        setStatus(message)
        _ = alert("更新を完了できませんでした", body: message, buttons: ["閉じる"], style: .warning)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        clearActions()
        expectedBytes = 0
        receivedBytes = 0
        self.cancellation = cancellation
        showDownloadProgress()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
        showDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (total, overflow) = receivedBytes.addingReportingOverflow(length)
        receivedBytes = overflow ? UInt64.max : total
        showDownloadProgress()
    }

    private func showDownloadProgress() {
        if expectedBytes > 0 {
            let percent = Int(min(1, Double(receivedBytes) / Double(expectedBytes)) * 100)
            setStatus("更新をダウンロードしています… \(percent)％")
        } else {
            setStatus("更新をダウンロードしています…")
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        clearActions() // Sparkle no longer allows cancellation after extraction begins.
        setStatus("署名を検証して更新ファイルを展開しています…")
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        let fraction = progress.isFinite ? min(1, max(0, progress)) : 0
        setStatus("更新ファイルを展開しています… \(Int(fraction * 100))％")
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        clearActions()
        setStatus("更新の準備ができました。インストールと再起動を確認してください")
        guard let response = alert("インストールして再起動しますか？",
            body: "KoeBridgeを終了して更新します。録音・文字起こし・入力が残っている場合は、完了するまで再起動を待ちます。あとで行う場合も、次回のアプリ終了時に更新されることがあります。",
            buttons: ["インストールして再起動", "あとで", "更新をキャンセル"]) else { return }
        switch response {
        case .alertFirstButtonReturn:
            setStatus("検証済みの更新をインストールして再起動します…")
            reply(.install)
        case .alertThirdButtonReturn:
            setStatus("更新をキャンセルしました")
            reply(.skip) // At this stage .skip cancels installation without skipping the version.
        default:
            setStatus("更新を保留しました。次回のアプリ終了時に更新されることがあります")
            reply(.dismiss)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        clearActions()
        if !applicationTerminated { self.retryTerminatingApplication = retryTerminatingApplication }
        setStatus(applicationTerminated
            ? "検証済みの更新をインストールしています…"
            : "アプリの終了を待っています。更新後に再起動します…")
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        clearActions()
        setStatus(relaunched ? "更新が完了し、アプリを再起動しました" : "更新が完了しました")
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        clearActions()
        userInitiated = false
        expectedBytes = 0
        receivedBytes = 0
        dismissActiveAlert()
    }

    func showUpdateInFocus() {
        NSApp.activate(ignoringOtherApps: true)
        if let activeAlert { activeAlert.window.makeKeyAndOrderFront(nil) }
        else { (NSApp.delegate as? KoeBridgeAppDelegate)?.showUpdateProgress() }
    }
}
#endif
