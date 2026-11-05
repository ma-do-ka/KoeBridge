#if os(macOS)
import AppKit
import AVFoundation
import ApplicationServices
import SwiftUI
import KoeBridgeCore

/// Eight focused settings pages replace the old tall Form. All existing
/// preferences, permissions and recognition methods are reused.
struct SettingsView: View {
    @ObservedObject var controller: VoiceController
    @ObservedObject var guide: PermissionGuide
    @StateObject private var loginItem = LoginItemManager()
    @ObservedObject private var updater = KoeBridgeUpdateManager.shared
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { colorScheme == .dark }
    private var pageBackground: Color {
        dark ? Color(red: 0.079, green: 0.083, blue: 0.107)
             : Color(red: 0.955, green: 0.962, blue: 0.975)
    }
    private var sidebarBackground: Color {
        dark ? Color(red: 0.117, green: 0.120, blue: 0.145)
             : Color(red: 0.916, green: 0.932, blue: 0.955)
    }
    @AppStorage("diagnosticsEnabled") private var diagnosticsEnabled = false
    @State private var apiKeyDraft = ""
    @State private var apiKeyNotice = ""
    @State private var logNotice = ""
    @State private var confirmDeleteLog = false
    @State private var confirmDeleteKey = false
    @State private var navigation = SettingsNavigation()
    @State private var searchText = ""
    @State private var searchTarget: String?
    @State private var permissionRefreshFeedback: SettingsPermissionRefreshFeedback = .idle
    @State private var permissionRefreshSequence = 0
    @State private var generalPermissionCheckedAt: Date?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 247)
                .background(sidebarBackground)
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
                settingsPageHeading
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 8)
                displayedPage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(pageBackground)
        }
        .groupBoxStyle(ContrastSettingsGroupBoxStyle(dark: dark))
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
        .onReceive(updater.$requestedUpdatePage) { request in
            guard request > 0 else { return }
            go(.about)
            updater.consumedUpdatePageRequest()
        }
    }

    private var settingsPageHeading: some View {
        HStack(spacing: 15) {
            SettingsCategoryIcon(section: navigation.selected, size: 62)
            VStack(alignment: .leading, spacing: 5) {
                Text(navigation.selected.title)
                    .font(.system(size: 23, weight: .semibold))
                Text(navigation.selected.pageDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var permissionSnapshot: PermissionStateSnapshot {
        PermissionStateSnapshot(
            accessibilityGranted: guide.accessibilityGranted,
            postEventGranted: guide.postEventGranted,
            microphoneStatusRaw: guide.microphoneStatus.rawValue
        )
    }

    /// OS permission checks are synchronous. Show a short inline result
    /// without claiming that a permission was newly granted.
    private func refreshPermissionStatus() {
        let before = permissionSnapshot
        permissionRefreshSequence += 1
        let sequence = permissionRefreshSequence
        permissionRefreshFeedback = .refreshing
        Task { @MainActor in
            await Task.yield()
            guard permissionRefreshSequence == sequence else { return }
            guide.refreshFromSettings()
            let result = SettingsUXPolicy.refreshResult(before: before, after: permissionSnapshot)
            permissionRefreshFeedback = result == .changed ? .changed : .unchanged
            try? await Task.sleep(for: .seconds(3))
            if permissionRefreshSequence == sequence {
                permissionRefreshFeedback = .idle
            }
        }
    }

    private func go(_ section: SettingsSection) {
        searchTarget = nil
        navigation.select(section)
    }

    /// Search navigates to the correct real setting and scrolls it into view.
    private func scrollablePage<Content: View>(
        _ section: SettingsSection, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ScrollViewReader { proxy in
            SettingsIndicatedScrollView { content() }
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
                Group {
                    if let iconURL = Bundle.main.url(forResource: "KoeBridge_AppIcon", withExtension: "icns"),
                       let iconImage = NSImage(contentsOf: iconURL) {
                        Image(nsImage: iconImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(width: 44, height: 44)
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
            .background(dark ? Color(red: 0.185, green: 0.19, blue: 0.225)
                             : Color.white,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(dark ? Color.white.opacity(0.10)
                                       : Color.black.opacity(0.07))
            }
            .padding(.horizontal, 13)
            .padding(.bottom, 18)

            SettingsIndicatedScrollView {
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
                                        SettingsCategoryIcon(section: result.section, size: 27)
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
                        SettingsCategoryIcon(section: page, size: 34)
                        Text(page.title)
                            .font(.system(size: 14, weight: navigation.selected == page ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(navigation.selected == page && dark ? Color.white : Color.primary)
                    .background(
                        navigation.selected == page
                            ? (dark ? Color(red: 0.13, green: 0.28, blue: 0.50)
                                    : Color(red: 0.77, green: 0.86, blue: 0.99))
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(navigation.selected == page
                                          ? Color.blue.opacity(dark ? 0.54 : 0.23)
                                          : Color.clear, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(page.title)を開く")
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
        SettingsIndicatedScrollView {
            VStack(alignment: .leading, spacing: 18) {
                generalControlsCard
                generalReadinessCard
                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        settingsRow("ログイン時に自動起動",
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
                        Text("録音キーを押してからマイクが使えるまでと、録音終了後に入力を送信するまでの実測時間を表示します。")
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
                            Label("録音停止から入力送信まで", systemImage: "arrow.up.circle")
                            Spacer()
                            Text(controller.lastStopToInputSeconds.map { String(format: "%.2f秒", $0) } ?? "未計測")
                                .monospacedDigit()
                        }
                        .frame(minHeight: 34)
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
                        Label("1. 入力したい欄をクリック", systemImage: "cursorarrow.click.2")
                        Label("2. \(controller.shortcutChoice.label) で録音開始", systemImage: "mic")
                        Label("3. 同じキーでもう一度押して確定", systemImage: "checkmark.circle")
                        HStack(spacing: 12) {
                            Button("使い方を確認") { go(.help) }
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
                settingsRow("文字起こしの方法",
                            description: "Gemini API またはMac内でのApple認識を選択します。",
                            icon: "waveform") {
                    Picker("認識方法", selection: $controller.requestedMode) {
                        Text("Gemini API").tag(RecognitionMode.gemini)
                        Text("Apple（Mac内）").tag(RecognitionMode.local)
                    }
                    .labelsHidden()
                    .frame(width: 168)
                }
                Divider()
                settingsRow("録音の開始・終了キー",
                            description: "今の設定：\(controller.shortcutChoice.label)。もう一度押すと確定します。",
                            icon: "keyboard") {
                    Picker("録音キー", selection: Binding(
                        get: { controller.shortcutChoice },
                        set: { controller.selectShortcut($0) }
                    )) {
                        ForEach(RecordingShortcut.allCases) { shortcut in
                            Text(shortcut.label).tag(shortcut)
                        }
                    }
                    .labelsHidden()
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
                settingsRow("認識した文章を自動入力",
                            description: "OFFの場合、結果は履歴に保存して後からコピーできます。",
                            icon: "text.cursor") {
                    Toggle("自動入力", isOn: $controller.automaticPaste)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if controller.requestedMode == .gemini {
                    Divider()
                    settingsRow("文字起こしスタイル",
                                description: controller.transcriptionStyle.explanation,
                                icon: "text.alignleft") {
                        Picker("スタイル", selection: $controller.transcriptionStyle) {
                            ForEach(TranscriptionStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .labelsHidden()
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
                } else if !guide.accessibilityGranted || !guide.postEventGranted {
                    Label("自動入力に必要なmacOSの許可を確認してください。",
                          systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("音声入力に必要な基本設定を確認できました",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                HStack(spacing: 12) {
                    Label(guide.microphoneStatus == .authorized ? "マイク許可済み" : "マイク要確認",
                          systemImage: "mic")
                    Label(guide.accessibilityGranted && guide.postEventGranted
                          ? "入力操作許可済み" : "入力操作要確認",
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
                        Button("APIキー設定") { go(.gemini) }
                    }
                    Spacer()
                    Button("許可を再確認") {
                        guide.refreshFromSettings()
                        generalPermissionCheckedAt = Date()
                    }
                    Button("対処方法") { go(.permissions) }
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

    private var helpPage: some View {
        SettingsIndicatedScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
        scrollablePage(.about) {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    HStack(alignment: .center, spacing: 18) {
                        Group {
                            if let url = Bundle.main.url(forResource: "KoeBridge_AppIcon", withExtension: "icns"),
                               let img = NSImage(contentsOf: url) {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                Image(systemName: "waveform")
                                    .resizable()
                                    .scaledToFit()
                                    .padding(18)
                            }
                        }
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("KoeBridge")
                                .font(.system(size: 22, weight: .semibold))
                            Text("バージョン \(updater.installedLabel)")
                                .font(.headline)
                            Text("ビルド：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未取得")")
                                .foregroundStyle(.secondary)
                            Text("macOS用音声入力アプリ / MIT License")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Link("公式GitHubリポジトリ",
                                 destination: URL(string: "https://github.com/ma-do-ka/KoeBridge")!)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("アプリについて", systemImage: "info.circle")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        settingsRow("アップデートを自動的に確認",
                                    description: "1日1回を上限に、GitHubの正式リリースを確認します。",
                                    icon: "arrow.clockwise") {
                            Toggle("自動更新確認", isOn: $updater.automaticChecksEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        Divider()
                        settingsRow("アップデートを自動的にダウンロードしてインストール",
                                    description: "現在はソースコード配布のみのため未対応です。安全に配布できる署名済み更新パッケージの準備後に提供します。",
                                    icon: "square.and.arrow.down") {
                            Toggle("自動ダウンロードとインストール", isOn: .constant(false))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(true)
                                .help("公証済みアプリと安全な更新署名の準備が必要です")
                        }
                        Divider()
                        settingsRow("アップデートチャンネル",
                                    description: "現在は正式版（Stable）のみが対象です。",
                                    icon: "checkmark.seal") {
                            Text(updater.channelName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 100, alignment: .trailing)
                        }
                        Divider()
                        HStack(alignment: .center, spacing: 14) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("現在：v\(updater.installedLabel)")
                                    .font(.system(size: 14, weight: .semibold))
                                Text(updater.statusMessage)
                                    .font(.caption)
                                    .foregroundStyle(updater.state == .failed ? Color.orange : Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if updater.state == .checking {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Button("アップデートを確認…") {
                                Task { await updater.checkNow() }
                            }
                            .disabled(updater.state == .checking)
                        }
                        .padding(.vertical, 12)
                        if updater.state == .available {
                            HStack(spacing: 10) {
                                Label("新しい正式版が利用できます", systemImage: "arrow.down.circle.fill")
                                    .foregroundStyle(Color.green)
                                Spacer()
                                Button("リリースを見る") { updater.openLatestRelease() }
                                Button("更新コマンドをコピー") {
                                    _ = updater.copyUpdateCommand()
                                }
                            }
                            .font(.caption)
                            .padding(.bottom, 8)
                            Text("KoeBridgeを終了して、コピーしたコマンドをターミナルで実行してください。ビルド・署名・アプリの再起動を行います。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("自動インストールには対応していません。新しい正式版が出た場合、更新方法をここから案内します。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let checked = updater.lastCheckedAt {
                            Text("最終確認：\(checked.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("アップデート", systemImage: "arrow.triangle.2.circlepath")
                }
                .id("updates")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { updater.checkIfDue() }
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
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            } else {
                Color.clear
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
                .frame(minWidth: 126, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
        .padding(.vertical, 7)
    }

    private var voicePage: some View {
        scrollablePage(.voice) {
            VStack(alignment: .leading, spacing: 18) {
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
                                    SettingsRowActionButton("再登録") { controller.retryShortcutRegistration() }
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
                        settingsRow("文字起こしスタイル",
                                    description: controller.transcriptionStyle.explanation,
                                    icon: "text.alignleft") {
                            Picker("文字起こしスタイル", selection: $controller.transcriptionStyle) {
                                ForEach(TranscriptionStyle.allCases) { style in
                                    Text(style.title).tag(style)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 220)
                            .accessibilityLabel("文字起こしスタイル")
                        }
                        .id("smart")
                        if controller.transcriptionStyle == .agent {
                            Text("AIエージェント指示：Geminiの逐語認識を使い、専門用語の補助と最低限の改行だけを加えます。音声の聞き間違いや文字列の完全一致までは保証できません。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 8)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("固有名詞・専門用語を登録")
                                .font(.system(size: 14, weight: .medium))
                            Text("認識してほしい製品名や技術用語を1行に1語ずつ入力します。最大100語をGeminiに送信します。AIエージェント指示では一般的な開発用語も補助辞書に追加します。表記を強制する機能ではありません。")
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
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        settingsRow("保存件数：\(controller.history.count) / 10件",
                                    description: "直近10件の文字起こし結果をMacに保存します。音声やAPIキーは保存しません。") {
                            SettingsRowActionButton("文章を見る") { controller.onShowHistory?() }
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
                            SettingsRowActionButton("削除", role: .destructive) { confirmDeleteLog = true }
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
                GroupBox {
                    VStack(spacing: 0) {
                        permissionRow("入力先へのアクセスを許可",
                                      description: "文字を入力する場所を確認し、意図しない入力を防ぐために必要です。macOSのアクセシビリティ機能を利用します。",
                                      icon: "hand.raised.fill",
                                      status: guide.accessibilityGranted ? .granted : .needsReview,
                                      canRequest: !guide.accessibilityGranted) {
                            guide.requestAccessibility()
                        }
                        .id("accessibility")
                        Divider()
                        permissionRow("文字の入力操作を許可",
                                      description: "認識した文章を、ほかのアプリへキーボード入力として送信するために必要です。",
                                      icon: "keyboard.fill",
                                      status: guide.postEventGranted ? .granted
                                          : (guide.accessibilityGranted ? .needsReview : .prerequisite),
                                      canRequest: !guide.postEventGranted && guide.accessibilityGranted) {
                            guide.requestPostEvent()
                        }
                        .id("post")
                        Divider()
                        permissionRow("マイクの使用を許可",
                                      description: "音声を録音して文字起こしするために必要です。音声は選択した認識方法に従って処理されます。",
                                      icon: "mic.fill",
                                      status: guide.microphoneStatus == .authorized ? .granted
                                          : (guide.microphoneStatus == .denied ? .denied
                                             : (guide.microphoneStatus == .restricted ? .restricted : .needsReview)),
                                      canRequest: guide.microphoneStatus != .authorized && !guide.microphoneRequestInProgress,
                                      buttonTitle: guide.microphoneStatus == .notDetermined
                                          ? "許可を求める" : "対処方法") {
                            guide.requestMicrophone()
                        }
                        .id("microphone")
                    }
                    .padding(8)
                } label: {
                    Label("アプリの利用許可", systemImage: "checkmark.shield")
                }
                if !guide.message.isEmpty {
                    Label {
                        Text(guide.message)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                    }
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(dark ? Color.white.opacity(0.09) : Color.blue.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 10))
                }
                GroupBox {
                    VStack(spacing: 0) {
                        settingsRow("許可状態を再確認",
                                    description: "macOSで変更した許可状態を読み直します。",
                                    icon: "arrow.clockwise") {
                            HStack(spacing: 10) {
                                SettingsRowActionButton("再確認") {
                                    refreshPermissionStatus()
                                }
                                .disabled(permissionRefreshFeedback == .refreshing)
                                .accessibilityHint("macOSの現在の許可状態を読み直し、結果を横に表示します")
                                if permissionRefreshFeedback == .refreshing {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("確認中…")
                                    }
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("許可状態を確認中")
                                } else if permissionRefreshFeedback != .idle {
                                    Label(permissionRefreshFeedback.text,
                                          systemImage: permissionRefreshFeedback.symbol)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.green)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .accessibilityLabel("許可状態の確認結果：\(permissionRefreshFeedback.text)")
                                        .accessibilityAddTraits(.updatesFrequently)
                                }
                            }
                        }
                        Divider()
                        settingsRow("利用許可の案内を開く",
                                    description: "必要な許可と設定方法をまとめて確認できます。",
                                    icon: "questionmark.circle") {
                            SettingsRowActionButton("案内を開く") { controller.onShowPermissions?() }
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
        .onDisappear {
            permissionRefreshSequence += 1
            permissionRefreshFeedback = .idle
        }
    }

    private func permissionRow(
        _ title: String, description: String, icon: String,
        status: SettingsPermissionDisplayState, canRequest: Bool,
        buttonTitle: String = "許可を求める",
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 9) {
                SettingsPermissionStatusBadge(status: status)
                if status == .granted {
                    Text("操作不要")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if status == .prerequisite {
                    Text("上の許可を先に設定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    SettingsRowActionButton(buttonTitle, action: action)
                        .disabled(!canRequest)
                }
            }
            .frame(minWidth: 138, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 93, alignment: .center)
        .padding(.vertical, 7)
    }
}

#endif
