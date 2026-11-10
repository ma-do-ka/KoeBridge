#if os(macOS)
import SwiftUI
import KoeBridgeCore

struct SettingsVoicePage: View {
    @ObservedObject var controller: VoiceController
    let focusRequest: SettingsFocusRequest?

    var body: some View {
        SettingsPageScrollView(section: .voice, focusRequest: focusRequest) {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    VStack(spacing: 0) {
                        SettingsRow("文字起こしの方法",
                                    description: "音声を文字に変換する方法を選びます。GeminiはGoogleのAPIを使用し、AppleはこのMac内で処理します。") {
                            SettingsRecognitionPicker("文字起こしの方法", selection: $controller.requestedMode)
                            .pickerStyle(.segmented)
                            .frame(width: 245)
                        }
                        .id("engine")
                        Divider()
                        MicrophoneSettingsRow(controller: controller)
                        Divider()
                        SettingsRow("録音の開始・終了キー",
                                    description: "選んだキーと下の動作設定で録音を操作します。ほかのアプリのキー操作と競合する場合があります。") {
                            SettingsShortcutPicker("録音の開始・終了キー", selection: Binding(
                                get: { controller.shortcutChoice },
                                set: { controller.selectShortcut($0) }
                            ))
                            .frame(width: 250)
                        }
                        .id("shortcut")
                        SettingsInputControls(controller: controller)
                        if !controller.shortcutProblem.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(controller.shortcutProblem)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                SettingsRow("録音キーを再登録",
                                            description: "設定したキーが反応しない場合に、ショートカットの登録をやり直します。") {
                                    SettingsRowActionButton("再登録") { controller.retryShortcutRegistration() }
                                }
                            }
                        }
                        Divider()
                        SettingsRow("認識した文章を自動入力する",
                                    description: "録音終了後、元の入力欄への入力を試みます。オフの場合は文章を履歴に保存し、あとからコピーできます。", icon: "text.cursor") {
                            Toggle("認識した文章を自動入力する", isOn: $controller.automaticPaste)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .id("autopaste")
                    }
                    .padding(8)
                } label: {
                    Label("認識と入力の設定", systemImage: "slider.horizontal.3")
                }
                SettingsAppProfilesPage(controller: controller)
                    .id("app-profiles")
                SettingsSnippetsPage(controller: controller)
                GroupBox {
                    Text("選択テキストの音声変換: テキストを選択してショートカットを押し、変換の指示を話すと、選択範囲が書き換わります。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                } label: {
                    Label("選択テキストの音声変換", systemImage: "text.bubble")
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("クリップボードを使わず、認識した文章をキー入力として送信します。")
                        Text("入力先の変更や権限不足が検出された場合は自動入力を中止し、文章を直近\(RecentTranscriptArchive.maximumRecords)件の履歴に保存します。")
                        Text("右Commandなどの単独キーには入力監視の許可が必要な場合があります。FnキーはmacOSの割当と競合する場合があります。")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } label: {
                    Label("自動入力の安全確認", systemImage: "keyboard")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
