#if os(macOS)
import Foundation
import Combine
import ServiceManagement

/// The actual Login Items registration is owned by macOS, not UserDefaults.
/// The toggle always reflects the currently registered or pending OS state.
@MainActor final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var message = ""

    init() {
        status = SMAppService.mainApp.status
    }

    var isRequested: Bool {
        status == .enabled || status == .requiresApproval
    }

    var isActive: Bool { status == .enabled }

    var canChange: Bool { status != .notFound }

    var statusLabel: String {
        switch status {
        case .enabled: return "有効"
        case .notRegistered: return "無効"
        case .requiresApproval: return "macOSでの承認待ち"
        case .notFound: return "ログイン項目を認識できません"
        @unknown default: return "状態を確認できません"
        }
    }

    var needsSystemSettings: Bool {
        status == .requiresApproval || status == .notFound
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    /// Only register or unregister on an explicit user toggle. If macOS
    /// refuses the request the state is re-read; never show a fake success.
    func setRequested(_ requested: Bool) {
        message = ""
        refresh()
        guard canChange else {
            message = "macOSでログイン項目が見つかりません。KoeBridge.appを起動しているか確認してください。"
            return
        }
        guard requested != isRequested else { return }
        do {
            if requested {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = "ログイン項目を変更できませんでした：\(error.localizedDescription)"
        }
        refresh()
        if message.isEmpty && status == .requiresApproval {
            message = "macOSの「ログイン項目」でKoeBridgeを許可してください。承認前は自動起動しません。"
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
#endif
