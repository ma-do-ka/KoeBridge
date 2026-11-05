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
                GroupBox {
                    VStack(spacing: 0) {
                        settingsRow("文字起こしの方法",
                                    description: "現在の選択：\(controller.requestedMode.settingsLabel)", icon: "waveform") {
                            SettingsRowActionButton("変更する") { go(.voice) }
                        }
                        Divider()
                        settingsRow("録音の開始・終了キー",
                                    description: "現在の選択：\(controller.shortcutChoice.label)", icon: "keyboard") {
                            SettingsRowActionButton("変更する") { go(.voice) }
                        }
                        Divider()
                        settingsRow("Gemini APIキー",
                                    description: controller.hasKey ? "Macのキーチェーンに登録済みです。" : "未登録です。Apple認識はキーなしで使用できます。",
                                    icon: "key.horizontal") {
                            SettingsRowActionButton("設定する") { go(.gemini) }
                        }
                        Divider()
                        settingsRow("アプリの利用許可",
                                    description: "録音と自動入力に必要なmacOSの権限を確認します。",
                                    icon: "checkmark.shield") {
                            SettingsRowActionButton("確認する") { go(.permissions) }
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
        SettingsIndicatedScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
