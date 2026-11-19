#if os(macOS)
import SwiftUI

struct MeetingAndRetentionSettings: View {
    @ObservedObject private var controller = VoiceController.shared
    @ObservedObject private var guide = PermissionGuide.shared
    let showMeeting: Bool
    @State private var confirmClear = false
    @State private var turningOff = false
    var body: some View {
        GroupBox(showMeeting ? "会議モード" : "音声の保存") {
            VStack(alignment: .leading, spacing: 10) {
                if !showMeeting {
                    Toggle("認識に使った音声を保存", isOn: Binding(
                        get: { controller.retainAudioEnabled },
                        set: { enabled in
                            if enabled { controller.retainAudioEnabled = true }
                            else { turningOff = true; confirmClear = true }
                        })).settingsControlFocus("retention")
                    Text("通常の音声入力で認識へ渡した16 kHz・モノラルPCM16をWAVで保存します。7日間・合計250 MBで自動削除。14 MBを超える録音と会議の音声は保存しません。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(controller.retentionStatus).font(.caption).textSelection(.enabled)
                    Button("保存音声をすべて削除", role: .destructive) { turningOff = false; confirmClear = true }
                } else {
                    Toggle("会議モードを有効にする", isOn: $controller.meetingModeEnabled).settingsControlFocus("meeting")
                    HStack {
                        Text("画面収録：\(guide.screenRecordingGranted ? "許可済み" : "未許可")")
                        Button("許可を求める／設定を開く") {
                            guide.requestScreenRecording(enabled: controller.meetingModeEnabled)
                        }.disabled(!controller.meetingModeEnabled)
                        Button("状態を再確認") { guide.refreshFromSettings() }
                    }.font(.caption)
                    Text("会議はマイク／システム音声の区別のみで、人物別の識別ではありません。相手には複数人やメディア音声が含まれます。ヘッドホンを推奨します。文字起こしは履歴へ保存します。Geminiでは2つのLive接続を使い、両方の音声がGoogleへ送られ、使用量も2系統分になります。AppleはこのMac内で認識します。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Appleは50秒、Geminiは480秒ごとに順番に区切ります。区切りは文の途中になる場合があり、確定・再準備中は録音に隙間が生じます。参加者への録音の説明・同意を確認してください。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !guide.message.isEmpty { Text(guide.message).font(.caption) }
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert(turningOff ? "音声保存をオフにして保存音声をすべて削除しますか？" : "保存音声をすべて削除しますか？", isPresented: $confirmClear) {
            Button("削除", role: .destructive) {
                if turningOff { controller.retainAudioEnabled = false } else { controller.clearRetainedAudio() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("保存したWAVファイルを削除し、履歴の音声参照を解除して削除理由を記録します。履歴の文章は残ります。削除は取り消せません。")
        }
        .onAppear { if showMeeting { guide.refresh() } }
    }
}
#endif
