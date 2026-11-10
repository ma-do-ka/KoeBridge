#if os(macOS)
import SwiftUI
import KoeBridgeCore

struct SettingsPrivacyPage: View {
    let historyCount: Int
    @Binding var diagnosticsEnabled: Bool
    let logNotice: String
    let focusRequest: SettingsFocusRequest?
    let showHistory: () -> Void
    let requestLogDeletion: () -> Void

    var body: some View {
        SettingsPageScrollView(section: .history, focusRequest: focusRequest) {
            VStack(alignment: .leading, spacing: 18) {
                MeetingAndRetentionSettings()
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsRow("保存件数：\(historyCount) / \(RecentTranscriptArchive.maximumRecords)件",
                                    description: "直近\(RecentTranscriptArchive.maximumRecords)件の文字起こし結果をMacに保存します。音声は保存設定を有効にした場合のみ別ファイルに保存します。APIキーは履歴に保存しません。") {
                            SettingsRowActionButton("文章を見る") { showHistory() }
                        }
                        .id("history")
                        Text("保存先：~/Library/Application Support/KoeBridge/recent-transcripts.json")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                } label: {
                    Label("文字起こし履歴", systemImage: "clock.arrow.circlepath")
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        SettingsRow("問題調査用の記録を残す",
                                    description: "入力できなかった段階、入力先アプリの識別子、確認結果や処理時間をこのMacに保存します。通常はオフで問題ありません。認識した文章・入力欄の本文・音声・APIキー・ウィンドウ名・URLは記録しません。", icon: "stethoscope") {
                            Toggle("問題調査用の記録を残す", isOn: Binding(
                                get: { diagnosticsEnabled },
                                set: { enabled in
                                    diagnosticsEnabled = enabled
                                    // Consent changes synchronously with the
                                    // control, even if SwiftUI coalesces redraws.
                                    DiagnosticLog.preferenceDidChange(enabled)
                                }
                            ))
                                .id("logging")
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .onChange(of: diagnosticsEnabled) { _, enabled in
                                    if enabled {
                                        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                                        DiagnosticLog.record("diagnostics enabled; version=\(version)")
                                    }
                                }
                        }
                        Divider()
                        SettingsRow("動作記録を削除",
                                    description: "保存済みの動作記録だけを削除します。文字起こし履歴や設定は変更されません。", icon: "trash") {
                            SettingsRowActionButton("削除", role: .destructive) { requestLogDeletion() }
                        }
                        Text("保存先：~/Library/Logs/KoeBridge.log")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("1ファイル192KB、古いログ1件を含め最大約384KB。記録をオフにしても以前のログは残ります。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !logNotice.isEmpty {
                            Text(logNotice).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("動作記録", systemImage: "stethoscope")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
