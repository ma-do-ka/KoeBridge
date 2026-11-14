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
    @StateObject private var presetEditor = TransformPresetEditorState()
    @State private var apiKeyDraft = ""
    @State private var apiKeyNotice = ""
    @State private var logNotice = ""
    @State private var confirmDeleteLog = false
    @State private var confirmDeleteKey = false
    @State private var navigation = SettingsNavigation()
    @State private var searchText = ""
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
            Text("対象：KoeBridge.log と古いログ1件のみ。履歴・利用統計・保存音声・設定は変更しません。削除は取り消せません。")
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
        // The menu can open Settings before SwiftUI subscribes.
        // Handle that pending request on view appearance as well.
        .onReceive(NotificationCenter.default.publisher(for: .settingsDestinationRequested)) { note in
            if let id = note.object as? String,
               let entry = SettingsSearchCatalog.entries.first(where: { $0.id == id }) {
                navigation.focus(entry)
                SettingsDestination.pending = nil
            }
        }
        .onAppear {
            if let id = SettingsDestination.pending,
               let entry = SettingsSearchCatalog.entries.first(where: { $0.id == id }) {
                navigation.focus(entry)
                SettingsDestination.pending = nil
            }
            Task { @MainActor in openPendingUpdatePage() }
        }
        .onReceive(updater.$requestedUpdatePage) { request in
            guard request > 0 else { return }
            // @Published publishes in willSet. Defer until storage updates.
            Task { @MainActor in openPendingUpdatePage() }
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
        guard let result = SettingsSearchCatalog.find(searchText).first else { return }
        navigation.focus(result)
        searchText = ""
    }

    private func go(_ section: SettingsSection) {
        navigation.select(section)
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
                        sidebarGroup("基本", pages: [.general, .voice, .gemini, .shortcuts, .profiles])
                        Divider().padding(.horizontal, 16)
                        sidebarGroup("データと安全", pages: [.history, .permissions])
                        Divider().padding(.horizontal, 16)
                        sidebarGroup("サポート", pages: [.about])
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
                                    navigation.focus(result)
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
        case .shortcuts:
            SettingsShortcutsPage(controller: controller, focusRequest: navigation.focusRequest)
        case .profiles:
            SettingsPageScrollView(section: .profiles, focusRequest: navigation.focusRequest) {
                SettingsAppProfilesPage(controller: controller).settingsTarget("app-profiles").padding(18)
            }
        case .history:
            SettingsPrivacyPage(
                controller: controller, historyCount: controller.history.count, diagnosticsEnabled: $diagnosticsEnabled,
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
        }
    }
}
#endif
