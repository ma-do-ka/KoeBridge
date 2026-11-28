#if os(macOS)
import AppKit
import SwiftUI
import KoeBridgeCore

struct SettingsPrivacyPage: View {
    @ObservedObject var controller: VoiceController
    let historyCount: Int
    @Binding var diagnosticsEnabled: Bool
    @Binding var localDiagnosticsEnabled: Bool
    let logNotice: String
    let counterNotice: String
    let focusRequest: SettingsFocusRequest?
    let showHistory: () -> Void
    let requestLogDeletion: () -> Void
    let requestCounterDeletion: () -> Void

    var body: some View {
        SettingsPageScrollView(section: .history, focusRequest: focusRequest) {
            VStack(alignment: .leading, spacing: 18) {
                MeetingAndRetentionSettings(showMeeting: false).settingsTarget("retention")
                UsageMonitorView(controller: controller, focusRequest: focusRequest)
                ProtectedAppsSettings(controller: controller)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsRow("保存件数：\(historyCount) / \(RecentTranscriptArchive.maximumRecords)件",
                                    description: "直近\(RecentTranscriptArchive.maximumRecords)件の文字起こし結果をMacに保存します。音声は保存設定を有効にした場合のみ別ファイルに保存します。APIキーは履歴に保存しません。") {
                            SettingsRowActionButton("文章を見る") { showHistory() }.settingsControlFocus("history")
                        }
                        .settingsTarget("history")
                        Text("保存先：~/Library/Application Support/KoeBridge/recent-transcripts.json")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                } label: {
                    Label("文字起こし履歴", systemImage: "clock.arrow.circlepath")
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        SettingsRow("問題調査用の記録を残す",
                                    description: "入力できなかった段階、入力先アプリの識別子、確認結果や処理時間をこのMacに保存します。通常はオフで問題ありません。認識した文章・入力欄の本文・音声・APIキー・ウィンドウ名・URLは記録しません。", icon: "stethoscope") {
                            Toggle("問題調査用の記録を残す", isOn: Binding(
                                get: { diagnosticsEnabled },
                                set: { enabled in
                                    diagnosticsEnabled = enabled
                                    // Consent changes synchronously with the
                                    // control, even if SwiftUI coalesces redraws.
                                    DiagnosticLog.preferenceDidChange(enabled)
                                }
                            ))
                                .settingsControlFocus("logging").settingsTarget("logging")
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .onChange(of: diagnosticsEnabled) { _, enabled in
                                    if enabled {
                                        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                                        DiagnosticLog.record("diagnostics enabled; version=\(version)")
                                    }
                                }
                        }
                        Divider()
                        SettingsRow("動作記録を削除",
                                    description: "保存済みの動作記録だけを削除します。文字起こし履歴や設定は変更されません。", icon: "trash") {
                            SettingsRowActionButton("削除", role: .destructive) { requestLogDeletion() }
                        }
                        Text("保存先：~/Library/Logs/\(DiagnosticLog.fileURL.lastPathComponent)、\(DiagnosticLog.microphoneFileURL.lastPathComponent)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(DiagnosticLogPolicy.retentionDescription + "記録をオフにしても以前のログは残ります。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !logNotice.isEmpty {
                            Text(logNotice).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("動作記録", systemImage: "stethoscope")
                }
                LocalDiagnosticsSettings(localDiagnosticsEnabled: $localDiagnosticsEnabled,
                                         counterNotice: counterNotice,
                                         requestCounterDeletion: requestCounterDeletion)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Phase 0 minimal telemetry surface (GD-737): on-device aggregation only.
/// The disclosure, viewing, off-switch and wipe controls share one card.
private struct LocalDiagnosticsSettings: View {
    @Binding var localDiagnosticsEnabled: Bool
    let counterNotice: String
    let requestCounterDeletion: () -> Void
    @State private var openNotice = ""

    private func openAggregateFile() {
        LocalDiagnostics.counter.flushBlocking()
        let url = LocalDiagnostics.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            _ = NSWorkspace.shared.open(url)
            openNotice = ""
        } else {
            openNotice = "まだ集計ファイルがありません。"
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                SettingsRow("処理回数をこのMacに集計する",
                            description: "入力欄の読み取り時間（区間別）・失敗分類コード・マイク復旧・ガード発動の回数だけを、日ごとの集計としてこのMac上の1つのJSONファイルに保存します。音声・認識した文章・入力欄の本文・入力先アプリ名・個人や端末を特定する情報は一切記録せず、外部への送信もありません。オフにすると保存済みの集計も削除します。", icon: "chart.bar") {
                    Toggle("処理回数をこのMacに集計する", isOn: Binding(
                        get: { localDiagnosticsEnabled },
                        set: { enabled in
                            localDiagnosticsEnabled = enabled
                            // Consent changes synchronously with the
                            // control; OFF also wipes stored aggregates.
                            LocalDiagnostics.preferenceDidChange(enabled)
                        }
                    ))
                        .settingsControlFocus("local-diagnostics").settingsTarget("local-diagnostics")
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                Divider()
                SettingsRow("集計ファイルを見る",
                            description: "保存済みの集計をそのまま開き、記録されている内容を確認できます。", icon: "doc.text.magnifyingglass") {
                    SettingsRowActionButton("開く") { openAggregateFile() }
                }
                SettingsRow("集計データを削除",
                            description: "保存済みの集計だけを削除します。文字起こし履歴や設定は変更されません。", icon: "trash") {
                    SettingsRowActionButton("削除", role: .destructive) { requestCounterDeletion() }
                }
                Text("保存先：~/Library/Application Support/KoeBridge/local-diagnostics.json")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("30日より古い日付の集計は自動で削除されます。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !openNotice.isEmpty {
                    Text(openNotice).font(.caption).foregroundStyle(.secondary)
                }
                if !counterNotice.isEmpty {
                    Text(counterNotice).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } label: {
            Label("ローカル診断カウンタ（送信なし）", systemImage: "chart.bar")
        }
    }
}

private struct ProtectedAppsSettings: View {
    @ObservedObject var controller: VoiceController
    @State private var selectedBundle = ""
    @State private var manualBundle = ""
    @State private var runningApps: [RunningApp] = []

    private struct RunningApp: Identifiable {
        let id: String
        let name: String
    }

    private func refreshApps() {
        var seen = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  seen.insert(id).inserted else { return nil }
            return RunningApp(id: id, name: app.localizedName ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var bundleToAdd: String {
        let manual = manualBundle.trimmingCharacters(in: .whitespacesAndNewlines)
        return manual.isEmpty ? selectedBundle : manual
    }

    private var validationHint: String? {
        guard !bundleToAdd.isEmpty else { return nil }
        return ProtectedAppPolicy.validationHint(for: bundleToAdd)
    }

    private func addProtectedApp() {
        let bundle = ProtectedAppPolicy.normalizedBundleIdentifier(bundleToAdd)
        guard validationHint == nil else { return }
        let displayName = runningApps.first(where: { ProtectedAppPolicy.isSameBundle($0.id, bundle) })?.name ?? bundle
        controller.protectedApps = ProtectedAppPolicy.saving(
            ProtectedApp(bundleIdentifier: bundle, displayName: displayName),
            in: controller.protectedApps
        )
        selectedBundle = ""
        manualBundle = ""
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("起動中のアプリ", selection: $selectedBundle) {
                    Text("アプリを選択").tag("")
                    ForEach(runningApps) { app in Text(app.name).tag(app.id) }
                }
                .pickerStyle(.menu)
                .settingsControlFocus("protected-apps")
                .accessibilityLabel("証拠を最小化するアプリを起動中のアプリから選択")

                if controller.protectedAppsStore.state == .corrupt {
                    CorruptSettingsNotice(reset: controller.resetProtectedApps)
                } else if controller.protectedApps.isEmpty {
                    Text("まだ登録がありません。入力内容を証拠に残したくないアプリを追加できます。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.protectedApps) { app in
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "lock.shield")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 24)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.displayName)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(app.bundleIdentifier)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button(role: .destructive) {
                                    controller.protectedApps.removeAll { $0.id == app.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .help("このアプリを一覧から削除")
                                .accessibilityLabel("「\(app.displayName)」を証拠最小化の一覧から削除")
                            }
                            .padding(.vertical, 7)
                            if app.id != controller.protectedApps.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("またはバンドルIDを入力（例：com.apple.TextEdit）", text: $manualBundle)
                        .textFieldStyle(.roundedBorder)
                    Button("一覧を更新") { refreshApps() }
                }
                if let validationHint {
                    Text(validationHint)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    addProtectedApp()
                } label: {
                    Label("アプリを追加", systemImage: "plus")
                }
                .disabled(bundleToAdd.isEmpty || validationHint != nil || controller.protectedAppsStore.state == .corrupt)

                Text("登録したアプリでは、入力確認の証拠に本文を残しません（文字数とハッシュのみ）。そのため、後からの修正や位置合わせの精度は制限されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("入力証拠を最小化するアプリ", systemImage: "lock.shield")
        }
        .settingsTarget("protected-apps")
        .onAppear { refreshApps() }
    }
}

#endif
