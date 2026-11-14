#if os(macOS)
import AppKit
import Foundation
import Combine
import ServiceManagement
import KoeBridgeCore

/// Reflects macOS Login Items state. Never stores a fictitious enabled flag,
/// registers automatically at launch, or bypasses the user's OS approval.
@MainActor final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var message = ""
    @Published private(set) var registrationAttempted = false

    init() {
        status = SMAppService.mainApp.status
    }

    private var registrationState: LoginItemRegistrationState {
        switch status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    var isRequested: Bool { LoginItemRegistrationPolicy.isRequested(registrationState) }
    var isActive: Bool { LoginItemRegistrationPolicy.isActive(registrationState) }

    /// A .notFound status must remain actionable: registering can sometimes
    /// establish the missing OS record. Actual success is checked afterwards.
    var canChange: Bool { registrationState != .unknown }

    var statusLabel: String {
        switch status {
        case .enabled: return "登録済み・自動起動ON"
        case .notRegistered: return "未登録"
        case .requiresApproval: return "登録済み・macOSの承認待ち"
        case .notFound: return "未確認（ONで登録を試行）"
        @unknown default: return "状態を確認できません"
        }
    }

    var needsSystemSettings: Bool { status == .requiresApproval || status == .notFound }

    var shouldShowManualAddHelp: Bool {
        registrationAttempted && (status == .notFound || status == .notRegistered)
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    /// Called only by the user's explicit Toggle. In particular, an initial
    /// .notFound never causes automatic changes at application startup.
    func setRequested(_ requested: Bool) {
        message = ""
        refresh()
        let action = LoginItemRegistrationPolicy.action(
            requested: requested, current: registrationState
        )
        switch action {
        case .none:
            return
        case .register:
            registrationAttempted = true
            var registrationError: String?
            do {
                try SMAppService.mainApp.register()
            } catch {
                DiagnosticLog.record("login item registration failed: \(error.localizedDescription)")
                registrationError = UserFacingErrorMessage.message(for: error, operation: "自動起動の登録")
            }
            refresh()
            if status == .enabled {
                message = "KoeBridgeの登録が完了し、ログイン時の自動起動が有効になりました。"
            } else if status == .requiresApproval {
                // Registration is real, but macOS (not this app) owns approval.
                message = "KoeBridgeを登録しました。macOSの「ログイン項目」で手動で許可してください。"
                SMAppService.openSystemSettingsLoginItems()
            } else {
                // Do not misrepresent a failed .notFound registration as a
                // registered app. Guide the user to the OS's manual add flow.
                let detail = registrationError.map { "（\($0)）" } ?? ""
                message = "自動登録を確認できませんでした\(detail)。ログイン項目の設定でKoeBridge.appを手動追加してください。"
                SMAppService.openSystemSettingsLoginItems()
            }
        case .unregister:
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                // Read back first; a concurrent OS-side removal is harmless.
                DiagnosticLog.record("login item unregistration failed: \(error.localizedDescription)")
                let detail = UserFacingErrorMessage.message(for: error, operation: "自動起動の登録解除")
                refresh()
                if status != .notRegistered {
                    message = "登録解除を確認できませんでした：\(detail)"
                }
                return
            }
            refresh()
            if status == .notRegistered {
                registrationAttempted = false
                message = "ログイン時の自動起動を解除しました。"
            } else {
                message = "解除後の状態を確認できませんでした。macOSのログイン項目を確認してください。"
            }
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
#endif
