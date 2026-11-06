#if os(macOS)
import AppKit
import AVFoundation
import Speech
import SwiftUI
import KoeBridgeCore

/// The overview edits the same persisted preferences as the detailed pages.
struct SettingsGeneralPage: View {
    @ObservedObject var controller: VoiceController
    @ObservedObject var guide: PermissionGuide
    @ObservedObject var loginItem: LoginItemManager
    @ObservedObject var updater: KoeBridgeUpdateManager
    @Binding var generalPermissionCheckedAt: Date?
    let focusRequest: SettingsFocusRequest?
    let navigate: (SettingsSection) -> Void

    var body: some View {
        SettingsPageScrollView(section: .general, focusRequest: focusRequest) {
            VStack(alignment: .leading, spacing: 18) {
                generalControlsCard
                    .id("general")
                generalReadinessCard
                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        SettingsRow("ログイン時に自動起動",
                                    description: "ONでKoeBridgeをmacOSのログイン項目に登録します。OS側の承認が必要な場合は、システム設定でユーザーが許可してください。",
                                    icon: "power") {
                            Toggle("ログイン時に自動起動",
                                   isOn: Binding(
                                    get: { loginItem.isRequested },
                                    set: { loginItem.setRequested($0) }
                                   ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!loginItem.canChange)
                        }
                        .id("launchAtLogin")
                        Divider()
                        HStack(spacing: 10) {
                            Label("ログイン項目：\(loginItem.statusLabel)",
                                  systemImage: loginItem.isActive ? "checkmark.circle.fill" : "info.circle")
                                .font(.caption)
                                .foregroundStyle(loginItem.isActive ? Color.green : Color.secondary)
                            Spacer()
                            Button("状態を再確認") { loginItem.refresh() }
                                .controlSize(.small)
                            if loginItem.needsSystemSettings {
                                Button("ログイン項目を開く") { loginItem.openSystemSettings() }
                                    .controlSize(.small)
                            }
                        }
                        if loginItem.shouldShowManualAddHelp {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("macOSがKoeBridgeを自動登録できなかったため、手動での追加が必要です。")
                                Text("「ログイン項目を開く」でmacOSの設定を表示し、KoeBridge.appを追加・許可してください。")
                                Button("KoeBridge.appをFinderで表示") {
                                    loginItem.revealAppInFinder()
                                }
                                .controlSize(.small)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !loginItem.message.isEmpty {
                            Text(loginItem.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("起動と常駐", systemImage: "power")
                }
                generalUpdatesCard
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("録音キーを押してからマイクが使えるまでと、録音停止から入力処理が終わるまでの実測時間を表示します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .center) {
                            Label("録音開始まで", systemImage: "mic")
                            Spacer()
                            Text(controller.lastStartupSeconds.map { String(format: "%.2f秒", $0) } ?? "未計測")
                                .monospacedDigit()
                        }
                        .frame(minHeight: 34)
                        Divider()
                        HStack(alignment: .center) {
                            Label("録音停止から入力処理完了まで", systemImage: "arrow.up.circle")
                            Spacer()
                            Text(controller.lastStopToInputSeconds.map { String(format: "%.2f秒", $0) } ?? "未計測")
                                .monospacedDigit()
                        }
                        .frame(minHeight: 34)
                        Text("端末や接続環境により変動します。入力イベント送信後の確認待ち時間を含みます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } label: {
                    Label("直近の処理時間", systemImage: "speedometer")
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("1. 入力したい欄をクリック", systemImage: "cursorarrow.click.2")
                        Label("2. \(controller.shortcutChoice.label) で録音開始", systemImage: "mic")
                        Label("3. 同じキーでもう一度押して確定", systemImage: "checkmark.circle")
                        HStack(spacing: 12) {
                            Button("使い方を確認") { navigate(.help) }
                            Button("保存した文章を見る") { controller.onShowHistory?() }
                        }
                        Text("入力できなかった文章は「認識履歴（直近10件）」で確認できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } label: {
                    Label("はじめに", systemImage: "book")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            loginItem.refresh()
            guide.refresh()
            updater.checkIfDue()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
            guide.refresh()
        }
    }

    /// Primary controls are editable here. The Voice/Gemini pages remain
    /// available for detailed descriptions, rather than being the only route.
    private var generalControlsCard: some View {
        GroupBox {
            VStack(spacing: 0) {
                SettingsRow("文字起こしの方法",
                            description: "Gemini API またはMac内でのApple認識を選択します。",
                            icon: "waveform") {
                    SettingsRecognitionPicker("認識方法", selection: $controller.requestedMode)
                    .frame(width: 168)
                }
                Divider()
                SettingsRow("録音の開始・終了キー",
                            description: "今の設定：\(controller.shortcutChoice.label)。もう一度押すと確定します。",
                            icon: "keyboard") {
                    SettingsShortcutPicker("録音キー", selection: Binding(
                        get: { controller.shortcutChoice },
                        set: { controller.selectShortcut($0) }
                    ))
                    .frame(width: 198)
                }
                if !controller.shortcutProblem.isEmpty {
                    HStack {
                        Text(controller.shortcutProblem)
                            .font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button("再登録") { controller.retryShortcutRegistration() }
                    }
                }
                Divider()
                SettingsRow("認識した文章を自動入力",
                            description: "OFFの場合、結果は履歴に保存して後からコピーできます。",
                            icon: "text.cursor") {
                    Toggle("自動入力", isOn: $controller.automaticPaste)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if controller.requestedMode == .gemini {
                    Divider()
                    SettingsRow("文字起こしスタイル",
                                description: controller.transcriptionStyle.explanation,
                                icon: "text.alignleft") {
                        SettingsTranscriptionStylePicker("スタイル", selection: $controller.transcriptionStyle)
                        .frame(width: 192)
                    }
                }
            }
            .padding(8)
        } label: {
            Label("音声入力をすぐ使う", systemImage: "mic.fill")
        }
    }

    private var generalReadinessCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if guide.microphoneStatus != .authorized {
                    Label("マイクの許可が必要です", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                } else if controller.requestedMode == .gemini && !controller.hasKey {
                    Label("Gemini APIキーが未登録です。Apple認識への切替が必要な場合があります。",
                          systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                } else if controller.requestedMode == .local &&
                            SFSpeechRecognizer.authorizationStatus() != .authorized {
                    Label("Appleの音声認識への許可を確認してください。マイク許可とは別に管理されます。",
                          systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                } else if controller.automaticPaste &&
                            (!guide.accessibilityGranted || !guide.postEventGranted) {
                    Label("自動入力に必要なmacOSの許可を確認してください。",
                          systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                } else if !controller.automaticPaste {
                    Label("文字起こしの準備を確認しました（自動入力はOFF・履歴保存）",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("音声入力に必要な基本設定を確認できました",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                HStack(spacing: 12) {
                    Label(guide.microphoneStatus == .authorized ? "マイク許可済み" : "マイク要確認",
                          systemImage: "mic")
                    Label(!controller.automaticPaste ? "自動入力OFF"
                          : (guide.accessibilityGranted && guide.postEventGranted
                             ? "入力操作許可済み" : "入力操作要確認"),
                          systemImage: "keyboard")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if controller.requestedMode == .gemini {
                        Label(controller.hasKey ? "Geminiキー登録済み" : "Geminiキー未登録",
                              systemImage: "key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("APIキー設定") { navigate(.gemini) }
                    }
                    Spacer()
                    Button("許可を再確認") {
                        guide.refreshFromSettings()
                        generalPermissionCheckedAt = Date()
                    }
                    Button("対処方法") { navigate(.permissions) }
                }
                .controlSize(.small)
                if let checked = generalPermissionCheckedAt {
                    Text("許可状態を確認しました：\(checked.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("許可状態はmacOSが管理します。KoeBridgeから強制的にONにはできません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            Label("準備状況と困ったとき", systemImage: "checkmark.shield")
        }
    }

    private var generalUpdatesCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("現在：v\(updater.installedLabel)（Stable）")
                        .font(.system(size: 14, weight: .semibold))
                    Text(updater.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("更新を確認") {
                    updater.requestUpdatePage()
                    Task { await updater.checkNow() }
                }
                .disabled(updater.state == .checking)
            }
            .padding(8)
        } label: {
            Label("アップデート", systemImage: "arrow.triangle.2.circlepath")
        }
    }
}
#endif
