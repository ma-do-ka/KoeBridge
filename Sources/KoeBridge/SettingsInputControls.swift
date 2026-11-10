#if os(macOS)
import SwiftUI
import KoeBridgeCore

struct SettingsInputControls: View {
    @ObservedObject var controller: VoiceController

    private var caption: String {
        switch controller.shortcutActivationMode {
        case .toggle: return "押すたびに開始・確定を切り替えます"
        case .hold: return "押している間だけ録音し、離すと確定します。準備中に離すと取り消します"
        case .hybrid: return "短く押すと録音を固定し、長く押すと離した時点で確定します"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("録音キーの動作", selection: $controller.shortcutActivationMode) {
                Text("トグル").tag(ShortcutActivationMode.toggle)
                Text("ホールド").tag(ShortcutActivationMode.hold)
                Text("ハイブリッド").tag(ShortcutActivationMode.hybrid)
            }
            .settingsControlFocus("activation").pickerStyle(.segmented).settingsTarget("activation")
            Text(caption).font(.caption).foregroundStyle(.secondary)
            ForEach(ShortcutAction.allCases.filter { $0 == .transformSelection }) { action in
                Picker(action.label, selection: Binding<RecordingShortcut?>(
                    get: { controller.transformShortcut },
                    set: { controller.selectTransformShortcut($0) }
                )) {
                    Text("未割り当て（オフ）").tag(Optional<RecordingShortcut>.none)
                    ForEach(RecordingShortcut.allCases) { choice in
                        Text(choice.label).tag(Optional(choice))
                    }
                }.settingsControlFocus("transform-shortcut")
            }
            .settingsTarget("transform-shortcut")
            Text("割り当てると有効になります。選択テキストと指示は、変換時だけGeminiへ送信されます。音声モードでは録音キーと同じ開始・終了動作、プリセットでは1回押すと実行します。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("選択テキストを翻訳", selection: Binding<RecordingShortcut?>(
                get: { controller.translateShortcut },
                set: { controller.selectTranslateShortcut($0) }
            )) {
                Text("未割り当て（オフ）").tag(Optional<RecordingShortcut>.none)
                ForEach(RecordingShortcut.allCases) { choice in
                    Text(choice.label).tag(Optional(choice))
                }
            }
            .settingsControlFocus("translate-shortcut").settingsTarget("translate-shortcut")
            Picker("直前の入力を修正", selection: Binding<RecordingShortcut?>(
                get: { controller.fixLastShortcut },
                set: { controller.selectFixLastShortcut($0) }
            )) {
                Text("未割り当て（オフ）").tag(Optional<RecordingShortcut>.none)
                ForEach(RecordingShortcut.allCases) { choice in
                    Text(choice.label).tag(Optional(choice))
                }
            }
            .settingsControlFocus("fix-shortcut").settingsTarget("fix-shortcut")
            Text("1回押すと直前の入力への修正指示を録音します。録音キーで確定してください。入力先や文章・カーソルが変わった場合、または10分を過ぎた場合は修正できません。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("マウスボタン", selection: $controller.mouseTriggerButton) {
                Text("なし").tag(MouseTriggerButton.none)
                Text("中央ボタン").tag(MouseTriggerButton.middle)
                Text("サイドボタン（戻る）").tag(MouseTriggerButton.sideBack)
                Text("サイドボタン（進む）").tag(MouseTriggerButton.sideForward)
            }
            .settingsControlFocus("mouse").settingsTarget("mouse")
            Text("マウスボタンでも録音を開始・確定できます。ボタンは通常のクリックとしてもそのまま動作します（入力監視の許可が必要です）")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 10)
    }
}
#endif
