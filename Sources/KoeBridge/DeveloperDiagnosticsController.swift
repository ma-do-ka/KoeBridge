#if os(macOS)
import AppKit
import Combine
import Foundation

@MainActor final class DeveloperDiagnosticsController: ObservableObject {
    static let shared = DeveloperDiagnosticsController()

    @Published private(set) var enabled: Bool
    @Published private(set) var isDeleting = false
    @Published private(set) var statusMessage = ""

    private init() {
        enabled = DeveloperDiagnostics.isEnabled
    }

    func enable() {
        let token = DeveloperDiagnostics.enablePreference()
        enabled = true
        statusMessage = "開発用診断を有効にしました。音声サンプルと認識文字列をこのMac内だけに保存します。"
        Task {
            do {
                try await DeveloperDiagnosticsStore.shared.prepare(token: token)
            } catch {
                DeveloperDiagnostics.disablePreference()
                try? await DeveloperDiagnosticsStore.shared.deleteAllIfStillDisabled()
                await MainActor.run {
                    self.enabled = false
                    self.statusMessage = "開発用診断を開始できなかったため停止しました：\(error.localizedDescription)"
                }
            }
        }
    }

    func disableAndDelete() {
        guard !isDeleting else { return }
        DeveloperDiagnostics.disablePreference()
        enabled = false
        isDeleting = true
        statusMessage = "開発用診断を停止し、保存データを削除しています…"
        Task {
            do {
                try await DeveloperDiagnosticsStore.shared.deleteAllIfStillDisabled()
                await MainActor.run {
                    self.isDeleting = false
                    self.statusMessage = DeveloperDiagnostics.isEnabled
                        ? "開発用診断は再度有効になったため、新しい診断データは保持します。"
                        : "開発用診断を停止し、保存データを削除しました。"
                }
            } catch {
                await MainActor.run {
                    self.isDeleting = false
                    self.statusMessage = "開発用診断は停止しましたが、保存データを削除できません：\(error.localizedDescription)"
                }
            }
        }
    }

    func deleteData() {
        guard !isDeleting else { return }
        _ = DeveloperDiagnostics.rotateEpochKeepingPreference()
        isDeleting = true
        statusMessage = "開発用診断データを削除しています…"
        Task {
            do {
                try await DeveloperDiagnosticsStore.shared.deleteAll()
                if let token = DeveloperDiagnostics.token {
                    try await DeveloperDiagnosticsStore.shared.prepare(token: token)
                }
                await MainActor.run {
                    self.isDeleting = false
                    self.statusMessage = "開発用診断データを削除しました。"
                }
            } catch {
                await MainActor.run {
                    self.isDeleting = false
                    self.statusMessage = "開発用診断データを削除できません：\(error.localizedDescription)"
                }
            }
        }
    }

    func revealInFinder() {
        let token = DeveloperDiagnostics.token
        Task {
            do {
                let url = try await DeveloperDiagnosticsStore.shared.prepareForReveal(token: token)
                await MainActor.run {
                    guard let url else {
                        self.statusMessage = "開発用診断データはまだありません。"
                        return
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "開発用診断フォルダーを開けません：\(error.localizedDescription)"
                }
            }
        }
    }
}
#endif
