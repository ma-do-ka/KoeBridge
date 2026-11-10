#if os(macOS)
import SwiftUI

struct MeetingAndRetentionSettings: View {
    @ObservedObject private var controller = VoiceController.shared
    @ObservedObject private var guide = PermissionGuide.shared
    var body: some View {
        GroupBox("会議モードと音声保存（個別に有効化）") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("認識に使った音声を保存", isOn: $controller.retainAudioEnabled)
                Text("通常の音声入力で認識へ渡した16 kHz・モノラルPCM16をWAVで保存します。7日間・合計250 MBで自動削除。14 MBを超える録音と会議の音声は保存しません。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(controller.retentionStatus).font(.caption).textSelection(.enabled)
                Button("保存音声をすべて削除", role: .destructive) { controller.clearRetainedAudio() }
                Divider()
                Toggle("会議モードを有効にする", isOn: $controller.meetingModeEnabled)
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
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { guide.refresh() }
    }
}
#endif
