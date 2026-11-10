#if os(macOS)
import AppKit
import SwiftUI
import KoeBridgeCore

/// Inline editor with immediate persistence, following the snippets section.
struct SettingsAppProfilesPage: View {
    @ObservedObject var controller: VoiceController
    @State private var expandedProfile: UUID?
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

    private func addProfile() {
        let bundle = bundleToAdd
        guard !bundle.isEmpty else { return }
        if let existing = controller.appProfiles.first(where: { $0.bundleIdentifier == bundle }) {
            expandedProfile = existing.id
        } else {
            let profile = AppProfile(bundleIdentifier: bundle,
                displayName: runningApps.first(where: { $0.id == bundle })?.name ?? bundle)
            controller.appProfiles.append(profile)
            expandedProfile = profile.id
        }
        manualBundle = ""
    }

    var body: some View {
        GroupBox {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 12) {
                    if controller.appProfiles.isEmpty {
                        Text("プロファイルはまだありません。よく使うアプリごとに、エンジンや文体を切り替えられます。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($controller.appProfiles) { $profile in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Toggle("有効", isOn: $profile.isEnabled)
                                    .toggleStyle(.switch).fixedSize()
                                Button {
                                    expandedProfile = expandedProfile == profile.id ? nil : profile.id
                                } label: {
                                    Label(profile.displayName, systemImage: expandedProfile == profile.id ? "chevron.down" : "chevron.right")
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button(role: .destructive) {
                                    controller.appProfiles.removeAll { $0.id == profile.id }
                                    if expandedProfile == profile.id { expandedProfile = nil }
                                } label: { Image(systemName: "trash") }
                                .help("このプロファイルを削除")
                                .accessibilityLabel("プロファイルを削除")
                            }
                            Text(profile.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                            if expandedProfile == profile.id {
                                AppProfileFields(profile: $profile)
                            }
                            Divider()
                        }
                        .id(profile.id)
                    }
                    Picker("起動中のアプリ", selection: $selectedBundle) {
                        Text("アプリを選択").tag("")
                        ForEach(runningApps) { app in Text(app.name).tag(app.id) }
                    }
                    HStack {
                        TextField("またはバンドルIDを入力（例：com.apple.TextEdit）", text: $manualBundle)
                            .textFieldStyle(.roundedBorder)
                        Button("一覧を更新") { refreshApps() }
                    }
                    Button {
                        addProfile()
                        if let id = expandedProfile {
                            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
                        }
                    } label: { Label("プロファイルを追加", systemImage: "plus") }
                    .disabled(bundleToAdd.isEmpty)
                    Text("プロファイルのあるアプリで録音すると、そのアプリ専用の設定が自動で適用されます。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            Label("アプリ別プロファイル", systemImage: "app.badge")
        }
        .onAppear { refreshApps() }
    }
}

private struct AppProfileFields: View {
    @Binding var profile: AppProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("表示名", text: $profile.displayName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("プロファイルの表示名")
            Picker("エンジン", selection: $profile.engine) {
                Text("グローバルに従う").tag(nil as String?)
                Text("Gemini").tag(Optional("gemini"))
                Text("Apple").tag(Optional("local"))
            }
            Picker("文体", selection: $profile.style) {
                Text("グローバルに従う").tag(nil as String?)
                Text("そのまま").tag(Optional("verbatim"))
                Text("読みやすく").tag(Optional("readable"))
                Text("エージェント").tag(Optional("agent"))
            }
            Text("追加の用語（1行に1語）").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $profile.additionalVocabulary)
                .frame(minHeight: 72, maxHeight: 120)
                .border(Color.secondary.opacity(0.25))
                .accessibilityLabel("追加の用語")
            Text("追加の用語は、グローバルの登録用語がオフでも使用します。用語・文体の補助はGeminiで使用します。")
                .font(.caption).foregroundStyle(.secondary)
            ProfileOverridePicker(title: "登録した用語を使う", selection: $profile.registeredVocabularyEnabled)
            ProfileOverridePicker(title: "開発・ITの用語を使う", selection: $profile.topicVocabularyEnabled)
            ProfileOverridePicker(title: "文脈チェック", selection: $profile.textContextCheckEnabled)
            ProfileOverridePicker(title: "音声の再チェック", selection: $profile.audioRecheckEnabled)
            ProfileOverridePicker(title: "音声を毎回再チェック", selection: $profile.audioRecheckAlways)
            Text("「音声を毎回再チェック」がオフの場合は、疑わしい箇所があるときだけ再チェックします。")
                .font(.caption).foregroundStyle(.secondary)
            ProfileOverridePicker(title: "後処理", selection: $profile.postProcessEnabled)
            Picker("後処理のモード", selection: $profile.postProcessMode) {
                Text("グローバルに従う").tag(nil as String?)
                ForEach(PostProcessingMode.allCases, id: \.rawValue) { mode in
                    Text(mode.label).tag(Optional(mode.rawValue))
                }
            }
        }
        .pickerStyle(.menu)
    }
}

private struct ProfileOverridePicker: View {
    let title: String
    @Binding var selection: Bool?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("グローバルに従う").tag(nil as Bool?)
            Text("オン").tag(Optional(true))
            Text("オフ").tag(Optional(false))
        }
    }
}
#endif
