#if os(macOS)
import AppKit
import Combine
import Foundation

@MainActor final class DeveloperDiagnosticsController: ObservableObject {
    static let shared = DeveloperDiagnosticsController()

    @Published private(set) var enabled: Bool
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
                await MainActor.run {
                    self.statusMessage = "開発用診断フォルダーを準備できません：\(error.localizedDescription)"
                }
            }
        }
    }

    func disableAndDelete() {
        DeveloperDiagnostics.disablePreference()
        enabled = false
        statusMessage = "開発用診断を停止し、保存データを削除しています…"
        Task {
            do {
                try await DeveloperDiagnosticsStore.shared.deleteAll()
                await MainActor.run {
                    self.statusMessage = "開発用診断を停止し、保存データを削除しました。"
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "開発用診断は停止しましたが、保存データを削除できません：\(error.localizedDescription)"
                }
            }
        }
    }

    func deleteData() {
        _ = DeveloperDiagnostics.rotateEpochKeepingPreference()
        statusMessage = "開発用診断データを削除しています…"
        Task {
            do {
                try await DeveloperDiagnosticsStore.shared.deleteAll()
                if let token = DeveloperDiagnostics.token {
                    try await DeveloperDiagnosticsStore.shared.prepare(token: token)
                }
                await MainActor.run {
                    self.statusMessage = "開発用診断データを削除しました。"
                }
            } catch {
                await MainActor.run {
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
