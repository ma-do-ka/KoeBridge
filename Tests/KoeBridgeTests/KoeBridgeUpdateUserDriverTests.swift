#if os(macOS)
import AppKit
import Sparkle
import Testing
import KoeBridgeCore
@testable import KoeBridge

@MainActor struct KoeBridgeUpdateUserDriverTests {
    private func rawError(domain: String = "SUSparkleErrorDomain", code: Int = 3001) -> NSError {
        NSError(domain: domain, code: code, userInfo: [
            NSLocalizedDescriptionKey: "The update feed is improperly signed and could not be validated.",
            NSLocalizedRecoverySuggestionErrorKey: "Contact the developer for assistance."
        ])
    }

    @Test func menuCheckRefusesPendingWorkBeforeCheckingConfiguration() {
        _ = NSApplication.shared
        for configured in [false, true] {
            var status = ""
            var alerts = 0
            var openedSettings = 0
            var checks = 0
            let expected = "録音・文字起こし・入力が完了してから更新してください"
            KoeBridgeInAppUpdater.checkForUpdatesFromMenu(
                hasPendingWork: true, configured: configured, explanation: "署名設定の説明",
                setStatus: { status = $0 }, presentAlert: { alert in
                    alerts += 1
                    #expect(status == expected)
                    #expect(alert.messageText == "更新の確認")
                    #expect(alert.informativeText == expected)
                    #expect(alert.buttons.map(\.title) == ["閉じる"])
                    return .alertFirstButtonReturn
                }, showUpdatePage: { openedSettings += 1 }, check: { checks += 1 })
            #expect(status == expected)
            #expect(alerts == 1)
            #expect(openedSettings == 0)
            #expect(checks == 0)
        }
    }

    @Test func menuCheckOffersSettingsWhenSignedUpdatesAreUnconfigured() {
        _ = NSApplication.shared
        var status = ""
        var alerts = 0
        var openedSettings = 0
        var checks = 0
        let explanation = "アプリ内インストールの署名設定が未登録です。現在はリリースページから手動更新してください。"
        KoeBridgeInAppUpdater.checkForUpdatesFromMenu(
            hasPendingWork: false, configured: false, explanation: explanation,
            setStatus: { status = $0 }, presentAlert: { alert in
                alerts += 1
                #expect(status == explanation)
                #expect(alert.messageText == "更新の確認")
                #expect(alert.informativeText == explanation)
                #expect(alert.buttons.map(\.title) == ["設定のアップデート画面を開く", "閉じる"])
                #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
                return .alertFirstButtonReturn
            }, showUpdatePage: { openedSettings += 1 }, check: { checks += 1 })
        #expect(status == explanation)
        #expect(alerts == 1)
        #expect(openedSettings == 1)
        #expect(checks == 0)
    }

    @Test func menuCheckCanDismissUnconfiguredUpdatesWithoutOpeningSettings() {
        _ = NSApplication.shared
        var openedSettings = 0
        var checks = 0
        KoeBridgeInAppUpdater.checkForUpdatesFromMenu(
            hasPendingWork: false, configured: false, explanation: "署名設定の説明",
            setStatus: { _ in }, presentAlert: { _ in .alertSecondButtonReturn },
            showUpdatePage: { openedSettings += 1 }, check: { checks += 1 })
        #expect(openedSettings == 0)
        #expect(checks == 0)
    }

    @Test func menuCheckPassesThroughWhenReadyWithoutShowingSettingsOrAnEarlyAlert() {
        _ = NSApplication.shared
        var statuses: [String] = []
        var alerts = 0
        var openedSettings = 0
        var checks = 0
        KoeBridgeInAppUpdater.checkForUpdatesFromMenu(
            hasPendingWork: false, configured: true, explanation: "署名設定の説明",
            setStatus: { statuses.append($0) }, presentAlert: { _ in
                alerts += 1
                return .alertFirstButtonReturn
            }, showUpdatePage: { openedSettings += 1 }, check: { checks += 1 })
        #expect(statuses.isEmpty)
        #expect(alerts == 0)
        #expect(openedSettings == 0)
        #expect(checks == 1)
    }

    @Test func startupAndUpdaterErrorsShareMappedDelegateStatusAndAcknowledgeOnce() {
        _ = NSApplication.shared
        var status = ""
        var bodies: [String] = []
        var acknowledgements = 0
        let driver = KoeBridgeUpdateUserDriver(setStatus: { status = $0 },
            setCanCancel: { _ in }, setCanRetryTermination: { _ in }, presentAlert: { alert in
                bodies.append(alert.informativeText)
                #expect(alert.messageText == "更新を完了できませんでした")
                #expect(alert.buttons.map(\.title) == ["閉じる"])
                return .alertFirstButtonReturn
            })
        for error in [rawError(), rawError(domain: NSURLErrorDomain, code: -1009),
                      rawError(domain: "unknown.domain", code: 99)] {
            let expected = UserFacingErrorMessage.message(for: error, operation: "更新")
            #expect(KoeBridgeInAppUpdater.errorMessage(for: error) == expected)
            driver.showStartError(error)
            #expect(status == expected)
            driver.showUpdaterError(error) { acknowledgements += 1 }
            #expect(status == expected)
            #expect(bodies.suffix(2).allSatisfy { $0 == expected && !$0.contains(error.localizedDescription) })
        }
        #expect(acknowledgements == 3)
        #expect(bodies.count == 6)
    }

