#if os(macOS)
import AppKit
import Combine
import Sparkle
import KoeBridgeCore

/// Sparkle owns download, EdDSA validation, replacement and relaunch. The
/// existing GitHub metadata checker is informational only, never trusted as an
/// executable/signature source. No shell command runs from a release response.
@MainActor final class KoeBridgeInAppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = KoeBridgeInAppUpdater()
    @Published private(set) var blocksRecording = false
    @Published private(set) var message = ""
    private var installationCommitted = false
    private var noUpdateFound = false
    private var controller: SPUStandardUpdaterController?
    private var resumeInstallation: Task<Void, Never>?

    var configured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return SignedUpdateConfiguration.isReady(
            publicKey: info["SUPublicEDKey"] as? String, feed: info["SUFeedURL"] as? String,
            verifiesArchive: info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
            requiresSignedFeed: info["SURequireSignedFeed"] as? Bool == true,
            signatureExpiry: (info["SUSignedFeedFailureExpirationInterval"] as? NSNumber)?.doubleValue)
    }
    var explanation: String {
        configured
            ? "更新画面でダウンロードとインストールを確認すると、署名検証後にアプリを入れ替えて再起動します。"
            : "アプリ内インストールの署名設定が未登録です。現在はリリースページから手動更新してください。"
    }

    func checkForUpdates() {
        guard !VoiceController.shared.hasPendingWork else {
            message = "録音・文字起こし・入力が完了してから更新してください"
            return
        }
        guard configured else { message = explanation; return }
        do {
            if controller == nil {
                let candidate = SPUStandardUpdaterController(startingUpdater: false,
                    updaterDelegate: self, userDriverDelegate: nil)
                try candidate.updater.start()
                controller = candidate
            }
            guard let controller, controller.updater.canCheckForUpdates else { return }
            noUpdateFound = false
            blocksRecording = true
            message = "署名付きの更新情報を確認しています…"
            controller.checkForUpdates(nil)
        } catch {
            controller = nil
            blocksRecording = false
            message = "更新を開始できませんでした：\(error.localizedDescription)"
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard configured, !VoiceController.shared.hasPendingWork else {
            throw NSError(domain: "dev.koebridge.update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "録音・文字起こし・入力が完了してから更新してください"])
        }
        // Synchronous main-actor gate: a shortcut cannot sneak into the gap
        // between the readiness check and the asynchronous download dialog.
        blocksRecording = true
    }

    // Ignore any stale UserDefaults feed override. Only this pinned project feed
    // may be used; the signature key still comes exclusively from the bundle.
    func feedURLString(for updater: SPUUpdater) -> String? { SignedUpdateConfiguration.feedURL }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        message = "新しい版が見つかりました。更新画面からインストールできます"
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        noUpdateFound = true
        message = "このMacに適用できる新しい更新はありません"
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installationCommitted = true
        blocksRecording = true
        message = "検証済みの更新をインストールしています…"
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        blocksRecording = true
        guard VoiceController.shared.hasPendingWork else { return false }
        resumeInstallation?.cancel()
        resumeInstallation = Task { @MainActor [weak self] in
            while VoiceController.shared.hasPendingWork {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.resumeInstallation = nil
            installHandler()
        }
        return true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        resumeInstallation?.cancel(); resumeInstallation = nil
        installationCommitted = false
        blocksRecording = false
        if !noUpdateFound { message = "更新を完了できませんでした：\(error.localizedDescription)" }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if resumeInstallation == nil && !installationCommitted { blocksRecording = false }
        if let error, !noUpdateFound { message = "更新処理が終了しました：\(error.localizedDescription)" }
    }
}

extension KoeBridgeUpdateManager {
    var blocksRecording: Bool { KoeBridgeInAppUpdater.shared.blocksRecording }
}
#endif
