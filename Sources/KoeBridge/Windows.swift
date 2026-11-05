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
                contentRect: NSRect(x: 0, y: 0, width: 1050, height: 710),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "KoeBridge 設定"
            window.center()
            window.contentView = NSHostingView(rootView: SettingsView(controller: .shared, guide: .shared))
            window.minSize = NSSize(width: 850, height: 610)
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
        let stage = controller.overlayFeedback
        guard stage == .recording else { return stage.message }
        let full = controller.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return stage.message }
        return full.count > 180 ? "…" + String(full.suffix(180)) : full
    }

    private var feedbackSymbol: String {
        switch controller.overlayFeedback {
        case .hidden, .preparing: return "mic"
        case .recording: return "waveform"
        case .processing: return "ellipsis"
        case .sent: return "arrow.up.circle.fill"
        case .saved: return "clock.arrow.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(controller.isRecording ? Color.red.opacity(0.15) : Color.secondary.opacity(0.12))
                    .frame(width: 38, height: 38)
                if controller.overlayFeedback == .processing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("文字起こしの確定処理中")
                } else {
                    Image(systemName: feedbackSymbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(controller.isRecording ? Color.red : Color.secondary)
                        .accessibilityHidden(true)
                }
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
                Text("保存した文章：\(controller.history.count) / 10件")
                    .font(.headline)
                Spacer()
                Text("直近10件を保存。音声データ・APIキーは保存しません")
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
                                Button("文章をコピー") { controller.copyRecord(selected) }
                                Button("この文章を削除", role: .destructive) {
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
                Text("自動入力が相手のアプリで受け付けられたかは確認できません。必要に応じて文章をコピーしてください。")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("履歴をすべて削除", role: .destructive) { confirmDeleteAll = true }
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

/// Five focused settings pages replace the old tall Form, which clipped its
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
    @State private var navigation = SettingsNavigation()
    @State private var searchText = ""
    @State private var searchTarget: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 247)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.80))
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 0) {
                        Button { navigation.back() } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 28, height: 28)
                        }
                        .disabled(!navigation.canGoBack)
                        .help("前の設定画面へ戻る")
                        Divider().frame(height: 18)
                        Button { navigation.forward() } label: {
                            Image(systemName: "chevron.right")
                                .frame(width: 28, height: 28)
                        }
                        .disabled(!navigation.canGoForward)
                        .help("次の設定画面へ進む")
                    }
                    .buttonStyle(.borderless)
                    Text(navigation.selected.title)
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                Divider()
                displayedPage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 570)
        .alert("動作記録を削除しますか？", isPresented: $confirmDeleteLog) {
            Button("削除", role: .destructive) {
                do {
                    try DiagnosticLog.deleteExistingFiles()
                    logNotice = "動作記録を削除しました"
                } catch {
                    logNotice = "動作記録を削除できません：\(error.localizedDescription)"
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("KoeBridge.log と古いログ1件を削除します。文字起こし履歴や設定は削除されません。")
        }
        .alert("Gemini APIキーを削除しますか？", isPresented: $confirmDeleteKey) {
            Button("削除", role: .destructive) {
                controller.deleteKey()
                apiKeyDraft = ""
                apiKeyNotice = "APIキーを削除しました"
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("macOSのキーチェーン内に保存したKoeBridge用APIキーを削除します。")
        }
    }

    private func go(_ section: SettingsSection) {
        navigation.select(section)
    }

    /// Search navigates to the correct real setting and scrolls it into view.
    private func scrollablePage<Content: View>(
        _ section: SettingsSection, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView { content() }
                .onAppear { scrollToSearchResult(proxy, section: section) }
                .onChange(of: searchTarget) { _, _ in scrollToSearchResult(proxy, section: section) }
        }
    }

    private func scrollToSearchResult(_ proxy: ScrollViewProxy, section: SettingsSection) {
        guard navigation.selected == section, let searchTarget else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(searchTarget, anchor: .top)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("KoeBridge")
                        .font(.system(size: 17, weight: .bold))
                    Text("設定")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 24)
            .padding(.bottom, 20)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("設定を検索", text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("設定を検索")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("検索をクリア")
                }
            }
            .padding(9)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 13)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        sidebarGroup("基本", pages: [.general, .voice, .gemini, .usage])
                        Divider().padding(.horizontal, 16)
                        sidebarGroup("データと安全", pages: [.history, .permissions])
                        Divider().padding(.horizontal, 16)
                        sidebarGroup("サポート", pages: [.help, .about])
                    } else {
                        Text("検索結果")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 18)
                        let results = SettingsSearchCatalog.find(searchText)
                        if results.isEmpty {
                            Text("一致する設定がありません")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                        } else {
                            ForEach(results) { result in
                                Button {
                                    go(result.section)
                                    searchText = ""
                                    searchTarget = result.id
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: result.section.symbol)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(result.title).font(.subheadline)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Text(result.section.title)
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(result.title)、\(result.section.title)を開く")
                            }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func sidebarGroup(_ title: String, pages: [SettingsSection]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 3)
            ForEach(pages, id: \.self) { page in
                Button { go(page) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: page.symbol)
                            .font(.system(size: 15))
                            .frame(width: 20)
                        Text(page.title)
                            .font(.system(size: 14, weight: navigation.selected == page ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .foregroundStyle(navigation.selected == page ? Color.white : Color.primary)
                    .background(navigation.selected == page ? Color.accentColor : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(navigation.selected == page ? [.isSelected] : [])
                .padding(.horizontal, 10)
            }
        }
    }

    @ViewBuilder private var displayedPage: some View {
        switch navigation.selected {
        case .general: generalPage
        case .voice: voicePage
        case .gemini: geminiPage
        case .usage: UsageMonitorView(controller: controller, focusID: searchTarget)
        case .history: privacyPage
        case .permissions: permissionsPage
        case .help: helpPage
        case .about: aboutPage
        }
    }

    private var generalPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headline("一般", detail: "現在の利用状態と、よく使う設定への入口です。")
                GroupBox {
                    VStack(spacing: 0) {
                        settingsRow("文字起こしの方法",
                                    description: "現在の選択：\(controller.requestedMode.settingsLabel)", icon: "waveform") {
                            Button("変更する") { go(.voice) }
                        }
                        Divider()
                        settingsRow("録音の開始・終了キー",
                                    description: "現在の選択：\(controller.shortcutChoice.label)", icon: "keyboard") {
                            Button("変更する") { go(.voice) }
                        }
                        Divider()
                        settingsRow("Gemini APIキー",
                                    description: controller.hasKey ? "Macのキーチェーンに登録済みです。" : "未登録です。Apple認識はキーなしで使用できます。") {
                            Button("設定する") { go(.gemini) }
                        }
                        Divider()
                        settingsRow("アプリの利用許可",
                                    description: "録音と自動入力に必要なmacOSの権限を確認します。") {
                            Button("確認する") { go(.permissions) }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("現在の設定", systemImage: "gearshape")
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("録音キーを押してからマイクが使えるまでと、録音終了後に入力を送信するまでの実測時間を表示します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Label("録音開始まで", systemImage: "mic")
                            Spacer()
                            Text(controller.lastStartupSeconds.map { String(format: "%.2f秒", $0) } ?? "未計測")
                                .monospacedDigit()
                        }
                        Divider()
                        HStack {
                            Label("録音停止から入力送信まで", systemImage: "arrow.up.circle")
                            Spacer()
                            Text(controller.lastStopToInputSeconds.map { String(format: "%.2f秒", $0) } ?? "未計測")
                                .monospacedDigit()
                        }
                        Text("端末や接続環境により変動します。送信時間には相手アプリでの受理確認は含みません。")
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
                        Text("KoeBridgeはメニューバーから操作します。録音キーを押すと準備を始め、録音中にもう一度押すと文字起こしを確定します。")
                        Text("自動入力ができなかった場合は、履歴の文章をコピーできます。")
                        Button("使い方を確認する") { go(.help) }
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
    }

    private var helpPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headline("ヘルプ", detail: "使い方と、うまく動作しないときの確認先です。")
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("1. 文字を入力したいアプリの入力欄を選びます。", systemImage: "cursorarrow.click.2")
                        Label("2. 設定したキーで録音を開始します。", systemImage: "mic")
                        Label("3. 同じキーで録音を終了し、確定処理が終わると自動入力を試みます。", systemImage: "checkmark.circle")
                        Text("現在の録音キー：\(controller.shortcutChoice.label)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } label: { Label("基本操作", systemImage: "list.number") }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("音声入力できないとき")
                            .font(.headline)
                        Text("利用許可を確認し、マイクと文字の入力操作が許可されているか確認してください。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("利用許可を確認") { go(.permissions) }
                        Divider()
                        Text("自動入力だけができないとき")
                            .font(.headline)
                        Text("元の入力欄が選択されたままか確認してください。履歴から文章をコピーすることもできます。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("履歴と記録を開く") { go(.history) }
                        Divider()
                        Text("Geminiが使えないとき")
                            .font(.headline)
                        Text("APIキーの登録状況やネットワーク接続を確認します。Appleへの自動切替が行われる場合もあります。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Geminiの設定を開く") { go(.gemini) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } label: { Label("トラブル対処", systemImage: "wrench.and.screwdriver") }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var aboutPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headline("情報", detail: "KoeBridgeのバージョンと公開ソースコードです。")
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("KoeBridge", systemImage: "waveform")
                            .font(.title2.weight(.semibold))
                        Text("バージョン：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未取得")")
                        Text("ビルド：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未取得")")
                        Text("macOS向けの軽量音声入力アプリ。ソースコードはMITライセンスで公開されています。")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("公式GitHubリポジトリを開く",
                             destination: URL(string: "https://github.com/ma-do-ka/KoeBridge")!)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } label: { Label("アプリについて", systemImage: "info.circle") }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Each setting has a plain-language label and a short secondary explanation.
    private func settingsRow<Accessory: View>(
        _ title: String, description: String, icon: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func headline(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var voicePage: some View {
        scrollablePage(.voice) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("音声入力").font(.title2.weight(.semibold))
                        Text("話した内容を文字に変換し、元の入力欄への入力を試みます。")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 6)
                GroupBox {
                    VStack(spacing: 0) {
                        settingsRow("文字起こしの方法",
                                    description: "音声を文字に変換する方法を選びます。GeminiはGoogleのAPIを使用し、AppleはこのMac内で処理します。") {
                            Picker("文字起こしの方法", selection: $controller.requestedMode) {
                                Text("Gemini API").tag(RecognitionMode.gemini)
                                Text("Apple（Mac内）").tag(RecognitionMode.local)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 245)
                        }
                        .id("engine")
                        Divider()
                        settingsRow("録音の開始・終了キー",
                                    description: "選んだキーで録音を開始し、もう一度押すと終了します。ほかのアプリのキー操作と競合する場合があります。") {
                            Picker("録音の開始・終了キー", selection: Binding(
                                get: { controller.shortcutChoice },
                                set: { controller.selectShortcut($0) }
                            )) {
                                ForEach(RecordingShortcut.allCases) { choice in
                                    Text(choice.label).tag(choice)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 250)
                        }
                        .id("shortcut")
                        if !controller.shortcutProblem.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(controller.shortcutProblem)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                settingsRow("録音キーを再登録",
                                            description: "設定したキーが反応しない場合に、ショートカットの登録をやり直します。") {
                                    Button("再登録") { controller.retryShortcutRegistration() }
                                }
                            }
                        }
                        Divider()
                        settingsRow("認識した文章を自動入力する",
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
                GroupBox {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("クリップボードを使わず、認識した文章をキー入力として送信します。")
                        Text("入力先の変更や権限不足が検出された場合は自動入力を中止し、文章を直近10件の履歴に保存します。")
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

    private var geminiPage: some View {
        scrollablePage(.gemini) {
            VStack(alignment: .leading, spacing: 18) {
                headline("Gemini API", detail: "Geminiを使うための接続情報と文字起こし方法を設定します。Appleの音声認識には適用されません。")
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Gemini APIキー").font(.system(size: 14, weight: .medium))
                            Text("Google AI Studioで発行したキーを登録します。Macのキーチェーンに保存し、保存済みの値は表示しません。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SecureField("Gemini APIキーを入力", text: $apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .id("apikey")
                        HStack(spacing: 10) {
                            Label(controller.hasKey ? "キーチェーンに登録済み" : "APIキー未登録",
                                  systemImage: controller.hasKey ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("APIキーを保存") {
                                do {
                                    try controller.saveKey(apiKeyDraft)
                                    apiKeyDraft = ""
                                    apiKeyNotice = "APIキーを保存しました"
                                } catch {
                                    apiKeyNotice = "保存に失敗しました：\(error.localizedDescription)"
                                }
                            }
                            .disabled(apiKeyDraft.isEmpty)
                            Button("APIキーを削除", role: .destructive) { confirmDeleteKey = true }
                                .disabled(!controller.hasKey)
                        }
                        Text("新しいキーを保存すると登録済みのキーを置き換えます。削除後にGeminiを使うには再登録が必要です。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if !apiKeyNotice.isEmpty {
                            Text(apiKeyNotice).font(.caption).textSelection(.enabled)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("API接続", systemImage: "key.horizontal")
                }
                GroupBox {
                    VStack(spacing: 0) {
                        settingsRow("日本語での認識を優先する",
                                    description: "日本語を中心に話す場合に有効にしてください。Geminiに日本語の言語設定を送ります。オフでは言語を指定しません。", icon: "character.book.closed") {
                            Toggle("日本語での認識を優先する", isOn: $controller.japaneseHint)
                                .labelsHidden().toggleStyle(.switch)
                        }
                        .id("japanese")
                        Divider()
                        settingsRow("話した内容を読みやすく整える",
                                    description: "言い直しや「えーと」などを整理し、自然な文章への変換を試みます。発言をできるだけそのまま残す場合はオフにしてください。", icon: "text.alignleft") {
                            Toggle("話した内容を読みやすく整える", isOn: $controller.smartFormatting)
                                .labelsHidden().toggleStyle(.switch)
                        }
                        .id("smart")
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("固有名詞・専門用語を登録")
                                .font(.system(size: 14, weight: .medium))
                            Text("認識してほしい製品名や技術用語を1行に1語ずつ入力します。重複を除いた最大100語をGeminiに送信します。表記を強制する機能ではありません。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            TextEditor(text: $controller.vocabulary)
                                .id("words")
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 125)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(Color.secondary.opacity(0.25))
                                }
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(8)
                } label: {
                    Label("文字起こしの調整", systemImage: "text.badge.checkmark")
                }
                GroupBox {
                    Text("Geminiの利用中は録音した音声がGoogleのAPIへ送信されます。料金や利用制限はGoogle側の契約・課金条件に従います。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } label: {
                    Label("Gemini利用時のプライバシーと料金", systemImage: "lock.shield")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var privacyPage: some View {
        scrollablePage(.history) {
            VStack(alignment: .leading, spacing: 18) {
                headline("履歴・記録", detail: "文字起こし履歴の確認と、不具合調査用の動作記録を管理します。")
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        settingsRow("保存件数：\(controller.history.count) / 10件",
                                    description: "直近10件の文字起こし結果をMacに保存します。音声やAPIキーは保存しません。") {
                            Button("保存した文章を見る") { controller.onShowHistory?() }
                        }
                        .id("history")
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
                        settingsRow("問題調査用の記録を残す",
                                    description: "不具合調査に役立つ動作情報を保存します。通常はオフで問題ありません。認識した文章・音声・APIキーは記録しません。", icon: "stethoscope") {
                            Toggle("問題調査用の記録を残す", isOn: $diagnosticsEnabled)
                                .id("logging")
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
                        settingsRow("動作記録を削除",
                                    description: "保存済みの動作記録だけを削除します。文字起こし履歴や設定は変更されません。", icon: "trash") {
                            Button("削除", role: .destructive) { confirmDeleteLog = true }
                        }
                        Text("保存先：~/Library/Logs/KoeBridge.log")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("1ファイル192KB、古いログ1件を含め最大約384KB。記録をオフにしても以前のログは残ります。")
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
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissionsPage: some View {
        scrollablePage(.permissions) {
            VStack(alignment: .leading, spacing: 18) {
                headline("利用許可", detail: "録音と文字入力に必要なmacOSの許可状態を確認します。許可はmacOSが管理します。")
                GroupBox {
                    VStack(spacing: 0) {
                        permissionRow("入力先へのアクセスを許可",
                                      description: "文字を入力する場所を確認し、意図しない入力を防ぐために必要です。macOSのアクセシビリティ機能を利用します。",
                                      icon: "hand.raised.fill",
                                      isGranted: guide.accessibilityGranted,
                                      canRequest: !guide.accessibilityGranted) {
                            guide.requestAccessibility()
                        }
                        .id("accessibility")
                        Divider().padding(.vertical, 6)
                        permissionRow("文字の入力操作を許可",
                                      description: "認識した文章を、ほかのアプリへキーボード入力として送信するために必要です。",
                                      icon: "keyboard.fill",
                                      isGranted: guide.postEventGranted,
                                      canRequest: !guide.postEventGranted && guide.accessibilityGranted) {
                            guide.requestPostEvent()
                        }
                        .id("post")
                        Divider().padding(.vertical, 6)
                        permissionRow("マイクの使用を許可",
                                      description: "音声を録音して文字起こしするために必要です。音声は選択した認識方法に従って処理されます。",
                                      icon: "mic.fill",
                                      isGranted: guide.microphoneStatus == .authorized,
                                      canRequest: guide.microphoneStatus != .authorized && !guide.microphoneRequestInProgress) {
                            guide.requestMicrophone()
                        }
                        .id("microphone")
                    }
                    .padding(8)
                } label: {
                    Label("アプリの利用許可", systemImage: "checkmark.shield")
                }
                if !guide.message.isEmpty {
                    Text(guide.message)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GroupBox {
                    VStack(spacing: 0) {
                        settingsRow("許可状態を再確認",
                                    description: "macOSで変更した許可状態を読み直します。") {
                            Button("再確認") { guide.refresh() }
                        }
                        Divider()
                        settingsRow("利用許可の案内を開く",
                                    description: "必要な許可と設定方法をまとめて確認できます。") {
                            Button("案内を開く") { controller.onShowPermissions?() }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("許可の操作", systemImage: "arrow.clockwise")
                }
                Text("一度拒否した許可は、再要求してもダイアログが表示されない場合があります。macOSのシステム設定「プライバシーとセキュリティ」で確認してください。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { guide.refresh() }
    }

    private func permissionRow(
        _ title: String, description: String, icon: String,
        isGranted: Bool, canRequest: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                Label(isGranted ? "許可済み" : "未許可",
                      systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(isGranted ? Color.green : Color.orange)
                    .font(.caption)
                Button("許可を求める", action: action)
                    .disabled(!canRequest)
            }
        }
        .padding(.vertical, 8)
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
            message = "まず『入力先へのアクセスを許可』の設定が必要です。"
            return
        }
        _ = TextInsertion.requestPostEventAccess()
        refresh()
        message = postEventGranted
            ? "入力イベントの送信が許可されました。"
            : "文字の入力操作は未許可です。macOSが再度ダイアログを出さない場合、プライバシー設定でKoeBridgeを確認してください。"
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("音声入力に必要な許可")
                    .font(.title2).fontWeight(.semibold)
                Text("マイクによる録音と、ほかのアプリへの文字入力のためにmacOSの利用許可が必要です。")
                    .font(.caption).foregroundStyle(.secondary)
                permissionHelpRow(
                    "入力先へのアクセスを許可",
                    description: "入力先を確認し、意図しない場所への入力を防ぐために必要です。",
                    icon: "hand.raised.fill",
                    isGranted: guide.accessibilityGranted,
                    canRequest: !guide.accessibilityGranted
                ) { guide.requestAccessibility() }
                Divider()
                permissionHelpRow(
                    "文字の入力操作を許可",
                    description: "認識した文字を、ほかのアプリへ入力するために必要です。",
                    icon: "keyboard.fill",
                    isGranted: guide.postEventGranted,
                    canRequest: !guide.postEventGranted && guide.accessibilityGranted
                ) { guide.requestPostEvent() }
                Divider()
                permissionHelpRow(
                    "マイクの使用を許可",
                    description: "音声を録音して文字に変換するために必要です。",
                    icon: "mic.fill",
                    isGranted: guide.microphoneStatus == .authorized,
                    canRequest: guide.microphoneStatus != .authorized && !guide.microphoneRequestInProgress
                ) { guide.requestMicrophone() }
                Text("一度拒否した許可はmacOSのシステム設定「プライバシーとセキュリティ」から変更してください。入力先へのアクセスが許可済みでも、文字の入力操作が未許可の場合は入力できません。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !guide.message.isEmpty {
                    Text(guide.message)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !guide.needsAttention {
                    Text("必要な許可は確認済みです。「閉じる」で案内を閉じ、入力したい欄をクリックしてから録音してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("許可状態を再確認") {
                        guide.refresh()
                        if !guide.needsAttention { NSApp.keyWindow?.performClose(nil) }
                    }
                    Spacer()
                    Button("閉じる") { NSApp.keyWindow?.performClose(nil) }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 510, height: 440)
    }

    private func permissionHelpRow(
        _ title: String, description: String, icon: String,
        isGranted: Bool, canRequest: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 23)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(description)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(isGranted ? "許可済み" : "未許可")
                    .font(.caption)
                    .foregroundStyle(isGranted ? Color.green : Color.orange)
                Button("許可を求める", action: action)
                    .disabled(!canRequest)
            }
        }
    }
}
#endif
