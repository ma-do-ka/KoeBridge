#if os(macOS)
import SwiftUI
import KoeBridgeCore

/// Draft text and notices belong to the settings window so navigation does not
/// discard a pending API key. Recognition choices bind directly to the controller.
struct SettingsGeminiPage: View {
    @ObservedObject var controller: VoiceController
    @ObservedObject var presetEditor: TransformPresetEditorState
    @State private var editingLearnedTerm: LearnedTerm?
    @Binding var apiKeyDraft: String
    @Binding var apiKeyNotice: String
    let focusRequest: SettingsFocusRequest?
    let requestKeyDeletion: () -> Void

    var body: some View {
        SettingsPageScrollView(section: .gemini, focusRequest: focusRequest) {
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
                            .settingsControlFocus("apikey").settingsTarget("apikey")
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
                            Button("APIキーを削除", role: .destructive) { requestKeyDeletion() }
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
                        SettingsRow("録音前に接続を準備する",
                                    description: "録音開始前に接続だけを準備しておき、押し始めの待ち時間をなくします。録音するまで音声は送信されません。準備した接続は5分で破棄されます。", icon: "bolt.horizontal") {
                            Toggle("録音前に接続を準備する", isOn: $controller.geminiPrewarmEnabled).settingsControlFocus("prewarm").labelsHidden()
                        }
                        .settingsTarget("prewarm")
                        Divider()
                        SettingsRow("日本語での認識を優先する",
                                    description: "日本語を中心に話す場合に有効にしてください。Geminiに日本語の言語設定を送ります。オフでは言語を指定しません。", icon: "character.book.closed") {
                            Toggle("日本語での認識を優先する", isOn: $controller.japaneseHint).settingsControlFocus("japanese")
                                .labelsHidden().toggleStyle(.switch)
                        }
                        .settingsTarget("japanese")
                        Divider()
                        SettingsRow("文字起こしスタイル",
                                    description: controller.transcriptionStyle.explanation,
                                    icon: "text.alignleft") {
                            SettingsTranscriptionStylePicker("文字起こしスタイル", selection: $controller.transcriptionStyle)
                            .settingsControlFocus("smart").pickerStyle(.menu)
                            .frame(width: 220)
                            .accessibilityLabel("文字起こしスタイル")
                        }
                        .settingsTarget("smart")
                        if controller.transcriptionStyle == .agent {
                            Text("AIエージェント指示ではGeminiの逐語認識を使います。専門用語の補助は、選択した項目だけを使用します。音声の聞き間違いや文字列の完全一致までは保証できません。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 8)
                        }
                    }.padding(8)
                } label: { Label("接続準備と言語・スタイル", systemImage: "waveform") }
                GroupBox {
                    VStack(spacing: 0) {
                        SettingsRow("LLM後処理",
                                    description: "Appleの認識結果にも適用できます（Gemini APIキーが必要）。認識結果が確定したあと、別のLLM処理で文を整えます。失敗した場合は元の認識結果がそのまま入力されます。エージェントスタイルでは適用されません。") {
                            Toggle("LLM後処理", isOn: $controller.postProcessEnabled).settingsControlFocus(ids: controller.postProcessEnabled ? ["post-processing"] : ["post-processing", "post-mode"])
                                .labelsHidden().toggleStyle(.switch)
                        }
                        .settingsTarget("post-processing")
                        SettingsRow("後処理モード", description: "Appleの認識結果にも適用できます。Gemini APIキーが必要です。") {
                            Picker("後処理モード", selection: $controller.postProcessMode) {
                                ForEach(PostProcessingMode.allCases.filter { $0 != .off }, id: \.self) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .settingsControlFocus(ids: controller.postProcessEnabled ? ["post-mode"] : []).pickerStyle(.menu).frame(width: 220)
                            .disabled(!controller.postProcessEnabled)
                        }
                        .settingsTarget("post-mode")
                    }.padding(8)
                } label: { Label("認識後の文章整形", systemImage: "text.badge.checkmark") }
                GroupBox {
                    VStack(spacing: 0) {
                        vocabularyAssistanceSettings
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("固有名詞・専門用語を登録")
                                .font(.system(size: 14, weight: .medium))
                            Text("認識してほしい製品名や技術用語を1行に1語ずつ入力します。「登録した用語を使う」がオンのときに、登録順で優先してGeminiへ送信します。他の候補と合わせて最大100語です。表記を強制する機能ではありません。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            TextEditor(text: $controller.vocabulary)
                                .settingsControlFocus("words").settingsTarget("words")
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 125)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(Color.secondary.opacity(0.25))
                                }
                        }
                        .padding(.vertical, 8)
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("学習した語彙（\(controller.learnedTerms.count)語）").font(.headline)
                            Button("履歴から修正して学習") { controller.onShowHistory?() }.settingsControlFocus("learned-terms")
                            if controller.learnedTerms.isEmpty {
                                Text("まだありません。履歴の「修正して学習」から追加できます。")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(controller.learnedTerms) { entry in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(entry.term).textSelection(.enabled)
                                        Text("← " + entry.originalFragment).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("編集") { editingLearnedTerm = entry }
                                    Button("削除", role: .destructive) { controller.learnedTerms.removeAll { $0.id == entry.id } }
                                }
                                Divider()
                            }
                            Text("学習した語彙は自分で登録した語彙の後に認識の候補へ加わります。登録した語彙を上書きしません。「登録した用語を使う」がオンのとき、開発・IT用語と合わせて最大100語を送信します。「編集」で表記を変更できます。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        .settingsTarget("learned-terms")
                    }.padding(8)
                } label: { Label("辞書と学習", systemImage: "character.book.closed") }
                GroupBox {
                    VStack(spacing: 0) {
                        contextCheckSettings
                    }
                    .padding(8)
                } label: {
                    Label("Mac内の整理・音声の再照合と文脈", systemImage: "checkmark.shield")
                }
                GroupBox("翻訳") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("翻訳の方向", selection: $controller.translationDirection) {
                            Text("自動判定").tag(TranslationDirection.auto)
                            Text("日本語 → 英語").tag(TranslationDirection.jaToEn)
                            Text("英語 → 日本語").tag(TranslationDirection.enToJa)
                        }
                        .settingsControlFocus("translation")
                        Text("翻訳キーは1回押すと実行します。録音はしません。自動判定では、ひらがな・カタカナ・漢字を含む選択は英語へ、それ以外は日本語へ翻訳します。選択テキストはGeminiへ送信されます。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("翻訳キーの設定") {
                            SettingsDestination.pending = "translate-shortcut"
                            NotificationCenter.default.post(name: .settingsDestinationRequested, object: "translate-shortcut")
                        }
                    }.padding(8)
                }.settingsTarget("translation")
                SettingsTransformPresets(controller: controller, editor: presetEditor).settingsTarget("presets")
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
        .onAppear { presetEditor.initialize(controller.transformPresets) }
        .sheet(item: $editingLearnedTerm) { entry in
            LearnedTermEditor(controller: controller, entry: entry)
        }
    }

    private var vocabularyAssistanceSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("専門用語の補助")
                .font(.system(size: 14, weight: .medium))
            Toggle(isOn: $controller.registeredVocabularyEnabled) {
                Text("登録した用語を使う")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsControlFocus("vocabulary-assistance", "registered-vocabulary").toggleStyle(.checkbox).settingsTarget("registered-vocabulary")
            Toggle(isOn: $controller.topicVocabularyEnabled) {
                Text("開発・ITの用語を使う")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .settingsControlFocus("topic-vocabulary").settingsTarget("topic-vocabulary")
            Text("GitHub、Pythonなど、アプリ内の開発・IT用語を認識の候補として使います。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("両方を外すと、専門用語の候補をGeminiに送りません。登録した用語は削除されません。文字起こしスタイルを変えても、選択は変わりません。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .settingsTarget("vocabulary-assistance")
    }

    private var contextCheckSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mac内の句読点整理")
                .font(.system(size: 14, weight: .medium))
            Toggle(isOn: $controller.textContextCheckEnabled) {
                Text("Mac内で句読点を整理する")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsControlFocus("context-check").toggleStyle(.checkbox)
            Text("「という。こと」など、限られた日本語の区切りをMac内で整えます。語句の追加や言い換えは行いません。追加の通信・API料金はありません。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle(isOn: $controller.audioRecheckEnabled) {
                Text("音声を再認識して照合する")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsControlFocus(ids: controller.audioRecheckEnabled ? ["audio-recheck"] : ["audio-recheck", "audio-policy"]).toggleStyle(.checkbox)
            .settingsTarget("audio-recheck")
            Text("同じ録音をGoogleのAPIへもう一度送り、認識結果を比べます。追加の通信・待ち時間・API料金が発生します。語句が異なる場合は自動入力せず、元の文章と候補を履歴に残します。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                VStack(alignment: .leading, spacing: 6) {
                    Text("音声と照合するタイミング")
                        .font(.system(size: 13, weight: .medium))
                    Picker("音声と照合するタイミング", selection: $controller.audioRecheckPolicy) {
                        ForEach(AudioRecheckPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 270, alignment: .leading)
                    .accessibilityLabel("音声と照合するタイミング")
                    .settingsControlFocus(ids: controller.audioRecheckEnabled ? ["audio-policy"] : [])
                    .settingsTarget("audio-policy")
                    .disabled(!controller.audioRecheckEnabled)
                    Text("長い音声・通信待ちでは未完了となり、元の確定文を使います。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 20)
            }
            Divider().padding(.vertical, 4)
            Toggle("文脈を使って再チェックを補助する", isOn: $controller.recheckContextEnabled)
                .settingsControlFocus(ids: controller.recheckContextEnabled ? ["context"] : ["context", "context-app", "context-selection", "context-surrounding"]).toggleStyle(.checkbox).settingsTarget("context")
            VStack(alignment: .leading, spacing: 8) {
                Toggle("アプリ名", isOn: $controller.contextAppEnabled).settingsControlFocus(ids: controller.recheckContextEnabled ? ["context-app"] : []).settingsTarget("context-app")
                Toggle("選択テキスト", isOn: $controller.contextSelectionEnabled).settingsControlFocus(ids: controller.recheckContextEnabled ? ["context-selection"] : []).settingsTarget("context-selection")
                Toggle("周辺テキスト", isOn: $controller.contextSurroundingEnabled).settingsControlFocus(ids: controller.recheckContextEnabled ? ["context-surrounding"] : []).settingsTarget("context-surrounding")
            }
            .toggleStyle(.checkbox)
            .disabled(!controller.recheckContextEnabled)
            .padding(.leading, 20)
            Text("有効にした項目だけが、再チェック時にGeminiへ送られます。録音そのものの送信先は変わりません。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("選択・周辺テキストは各2,000文字まで。読み取れない項目は送信しません。音声の再認識が有効な場合に使用します。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("句読点整理と音声の再照合を両方オフにすると、追加の確認を行いません。Geminiで認識できた録音に適用し、Appleローカルで認識した場合は実行しません。設定の選択は保持されます。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .settingsTarget("context-check")
    }
}
private struct LearnedTermEditor: View {
    @ObservedObject var controller: VoiceController
    @State var entry: LearnedTerm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("学習した語彙を編集").font(.headline)
            TextField("正しい表記：", text: $entry.term)
            Text("← " + entry.originalFragment).textSelection(.enabled)
            Text("正しい表記は1〜60文字。同じ表記がある場合は1件にまとめます。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button("保存") {
                    guard controller.learnedTerms.contains(where: { $0.id == entry.id }) else { dismiss(); return }
                    let others = controller.learnedTerms.filter { $0.id != entry.id }
                    controller.learnedTerms = LearnedTermPolicy.saving(entry, in: others)
                    dismiss()
                }
                .disabled(LearnedTermPolicy.normalized(entry.term).isEmpty || entry.term.count > 60)
            }
        }
        .textFieldStyle(.roundedBorder).padding(20).frame(width: 420)
    }
}
#endif
