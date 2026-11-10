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
                            .settingsControlFocus("engine")
                            .pickerStyle(.segmented)
                            .frame(width: 245)
                        }
                        .settingsTarget("engine")
                        Divider()
                        Text(controller.localBackendStatus).font(.caption).foregroundStyle(.secondary)
                        MicrophoneSettingsRow(controller: controller)
                        Divider()
                        Divider()
                        SettingsRow("認識した文章を自動入力する",
                                    description: "録音終了後、元の入力欄への入力を試みます。オフの場合は文章を履歴に保存し、あとからコピーできます。", icon: "text.cursor") {
                            Toggle("認識した文章を自動入力する", isOn: $controller.automaticPaste)
                                .settingsControlFocus("autopaste").labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .settingsTarget("autopaste")
                    }
                    .padding(8)
                } label: {
                    Label("認識と入力の設定", systemImage: "slider.horizontal.3")
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("音声コマンドを有効にする", isOn: $controller.voiceCommandsEnabled).settingsControlFocus("voice-commands")
                        Text(controller.voiceCommandsEnabled
                             ? "発話全体が固定フレーズと一致した場合だけ実行します。"
                             : "音声コマンドはオフです。有効にすると、各コマンドを個別に選べます。発話全体の一致が必要です。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(VoiceCommandID.allCases) { command in
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle("「\(command.phrase)」", isOn: Binding(
                                    get: { controller.enabledVoiceCommands.contains(command) },
                                    set: { enabled in
                                        if enabled { controller.enabledVoiceCommands.insert(command) }
                                        else { controller.enabledVoiceCommands.remove(command) }
                                    }))
                                Text(command.effect).font(.caption).foregroundStyle(.secondary)
                                if command != .cancelTake {
                                    Text("チャットアプリなどでは送信される場合があります")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .disabled(!controller.voiceCommandsEnabled)
                        }
                    }.padding(8)
                } label: {
                    Label("音声コマンド", systemImage: "waveform")
                }.settingsTarget("voice-commands")
                SettingsSnippetsPage(controller: controller).settingsTarget("snippets")
                GroupBox("録音プレビュー") {
                    Toggle("確定した部分をプレビューで区別する", isOn: $controller.progressivePreviewEnabled).settingsControlFocus("preview")
                    Text("濃い文字は確定部分、薄い文字は暫定部分です。入力は確認後に一度だけ行います。").font(.caption)
                }.settingsTarget("preview")
                MeetingAndRetentionSettings(showMeeting: true).settingsTarget("meeting")
                GroupBox {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("クリップボードを使わず、認識した文章をキー入力として送信します。")
                        Text("入力先の変更や権限不足が検出された場合は自動入力を中止し、文章を直近\(RecentTranscriptArchive.maximumRecords)件の履歴に保存します。")
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
