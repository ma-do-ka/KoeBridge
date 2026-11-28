#if os(macOS)
import AppKit
import SwiftUI
import KoeBridgeCore

/// Owns navigation and window-lived drafts; page views receive their actual
/// settings dependencies and bindings explicitly.
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
    // Hidden in every build until the Konami command is entered in this window.
    @AppStorage(DeveloperToolsUnlockStore.defaultsKey) private var developerToolsUnlocked = false
    @StateObject private var presetEditor = TransformPresetEditorState()
    @StateObject private var benchRecorder: BenchRecordingCoordinator
    @State private var apiKeyDraft = ""
    @State private var apiKeyNotice = ""
    @State private var amiVoiceKeyDraft = ""
    @State private var amiVoiceKeyNotice = ""
    @State private var logNotice = ""
    @State private var confirmDeleteLog = false
    @State private var confirmDeleteKey = false
    @State private var confirmDeleteAmiVoiceKey = false
    @State private var navigation = SettingsNavigation()
    @State private var searchText = ""
    @State private var generalPermissionCheckedAt: Date?

    init(controller: VoiceController, guide: PermissionGuide) {
        self.controller = controller
        self.guide = guide
        _benchRecorder = StateObject(wrappedValue: BenchRecordingCoordinator(controller: controller))
    }

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
        .alert("診断ログをすべて削除しますか？", isPresented: $confirmDeleteLog) {
            Button("削除", role: .destructive) {
                do {
                    try DiagnosticLog.deleteExistingFiles()
                    logNotice = "動作記録を削除しました"
                } catch {
                    DiagnosticLog.record("diagnostic log deletion failed: \(error.localizedDescription)")
                    logNotice = UserFacingErrorMessage.message(for: error, operation: "動作記録の削除")
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("対象：KoeBridge.log と KoeBridge-mic.log、および両方の番号付き世代ファイル。履歴・利用統計・保存音声・設定は変更しません。削除は取り消せません。")
        }
        .alert("Gemini APIキーを削除しますか？", isPresented: $confirmDeleteKey) {
            Button("削除", role: .destructive) {
                do {
                    try controller.deleteKey()
                    apiKeyDraft = ""
                    apiKeyNotice = "APIキーを削除しました"
                } catch {
                    DiagnosticLog.record("API key deletion failed: \(error.localizedDescription)")
                    let mappedError: Error
                    if let keyError = error as? KeychainStore.KeyError, case .security(let status) = keyError {
                        mappedError = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                    } else { mappedError = error }
                    apiKeyNotice = UserFacingErrorMessage.message(for: mappedError, operation: "APIキーの削除")
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("macOSのキーチェーン内に保存したKoeBridge用APIキーを削除します。")
        }
        .alert("AmiVoice APIキーを削除しますか？", isPresented: $confirmDeleteAmiVoiceKey) {
            Button("削除", role: .destructive) {
                do {
                    try controller.deleteAmiVoiceKey()
                    amiVoiceKeyDraft = ""
                    amiVoiceKeyNotice = "APIキーを削除しました"
                } catch {
                    DiagnosticLog.record("AmiVoice API key deletion failed: \(error.localizedDescription)")
                    let mappedError: Error
                    if let keyError = error as? KeychainStore.KeyError, case .security(let status) = keyError {
                        mappedError = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                    } else { mappedError = error }
                    amiVoiceKeyNotice = UserFacingErrorMessage.message(for: mappedError, operation: "APIキーの削除")
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("macOSのキーチェーン内に保存したKoeBridge用AmiVoice APIキーを削除します。")
        }
        // The menu can open Settings before SwiftUI subscribes.
        // Handle that pending request on view appearance as well.
        .onReceive(NotificationCenter.default.publisher(for: .settingsDestinationRequested)) { note in
            if let id = note.object as? String,
               let entry = SettingsSearchCatalog.entries.first(where: { $0.id == id }) {
                focus(entry)
                SettingsDestination.pending = nil
            }
        }
        .onAppear {
            if let id = SettingsDestination.pending,
               let entry = SettingsSearchCatalog.entries.first(where: { $0.id == id }) {
                focus(entry)
                SettingsDestination.pending = nil
            }
            Task { @MainActor in openPendingUpdatePage() }
        }
        .onReceive(updater.$requestedUpdatePage) { request in
            guard request > 0 else { return }
            // @Published publishes in willSet. Defer until storage updates.
            Task { @MainActor in openPendingUpdatePage() }
        }
        .onChange(of: developerToolsUnlocked) { _, unlocked in
            guard !unlocked else { return }
            // A page that is about to disappear must not keep capturing audio
            // without any visible controls.
            DeveloperToolsRelockAction.cancelRecordingIfActive(benchRecorder)
            // Re-locking hides the page even while it is open and strips it
            // from Back/Forward history, not just from the selection.
            navigation.pruneUnavailable(
                { $0.isAvailable(developerToolsUnlocked: false) },
                fallback: .voice)
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

    private func openFirstSearchResult() {
        guard let result = SettingsSearchCatalog.find(
            searchText, developerToolsUnlocked: developerToolsUnlocked).first else { return }
        focus(result)
        searchText = ""
    }

    private func go(_ section: SettingsSection) {
        guard section.isAvailable(developerToolsUnlocked: developerToolsUnlocked) else { return }
        navigation.select(section)
    }

    /// Programmatic destinations cannot reveal the bench page while locked.
    private func focus(_ entry: SettingsSearchEntry) {
        guard entry.section.isAvailable(developerToolsUnlocked: developerToolsUnlocked) else { return }
        navigation.focus(entry)
    }

    private func openPendingUpdatePage() {
        guard updater.requestedUpdatePage > 0,
              let target = SettingsSearchCatalog.entries.first(where: { $0.id == "updates" })
        else { return }
        searchText = ""
        navigation.focus(target)
        updater.consumedUpdatePageRequest()
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
                    .onSubmit { openFirstSearchResult() }
                    .onKeyPress(.downArrow) { openFirstSearchResult(); return .handled }
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
                        sidebarGroup("基本", pages: [.general, .voice, .gemini, .amivoice, .shortcuts, .profiles])
                        Divider().padding(.horizontal, 16)
                        sidebarGroup("データと安全", pages: [.history, .permissions])
                        Divider().padding(.horizontal, 16)
                        sidebarGroup("サポート", pages: [.about])
                        if developerToolsUnlocked {
                            Divider().padding(.horizontal, 16)
                            sidebarGroup("開発ツール", pages: [.bench])
                        }
                    } else {
                        Text("検索結果")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 18)
                        let results = SettingsSearchCatalog.find(
                            searchText, developerToolsUnlocked: developerToolsUnlocked)
                        if results.isEmpty {
                            Text("一致する設定がありません")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                        } else {
                            ForEach(results) { result in
                                Button {
                                    focus(result)
                                    searchText = ""
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
        case .general:
            SettingsGeneralPage(
                controller: controller, guide: guide, loginItem: loginItem, updater: updater,
                generalPermissionCheckedAt: $generalPermissionCheckedAt,
                focusRequest: navigation.focusRequest, navigate: go
            )
        case .voice:
            SettingsVoicePage(controller: controller, focusRequest: navigation.focusRequest)
        case .gemini:
            SettingsGeminiPage(
                controller: controller, presetEditor: presetEditor, apiKeyDraft: $apiKeyDraft, apiKeyNotice: $apiKeyNotice,
                focusRequest: navigation.focusRequest, requestKeyDeletion: { confirmDeleteKey = true }
            )
        case .amivoice:
            SettingsAmiVoicePage(
                controller: controller, apiKeyDraft: $amiVoiceKeyDraft, apiKeyNotice: $amiVoiceKeyNotice,
                focusRequest: navigation.focusRequest, requestKeyDeletion: { confirmDeleteAmiVoiceKey = true },
                navigateToTerms: {
                    if let entry = SettingsSearchCatalog.entries.first(where: { $0.id == "words" }) {
                        navigation.focus(entry)
                    }
                }
            )
        case .shortcuts:
            SettingsShortcutsPage(controller: controller, focusRequest: navigation.focusRequest)
        case .profiles:
            SettingsPageScrollView(section: .profiles, focusRequest: navigation.focusRequest) {
                SettingsAppProfilesPage(controller: controller).settingsTarget("app-profiles").padding(18)
            }
        case .history:
            SettingsPrivacyPage(
                controller: controller, historyCount: controller.savedHistoryCount, diagnosticsEnabled: $diagnosticsEnabled,
                logNotice: logNotice, focusRequest: navigation.focusRequest,
                showHistory: { controller.onShowHistory?() },
                requestLogDeletion: { confirmDeleteLog = true }
            )
        case .permissions:
            SettingsPermissionsPage(
                guide: guide, focusRequest: navigation.focusRequest,
                showPermissions: { controller.onShowPermissions?() }
            )
        case .about:
            SettingsAboutPage(updater: updater, focusRequest: navigation.focusRequest, shortcutLabel: controller.shortcutChoice.label, navigate: go)
        case .bench:
            SettingsBenchRecordingPage(controller: controller, coordinator: benchRecorder, focusRequest: navigation.focusRequest)
        }
    }
}

/// Re-locking the developer tools hides the bench page, so an in-flight
/// capture must stop with it instead of recording invisibly.
@MainActor
enum DeveloperToolsRelockAction {
    /// Cancels only a session that can still be running; `.stopping` already
    /// owns its completion and `.idle` has nothing to stop.
    @discardableResult
    static func cancelRecordingIfActive(_ recorder: BenchRecordingCoordinator) -> Bool {
        switch recorder.state {
        case .preparing, .recording:
            recorder.cancelRecording(reason: "開発ツールが再ロックされたため、ベンチ録音を中止しました。")
            return true
        case .idle, .stopping:
            return false
        }
    }
}

struct CorruptSettingsNotice: View {
    let reset: () -> Void
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("この一覧を読み込めません。元のデータを保持し、編集を停止しています。")
            Button("この一覧を初期化…", role: .destructive) { confirming = true }
        }
        .alert("この一覧を初期化しますか？", isPresented: $confirming) {
            Button("初期化", role: .destructive, action: reset)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この一覧に保存されているすべての項目を削除します。取り消せません。")
        }
    }
}
#endif
