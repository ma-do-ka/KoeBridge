#if os(macOS)
import AppKit
import SwiftUI
import KoeBridgeCore

struct SettingsHelpPage: View {
    let shortcutLabel: String
    let focusRequest: SettingsFocusRequest?
    let navigate: (SettingsSection) -> Void

    var body: some View {
        SettingsPageScrollView(section: .help, focusRequest: focusRequest) {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("1. 文字を入力したいアプリの入力欄を選びます。", systemImage: "cursorarrow.click.2")
                        Label("2. 設定したキーで録音を開始します。", systemImage: "mic")
                        Label("3. 同じキーで録音を終了し、確定処理が終わると自動入力を試みます。", systemImage: "checkmark.circle")
                        Text("現在の録音キー：\(shortcutLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } label: { Label("基本操作", systemImage: "list.number") }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("音声入力できないとき")
                            .font(.headline)
                        Text("利用許可を確認し、マイクと文字の入力操作が許可されているか確認してください。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("利用許可を確認") { navigate(.permissions) }
                        Divider()
                        Text("自動入力だけができないとき")
                            .font(.headline)
                        Text("元の入力欄が選択されたままか確認してください。履歴から文章をコピーすることもできます。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("履歴と記録を開く") { navigate(.history) }
                        Divider()
                        Text("Geminiが使えないとき")
                            .font(.headline)
                        Text("APIキーの登録状況やネットワーク接続を確認します。Appleへの自動切替が行われる場合もあります。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Geminiの設定を開く") { navigate(.gemini) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } label: { Label("トラブル対処", systemImage: "wrench.and.screwdriver") }
            }
            .id("help")
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsAboutPage: View {
    @ObservedObject var updater: KoeBridgeUpdateManager
    let focusRequest: SettingsFocusRequest?

    var body: some View {
        SettingsPageScrollView(section: .about, focusRequest: focusRequest) {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    HStack(alignment: .center, spacing: 18) {
                        Group {
                            if let url = Bundle.main.url(forResource: "KoeBridge_AppIcon", withExtension: "icns"),
                               let img = NSImage(contentsOf: url) {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                Image(systemName: "waveform")
                                    .resizable()
                                    .scaledToFit()
                                    .padding(18)
                            }
                        }
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("KoeBridge")
                                .font(.system(size: 22, weight: .semibold))
                            Text("バージョン \(updater.installedLabel)")
                                .font(.headline)
                            Text("ビルド：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未取得")")
                                .foregroundStyle(.secondary)
                            Text("macOS用音声入力アプリ / MIT License")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Link("公式GitHubリポジトリ",
                                 destination: URL(string: "https://github.com/ma-do-ka/KoeBridge")!)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("アプリについて", systemImage: "info.circle")
                }
                .id("about")

                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsRow("アップデートを自動的に確認",
                                    description: "1日1回を上限に、GitHubの正式リリースを確認します。",
                                    icon: "arrow.clockwise") {
                            Toggle("自動更新確認", isOn: $updater.automaticChecksEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        Divider()
                        SettingsRow("アップデートを自動的にダウンロードしてインストール",
                                    description: "開発版アプリは手動でダウンロードできます。公証済みの自動更新パッケージは未提供のため、自動インストールは利用できません。",
                                    icon: "square.and.arrow.down") {
                            Toggle("自動ダウンロードとインストール", isOn: .constant(false))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(true)
                                .help("公証済みアプリと安全な更新署名の準備が必要です")
                        }
                        Divider()
                        SettingsRow("アップデートチャンネル",
                                    description: "現在は正式版（Stable）のみが対象です。",
                                    icon: "checkmark.seal") {
                            Text(updater.channelName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 100, alignment: .trailing)
                        }
                        Divider()
                        HStack(alignment: .center, spacing: 14) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("現在：v\(updater.installedLabel)")
                                    .font(.system(size: 14, weight: .semibold))
                                Text(updater.statusMessage)
                                    .font(.caption)
                                    .foregroundStyle(updater.state == .failed ? Color.orange : Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if updater.state == .checking {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Button("アップデートを確認…") {
                                Task { await updater.checkNow() }
                            }
                            .disabled(updater.state == .checking)
                        }
                        .padding(.vertical, 12)
                        if updater.state == .available {
                            HStack(spacing: 10) {
                                Label("新しい正式版が利用できます", systemImage: "arrow.down.circle.fill")
                                    .foregroundStyle(Color.green)
                                Spacer()
                                Button("リリースを見る") { updater.openLatestRelease() }
                                Button("更新コマンドをコピー") {
                                    _ = updater.copyUpdateCommand()
                                }
                            }
                            .font(.caption)
                            .padding(.bottom, 8)
                            Text("KoeBridgeを終了して、コピーしたコマンドをターミナルで実行してください。ビルド・署名・アプリの再起動を行います。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("自動インストールには対応していません。新しい正式版が出た場合、更新方法をここから案内します。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let checked = updater.lastCheckedAt {
                            Text("最終確認：\(checked.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("アップデート", systemImage: "arrow.triangle.2.circlepath")
                }
                .id("updates")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { updater.checkIfDue() }
    }
}
#endif