    @Test func noUpdateAlertOnlyAppearsForUserInitiatedChecks() {
        _ = NSApplication.shared
        var alerts = 0
        var acknowledgements = 0
        let driver = KoeBridgeUpdateUserDriver(setStatus: { _ in }, setCanCancel: { _ in },
            setCanRetryTermination: { _ in }, presentAlert: { alert in
                alerts += 1
                #expect(alert.informativeText == "このMacに適用できる新しい更新はありません")
                return .alertFirstButtonReturn
            })
        driver.showUpdateNotFoundWithError(rawError(code: 1001)) { acknowledgements += 1 }
        #expect(alerts == 0)
        driver.showUserInitiatedUpdateCheck(cancellation: {})
        driver.showUpdateNotFoundWithError(rawError(code: 1001)) { acknowledgements += 1 }
        #expect(alerts == 1)
        driver.dismissUpdateInstallation()
        driver.showUpdateNotFoundWithError(rawError(code: 1001)) { acknowledgements += 1 }
        #expect(alerts == 1)
        #expect(acknowledgements == 3)
    }

    @Test func checkingAndDownloadCancellationAreOneShotAndUnavailableDuringExtraction() {
        var status = ""
        var canCancel = false
        var cancellations = 0
        let driver = KoeBridgeUpdateUserDriver(setStatus: { status = $0 },
            setCanCancel: { canCancel = $0 }, setCanRetryTermination: { _ in })
        driver.showUserInitiatedUpdateCheck { cancellations += 1 }
        #expect(canCancel)
        driver.cancelUpdate()
        driver.cancelUpdate()
        #expect(!canCancel)
        #expect(cancellations == 1)
        #expect(status == "更新をキャンセルしました")
        driver.showDownloadInitiated { cancellations += 1 }
        #expect(canCancel)
        driver.showDownloadDidStartExtractingUpdate()
        driver.cancelUpdate()
        #expect(!canCancel)
        #expect(cancellations == 1)
    }

    @Test func invalidProgressDoesNotOverflowAndAllProgressRemainsJapanese() {
        var status = ""
        let driver = KoeBridgeUpdateUserDriver(setStatus: { status = $0 },
            setCanCancel: { _ in }, setCanRetryTermination: { _ in })
        driver.showDownloadInitiated(cancellation: {})
        #expect(status == "更新をダウンロードしています…")
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 25)
        #expect(status.hasSuffix("25％"))
        driver.showDownloadDidReceiveData(ofLength: UInt64.max)
        #expect(status.hasSuffix("100％"))
        driver.showDownloadDidReceiveExpectedContentLength(0)
        #expect(status == "更新をダウンロードしています…")
        for (progress, expected) in [(Double.nan, 0), (-1.0, 0), (0.5, 50), (2.0, 100)] {
            driver.showExtractionReceivedProgress(progress)
            #expect(status == "更新ファイルを展開しています… \(expected)％")
        }
    }

    @Test func installChoicesAndTerminationRetryPreserveSparkleFlow() {
        _ = NSApplication.shared
        var response: NSApplication.ModalResponse = .alertFirstButtonReturn
        var status = ""
        var canRetry = false
        var retries = 0
        var acknowledgements = 0
        let driver = KoeBridgeUpdateUserDriver(setStatus: { status = $0 },
            setCanCancel: { _ in }, setCanRetryTermination: { canRetry = $0 }, presentAlert: { alert in
                #expect(alert.buttons.map(\.title) == ["インストールして再起動", "あとで", "更新をキャンセル"])
                #expect(alert.informativeText.contains("完了するまで再起動を待ちます"))
                return response
            })
        for (selection, expected) in [(NSApplication.ModalResponse.alertFirstButtonReturn, SPUUserUpdateChoice.install),
                                       (.alertSecondButtonReturn, .dismiss), (.alertThirdButtonReturn, .skip)] {
            response = selection
            var replies: [SPUUserUpdateChoice] = []
            driver.showReady(toInstallAndRelaunch: { replies.append($0) })
            #expect(replies == [expected])
        }
        driver.showInstallingUpdate(withApplicationTerminated: false) { retries += 1 }
        #expect(canRetry)
        driver.retryTermination()
        #expect(retries == 1)
        driver.showInstallingUpdate(withApplicationTerminated: true) { retries += 1 }
        driver.retryTermination()
        #expect(!canRetry)
        #expect(retries == 1)
        driver.showUpdateInstalledAndRelaunched(true) { acknowledgements += 1 }
        #expect(status == "更新が完了し、アプリを再起動しました")
        #expect(acknowledgements == 1)
        driver.showInstallingUpdate(withApplicationTerminated: false) { retries += 1 }
        driver.dismissUpdateInstallation()
        driver.retryTermination()
        #expect(!canRetry)
        #expect(retries == 1)
    }

    @Test func teardownOrNestedErrorCannotSubmitAnObsoleteInstallDecision() {
        _ = NSApplication.shared
        var driver: KoeBridgeUpdateUserDriver!
        var status = ""
        var showNestedError = false
        var replies = 0
        var acknowledgements = 0
        driver = KoeBridgeUpdateUserDriver(setStatus: { status = $0 },
            setCanCancel: { _ in }, setCanRetryTermination: { _ in }, presentAlert: { alert in
                if alert.messageText == "インストールして再起動しますか？" {
                    if showNestedError {
                        driver.showUpdaterError(rawError()) { acknowledgements += 1 }
                    } else {
                        driver.dismissUpdateInstallation()
                    }
                }
                return .alertFirstButtonReturn
            })
        driver.showReady(toInstallAndRelaunch: { _ in replies += 1 })
        #expect(replies == 0)
        showNestedError = true
        driver.showReady(toInstallAndRelaunch: { _ in replies += 1 })
        #expect(replies == 0)
        #expect(acknowledgements == 1)
        #expect(status == KoeBridgeInAppUpdater.errorMessage(for: rawError()))
    }
}
#endif
