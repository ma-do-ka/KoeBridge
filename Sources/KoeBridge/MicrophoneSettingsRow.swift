#if os(macOS)
import SwiftUI

struct MicrophoneSettingsRow: View {
    @ObservedObject var controller: VoiceController
    @ObservedObject private var microphones = MicrophoneDeviceStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow("使用するマイク",
                        description: "KoeBridgeで使用するマイクを選びます。『システム設定に従う』では、Macで選択中の入力機器を使用します。", icon: "mic") {
                Picker("使用するマイク", selection: Binding(
                    get: { microphones.selectedUID }, set: { microphones.select($0) }
                )) {
                    Text(microphones.systemLabel).tag("")
                    if !microphones.selectedUID.isEmpty &&
                        !microphones.devices.contains(where: { $0.uid == microphones.selectedUID }) {
                        Text(microphones.selectedUIDCollides ? "選択したIDを複数のマイクが使用しています" : microphones.loaded ? "選択したマイク（未接続）" : "選択したマイク（確認中）")
                            .tag(microphones.selectedUID)
                    }
                    ForEach(microphones.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .settingsControlFocus("microphone-device").labelsHidden()
                .frame(width: 250)
                .disabled(controller.busy || !microphones.loaded)
                .help("Mac全体の入力設定は変更しません。準備中・録音中は変更できません。")
            }
            SettingsRow("Bluetoothマイクの接続を温めておく",
                        description: "Bluetoothヘッドセットの音声経路を開いたままにし、録音開始時の接続待ちをなくします。有効な間はマイク使用中インジケーターが点灯します。また、Bluetoothの仕様によりイヤホン側の再生音質が通話音質になります（本アプリの処理によるものではありません）。待機中の音声は録音・保存・送信されません。", icon: "mic") {
                Toggle("Bluetoothマイクの接続を温めておく", isOn: $controller.bluetoothMicWarmEnabled).settingsControlFocus("bluetooth-warm")
                    .labelsHidden()
            }
            .settingsTarget("bluetooth-warm")
            SettingsRow("録音中の音量ガード",
                        description: "録音中やマイクの接続を温めている間は、再生音量が開始時の音量を超えると、手動で上げた場合もその上限まで下げます。Bluetooth以外のマイクを選ぶと、ヘッドセットが通話用の音声経路に切り替わるのを防げます。", icon: "speaker.wave.2") {
                Toggle("録音中の音量ガード", isOn: $controller.outputVolumeGuardEnabled)
                    .settingsControlFocus("output-volume-guard").labelsHidden()
            }
            .settingsTarget("output-volume-guard")
            if microphones.selectedDeviceMissing {
                Text("選択したマイクが接続されていません。別のマイクには自動で切り替えません。")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsTarget("microphone-device")
        .task {
            while !Task.isCancelled {
                await microphones.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}
#endif
