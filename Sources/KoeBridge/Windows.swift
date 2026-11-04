#if os(macOS)
import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI
import KoeBridgeCore

/// Settings and history use ordinary windows; dictation uses a non-activating
/// panel on the macOS primary display, not NSScreen.main (focused window).
@MainActor final class AppWindows {
    private var settingsWindow: NSWindow?
    private var previewPanel: NSPanel?
    private var historyWindow: NSWindow?
    private var permissionWindow: NSWindow?
    private var displayObserver: NSObjectProtocol?

    init() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.movePreviewToPrimaryDisplay() }
        }
    }

    func manages(_ candidate: NSWindow?) -> Bool {
        guard let candidate else { return false }
        return candidate === settingsWindow || candidate === historyWindow || candidate === permissionWindow
    }

    func showPermissions() {
        PermissionGuide.shared.refresh()
        let window: NSWindow
        if let permissionWindow { window = permissionWindow }
        else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 510, height: 440),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "KoeBridge 初期設定・権限"
            window.center()
            window.contentView = NSHostingView(rootView: PermissionSetupView(guide: .shared))
            window.isReleasedWhenClosed = false
            permissionWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        let window: NSWindow
        if let settingsWindow { window = settingsWindow }
        else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 710, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "KoeBridge 設定"
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(controller: .shared, guide: .shared))
            window.minSize = NSSize(width: 690, height: 520)
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showPreview() {
        let panel: NSPanel
        if let previewPanel { panel = previewPanel }
        else {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 104),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false // SwiftUI material capsule draws its own subtle shadow
            panel.ignoresMouseEvents = true // no focus changes, no accidental clicks
            panel.isFloatingPanel = true
            panel.isMovable = false
            panel.level = .floating
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: PreviewView(controller: .shared))
            panel.isReleasedWhenClosed = false
            previewPanel = panel
        }
        movePreviewToPrimaryDisplay()
        panel.orderFrontRegardless() // does not activate the application or steal text focus
    }

    private func movePreviewToPrimaryDisplay() {
        guard let panel = previewPanel, let primary = NSScreen.screens.first else { return }
        let area = primary.visibleFrame
        let width = min(520.0, max(260.0, area.width - 24.0))
        let height = min(104.0, max(76.0, area.height - 20.0))
        let frame = NSRect(x: area.midX - width / 2.0,
                           y: area.minY + 12.0, width: width, height: height)
        panel.setFrame(frame, display: true)
    }

    /// Called on second shortcut press, before ASR finalization or paste.
    /// No fade, delay, or success-only condition; the overlay must disappear
    /// even if network recognition or focus-safe insertion later fails.
    func hidePreview() {
        previewPanel?.orderOut(nil)
    }

    func showHistory() {
        let window: NSWindow
        if let historyWindow { window = historyWindow }
        else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 790, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "KoeBridge 認識履歴（直近10件）"
            window.center()
            window.contentView = NSHostingView(rootView: HistoryView(controller: .shared))
            window.isReleasedWhenClosed = false
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// A minimal non-interactive floating transcription capsule.
/// Status, commands, diagnostics and history are intentionally available only
/// from the menu bar / Settings, never on the dictation overlay itself.
struct PreviewView: View {
    @ObservedObject var controller: VoiceController

    private var visibleTranscript: String {
        let full = controller.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else {
            return controller.phase == .preparing ? "マイクを準備しています…" : "話してください…"
        }
        return full.count > 180 ? "…" + String(full.suffix(180)) : full
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(controller.isRecording ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: controller.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(controller.isRecording ? Color.red : Color.secondary)
                    .accessibilityLabel(controller.isRecording ? "マイク録音中" : "マイク準備中")
            }
            Text(visibleTranscript)
                .font(.system(size: 14, weight: .medium, design: .default))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(visibleTranscript)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.17), radius: 13, x: 0, y: 5)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

struct HistoryView: View {
    @ObservedObject var controller: VoiceController
    @State private var selectedID: UUID?
    @State private var confirmDeleteAll = false

    private var selected: TranscriptRecord? {
        controller.history.first(where: { $0.id == selectedID }) ?? controller.history.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("直近の文字起こし：\(controller.history.count) / 10件")
                    .font(.headline)
                Spacer()
                Text("音声データ・APIキーは保存しません")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !controller.historyProblem.isEmpty {
                Text(controller.historyProblem)
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if controller.history.isEmpty {
                Spacer()
                Text("保存された文字起こしはありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(controller.history) { record in
                                Button {
                                    selectedID = record.id
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2).foregroundStyle(.secondary)
                                        Text(record.text.replacingOccurrences(of: "\n", with: " "))
                                            .lineLimit(2).font(.body)
                                        Text(record.delivery.label)
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(selected?.id == record.id
                                                ? Color.accentColor.opacity(0.14)
                                                : Color.secondary.opacity(0.07))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }.frame(width: 255)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        if let selected {
                            Text("\(selected.engine) / \(selected.isPartial ? "認識途中" : "確定結果")")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(selected.delivery.label)
                                .font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                Text(selected.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            HStack {
                                Spacer()
                                Button("この文章をコピー") { controller.copyRecord(selected) }
                                Button("この履歴を削除", role: .destructive) {
                                    let removing = selected.id
                                    controller.deleteRecord(removing)
                                    selectedID = controller.history.first?.id
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            HStack {
                Text("自動入力の受理確認はできません。失敗時はここからコピーしてください。")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("すべて削除", role: .destructive) { confirmDeleteAll = true }
                    .disabled(controller.history.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 650, minHeight: 390)
        .alert("保存した10件の履歴をすべて削除しますか？", isPresented: $confirmDeleteAll) {
            Button("削除", role: .destructive) { controller.clearHistory(); selectedID = nil }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("削除した文字起こしはKoeBridgeから復元できません。")
        }
    }
}

/// Four focused settings pages replace the old tall Form, which clipped its
/// labels in a fixed-size 540x665 window. All existing preferences are reused.
struct SettingsView: View {
    @ObservedObject var controller: VoiceController
    @ObservedObject var guide: PermissionGuide
    @AppStorage("diagnosticsEnabled") private var diagnosticsEnabled = false
    @State private var apiKeyDraft = ""
    @State private var apiKeyNotice = ""
    @State private var logNotice = ""
    @State private var confirmDeleteLog = false
    @State private var confirmDeleteKey = false
    @State private var tab: SettingsPage = .voice

    private enum SettingsPage: Hashable {
        case voice, gemini, privacy, permissions
    }

    var body: some View {
        TabView(selection: $tab) {
            voicePage
                .tabItem { Label("音声入力", systemImage: "mic.fill") }
                .tag(SettingsPage.voice)
            geminiPage
                .tabItem { Label("Gemini", systemImage: "sparkles") }
                .tag(SettingsPage.gemini)
            privacyPage
                .tabItem { Label("履歴・診断", systemImage: "lock.shield") }
                .tag(SettingsPage.privacy)
            permissionsPage
                .tabItem { Label("権限", systemImage: "checkmark.shield") }
                .tag(SettingsPage.permissions)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(minWidth: 675, minHeight: 475)
        .alert("診断ログを削除しますか？", isPresented: $confirmDeleteLog) {
            Button("削除", role: .destructive) {
                do {
                    try DiagnosticLog.deleteExistingFiles()
                    logNotice = "診断ログを削除しました"
                } catch {
                    logNotice = "ログを削除できません：\(error.localizedDescription)"
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("KoeBridge.log と古いログ1件を削除します。認識履歴や設定は削除されません。")
        }
        .alert("Gemini APIキーを削除しますか？", isPresented: $confirmDeleteKey) {
            Button("削除", role: .destructive) {
                controller.deleteKey()
                apiKeyDraft = ""
                apiKeyNotice = "APIキーを削除しました"
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("macOSキーチェーン内のKoeBridge用APIキーを削除します。")
        }
    }

    private func headline(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var voicePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headline("音声入力", detail: "録音方法と文字入力の動作を設定します。")
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Text("認識エンジン")
                                .frame(width: 112, alignment: .leading)
                            Picker("認識エンジン", selection: $controller.requestedMode) {
                                ForEach(RecognitionMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                        HStack(spacing: 12) {
                            Text("録音・確定キー")
                                .frame(width: 112, alignment: .leading)
                            Picker("録音・確定キー", selection: Binding(
                                get: { controller.shortcutChoice },
                                set: { controller.selectShortcut($0) }
                            )) {
                                ForEach(RecordingShortcut.allCases) { choice in
                                    Text(choice.label).tag(choice)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                        if !controller.shortcutProblem.isEmpty {
                            Text(controller.shortcutProblem)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("録音キーの登録を再試行") { controller.retryShortcutRegistration() }
                        }
                        Divider()
                        Toggle("録音停止後に元の入力先へ自動入力", isOn: $controller.automaticPaste)
                            .toggleStyle(.checkbox)
                        Text("録音キーを押して開始、もう一度押して確定します。録音パネルは停止と同時に閉じます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                } label: {
                    Label("基本設定", systemImage: "slider.horizontal.3")
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("自動入力にはクリップボードを使用せず、Unicodeキーイベントを送信します。")
                        Text("入力先の変更や権限不足を検出した場合は入力しません。文字起こしは直近10件の履歴からコピーできます。")
                        Text("右Command等の単独キーには入力監視の許可が必要な場合があります。FnキーはmacOSの割当と競合する場合があります。")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } label: {
                    Label("入力の安全性", systemImage: "keyboard")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var geminiPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headline("Gemini API", detail: "Geminiを選んだ場合に使用するキーと認識オプションです。")
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        SecureField("Gemini APIキー（保存済みの値は表示しません）", text: $apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Label(controller.hasKey ? "キーチェーンに登録済み" : "APIキー未登録",
                                  systemImage: controller.hasKey ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("登録・更新") {
                                do {
                                    try controller.saveKey(apiKeyDraft)
                                    apiKeyDraft = ""
                                    apiKeyNotice = "APIキーを保存しました"
                                } catch {
                                    apiKeyNotice = "保存に失敗しました：\(error.localizedDescription)"
                                }
                            }
                            .disabled(apiKeyDraft.isEmpty)
                            Button("削除", role: .destructive) { confirmDeleteKey = true }
                                .disabled(!controller.hasKey)
                        }
                        if !apiKeyNotice.isEmpty {
                            Text(apiKeyNotice).font(.caption).textSelection(.enabled)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("APIキー", systemImage: "key.horizontal")
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("日本語ヒント（ja-JP）", isOn: $controller.japaneseHint)
                            .toggleStyle(.checkbox)
                        Toggle("SMART整形（逐語ではなくなる）", isOn: $controller.smartFormatting)
                            .toggleStyle(.checkbox)
                        Text("専門用語辞書（1行に1語・最初の100語を送信）")
                            .font(.callout).fontWeight(.medium)
                        TextEditor(text: $controller.vocabulary)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 125)
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(Color.secondary.opacity(0.25))
                            }
                    }
                    .padding(8)
                } label: {
                    Label("認識精度", systemImage: "text.badge.checkmark")
                }
                Text("キーはmacOSキーチェーンに保存します。Gemini利用時の音声はGoogleのAPIへ送信され、利用枠・料金はGoogle側の条件に従います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var privacyPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headline("履歴・診断", detail: "文字起こし履歴と、問題調査用ログを管理します。")
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("認識履歴：\(controller.history.count) / 10件")
                                    .fontWeight(.medium)
                                Text("認識テキストのみをMac内に保存します。音声やAPIキーは保存しません。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("履歴を表示") { controller.onShowHistory?() }
                        }
                        Text("~/Library/Application Support/KoeBridge/recent-transcripts.json")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } label: {
                    Label("認識履歴", systemImage: "clock.arrow.circlepath")
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $diagnosticsEnabled) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("診断ログを保存する")
                                    .fontWeight(.medium)
                                Text("開発・問題調査時のみONにしてください。通常はOFFで、ログは追加されません。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .onChange(of: diagnosticsEnabled) { _, enabled in
                            if enabled {
                                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                                DiagnosticLog.record("diagnostics enabled; version=\(version)")
                            }
                        }
                        Divider()
                        Text("記録先：~/Library/Logs/KoeBridge.log")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("1ファイル192KB、世代1件を含め最大約384KB。認識本文・音声・APIキーは記録しません。OFFにしても既存ログは保持されます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("既存ログを削除", role: .destructive) { confirmDeleteLog = true }
                            Spacer()
                            if !logNotice.isEmpty {
                                Text(logNotice).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } label: {
                    Label("診断ログ", systemImage: "stethoscope")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissionsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headline("macOSの利用許可", detail: "許可状態はmacOSが管理します。未許可の場合のみ、ここから要求できます。")
                GroupBox {
                    VStack(spacing: 0) {
                        permissionRow("入力先の制御", icon: "hand.raised.fill",
                                      isGranted: guide.accessibilityGranted,
                                      canRequest: !guide.accessibilityGranted) {
                            guide.requestAccessibility()
                        }
                        Divider().padding(.vertical, 7)
                        permissionRow("入力イベントの送信", icon: "keyboard.fill",
                                      isGranted: guide.postEventGranted,
                                      canRequest: !guide.postEventGranted && guide.accessibilityGranted) {
                            guide.requestPostEvent()
                        }
                        Divider().padding(.vertical, 7)
                        permissionRow("マイク入力", icon: "mic.fill",
                                      isGranted: guide.microphoneStatus == .authorized,
                                      canRequest: guide.microphoneStatus != .authorized && !guide.microphoneRequestInProgress) {
                            guide.requestMicrophone()
                        }
                    }
                    .padding(8)
                } label: {
                    Label("現在の状態", systemImage: "checkmark.shield")
                }
                if !guide.message.isEmpty {
                    Text(guide.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("状態を更新") { guide.refresh() }
                    Button("初期設定・権限画面を開く") { controller.onShowPermissions?() }
                    Spacer()
                }
                Text("macOSで拒否済みの場合、再要求してもダイアログが出ないことがあります。システム設定の「プライバシーとセキュリティ」でKoeBridgeの許可を確認してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { guide.refresh() }
    }

    private func permissionRow(_ title: String, icon: String,
                               isGranted: Bool, canRequest: Bool,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 25)
                .foregroundStyle(.secondary)
            Text(title)
            Spacer()
            Label(isGranted ? "許可済み" : "未許可",
                  systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(isGranted ? Color.green : Color.orange)
                .font(.callout)
            Button("許可を要求", action: action)
                .disabled(!canRequest)
        }
    }
}

/// The OS owns both security decisions. This view requests prompts and
/// reflects actual process permissions; it never claims to enable them.
@MainActor final class PermissionGuide: ObservableObject {
    static let shared = PermissionGuide()
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var postEventGranted = false
    @Published private(set) var microphoneStatus: AVAuthorizationStatus = .notDetermined
    @Published private(set) var microphoneRequestInProgress = false
    @Published private(set) var message = ""

    private init() { refresh() }
    var needsAttention: Bool {
        PermissionSetupPolicy.shouldShowSetup(accessibilityGranted: accessibilityGranted,
                                               postEventGranted: postEventGranted,
                                               microphoneGranted: microphoneStatus == .authorized)
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        postEventGranted = CGPreflightPostEventAccess()
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestAccessibility() {
        _ = TextInsertion.requestAccessibility()
        refresh()
        message = accessibilityGranted
            ? "アクセシビリティは許可されています。"
            : "macOSの許可画面でKoeBridgeをONにしてください。必要ならアプリを終了して再起動します。"
    }

    func requestPostEvent() {
        refresh()
        guard accessibilityGranted else {
            message = "まず『入力先の制御』への許可が必要です。"
            return
        }
        _ = TextInsertion.requestPostEventAccess()
        refresh()
        message = postEventGranted
            ? "入力イベントの送信が許可されました。"
            : "入力イベント送信は未許可です。macOSが再度ダイアログを出さない場合、プライバシー設定でKoeBridgeを確認してください。"
    }

    func requestMicrophone() {
        refresh()
        guard microphoneStatus == .notDetermined, !microphoneRequestInProgress else {
            message = microphoneStatus == .authorized
                ? "マイクは許可されています。"
                : "マイクの利用を拒否済みの場合はmacOSのプライバシー設定から変更してください。"
            return
        }
        microphoneRequestInProgress = true
        Task { [weak self] in
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self else { return }
            self.microphoneRequestInProgress = false
            self.refresh()
        }
    }

    /// Only on the first app launch. Show the native microphone dialog and
    /// the native accessibility guidance, one after the other.
    func promptOnFirstLaunch() {
        let key = "permissionsIntroRequestedV044"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task { [weak self] in
            guard let self else { return }
            self.refresh()
            if self.microphoneStatus == .notDetermined {
                self.microphoneRequestInProgress = true
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                self.microphoneRequestInProgress = false
                self.refresh()
            }
            if !self.accessibilityGranted { self.requestAccessibility() }
            // One consent request on first launch after this feature is added.
            // If macOS has already denied it, subsequent requests may show no
            // prompt. The separate button and Settings guidance remain available.
            self.refresh()
            if self.accessibilityGranted && !self.postEventGranted {
                self.requestPostEvent()
            }
        }
    }
}

struct PermissionSetupView: View {
    @ObservedObject var guide: PermissionGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("音声入力の利用許可")
                .font(.title2).fontWeight(.semibold)
            Text("録音はマイク、文字入力はアクセシビリティと入力イベント送信の許可が必要です。いずれもmacOSが管理します。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Image(systemName: "hand.raised.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text("入力先の制御（アクセシビリティ）")
                    Text(guide.accessibilityGranted ? "許可済み" : "未許可")
                        .foregroundStyle(guide.accessibilityGranted ? Color.green : Color.orange)
                }
                Spacer()
                Button("許可を要求") { guide.requestAccessibility() }
                    .disabled(guide.accessibilityGranted)
            }
            Divider()
            HStack {
                Image(systemName: "keyboard.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text("入力イベントの送信（PostEvent）")
                    Text(guide.postEventGranted ? "許可済み" : "未許可")
                        .foregroundStyle(guide.postEventGranted ? Color.green : Color.orange)
                }
                Spacer()
                Button("許可を要求") { guide.requestPostEvent() }
                    .disabled(guide.postEventGranted || !guide.accessibilityGranted)
            }
            Divider()
            HStack {
                Image(systemName: "mic.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text("マイク入力")
                    Text(guide.microphoneStatus == .authorized ? "許可済み" : "未許可")
                        .foregroundStyle(guide.microphoneStatus == .authorized ? Color.green : Color.orange)
                }
                Spacer()
                Button("許可を要求") { guide.requestMicrophone() }
                    .disabled(guide.microphoneStatus == .authorized || guide.microphoneRequestInProgress)
            }
            Text("macOS 27以降：プライバシーとセキュリティ → デバイスの制御とデータへのアクセス／マイク。アクセシビリティがONでも入力イベント送信が未許可ならキー入力できません。")
                .font(.caption).foregroundStyle(.secondary)
            if !guide.message.isEmpty {
                Text(guide.message).font(.caption).foregroundStyle(.secondary)
            }
            if !guide.needsAttention {
                Text("許可は確認済みです。『閉じる』で設定画面を閉じ、入力したい欄をクリックしてから録音してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("状態を更新") {
                    guide.refresh()
                    // Do not keep KoeBridge's settings window as the focused
                    // app after onboarding; dictation must start in an editor.
                    if !guide.needsAttention { NSApp.keyWindow?.performClose(nil) }
                }
                Spacer()
                Button("閉じる") { NSApp.keyWindow?.performClose(nil) }
            }
        }
        .padding(22)
        .frame(width: 510, height: 440)
    }
}
#endif
