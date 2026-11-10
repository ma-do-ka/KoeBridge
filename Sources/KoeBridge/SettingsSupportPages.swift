#if os(macOS)
import AppKit
import SwiftUI
import KoeBridgeCore

struct SettingsHelpPage: View {
    let shortcutLabel: String
    let focusRequest: SettingsFocusRequest?
    let navigate: (SettingsSection) -> Void

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("1. 文字を入力したいアプリの入力欄を選びます。", systemImage: "cursorarrow.click.2")
                        Label("2. 設定したキーで録音を開始します。", systemImage: "mic")
                        Label("3. トグルは再度押して確定、ホールドは離して確定、ハイブリッドは短押しで固定・長押し後に離して確定します。", systemImage: "checkmark.circle")
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
                        Button("利用許可を確認") { navigate(.permissions) }.settingsControlFocus("help")
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
            .settingsTarget("help")
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsAboutPage: View {
    @ObservedObject var updater: KoeBridgeUpdateManager
    @ObservedObject private var nativeUpdater = KoeBridgeInAppUpdater.shared
    let focusRequest: SettingsFocusRequest?

    let shortcutLabel: String
    let navigate: (SettingsSection) -> Void

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
                                 destination: URL(string: "https://github.com/ma-do-ka/KoeBridge")!).settingsControlFocus("about")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("アプリについて", systemImage: "info.circle")
                }
                .settingsTarget("about")

                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsRow("アップデートを自動的に確認",
                                    description: "1日1回を上限に、正式リリースと公式ソースの更新を確認します。自動インストールはしません。",
                                    icon: "arrow.clockwise") {
                            Toggle("自動更新確認", isOn: $updater.automaticChecksEnabled).settingsControlFocus("updates")
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        Divider()
                        SettingsRow("アップデートを自動的にダウンロードしてインストール",
                                    description: "無人でのインストールは行いません。アプリ内更新では、更新画面で確認してからインストールします。",
                                    icon: "square.and.arrow.down") {
                            Toggle("自動ダウンロードとインストール", isOn: .constant(false))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(true)
                                .help("インストールには更新画面での確認が必要です")
                        }
                        Divider()
                        SettingsRow("アップデートチャンネル",
                                    description: "正式リリースと、手動ビルド用の公式mainソースを分けて案内します。",
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
                                Text(nativeUpdater.message.isEmpty ? updater.statusMessage : nativeUpdater.message)
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
                                Task {
                                    await updater.checkNow()
                                    if nativeUpdater.configured { nativeUpdater.checkForUpdates() }
                                }
                            }
                            .disabled(updater.state == .checking || nativeUpdater.blocksRecording)
                        }
                        .padding(.vertical, 12)
                        if updater.hasNewStableRelease {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("新しい正式版が利用できます", systemImage: "arrow.down.circle.fill")
                                    .foregroundStyle(Color.green)
                                HStack(spacing: 10) {
                                    Button("ダウンロードしてインストール…") { nativeUpdater.checkForUpdates() }
                                        .disabled(!nativeUpdater.configured || nativeUpdater.blocksRecording)
                                    Button("リリースを見る") { updater.openLatestRelease() }
                                }
                            }
                            .font(.caption)
                            .padding(.bottom, 8)
                        }
                        Text(nativeUpdater.explanation)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider().padding(.vertical, 12)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ソース更新（手動ビルド）").font(.headline)
                            Text(updater.sourceStatusMessage)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(updater.copiedCommand ? "コピーしました" : "更新コマンドをコピー") {
                                _ = updater.copyUpdateCommand()
                            }
                            .disabled(!updater.canCopyUpdateCommand || nativeUpdater.blocksRecording)
                            Text("KoeBridgeを終了し、ターミナルで実行してください。Swiftと署名環境が必要です。ユーザーフォルダのKoeBridgeでテスト・ビルドし、dist/KoeBridge.appを起動します。別の場所にあるアプリは置き換えません。未保存の変更がある場合は停止します。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let checked = updater.lastCheckedAt {
                            Text("GitHubリリースの最終確認：\(checked.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("アップデート", systemImage: "arrow.triangle.2.circlepath")
                }
                .settingsTarget("updates")
                SettingsHelpPage(shortcutLabel: shortcutLabel, focusRequest: focusRequest, navigate: navigate)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { updater.checkIfDue() }
    }
}
#endif
