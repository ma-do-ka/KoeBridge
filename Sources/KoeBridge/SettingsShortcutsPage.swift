#if os(macOS)
import SwiftUI
import KoeBridgeCore
struct SettingsShortcutsPage: View {
    @ObservedObject var controller: VoiceController
    let focusRequest: SettingsFocusRequest?
    var body: some View {
        SettingsPageScrollView(section: .shortcuts, focusRequest: focusRequest) {
            GroupBox("ショートカットと録音操作") {
                VStack(alignment: .leading, spacing: 12) {
                        SettingsRow("録音の開始・終了キー",
                                    description: "選んだキーと下の動作設定で録音を操作します。ほかのアプリのキー操作と競合する場合があります。") {
                            SettingsShortcutPicker("録音の開始・終了キー", selection: Binding(
                                get: { controller.shortcutChoice },
                                set: { controller.selectShortcut($0) }
                            ))
                            .settingsControlFocus("shortcut").frame(width: 250)
                        }
                        .settingsTarget("shortcut")
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
                }.padding(8)
            }.padding(18)
        }
    }
}
#endif
