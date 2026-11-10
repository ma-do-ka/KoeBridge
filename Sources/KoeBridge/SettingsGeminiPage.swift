#if os(macOS)
import SwiftUI
import KoeBridgeCore

/// Draft text and notices belong to the settings window so navigation does not
/// discard a pending API key. Recognition choices bind directly to the controller.
struct SettingsGeminiPage: View {
    @ObservedObject var controller: VoiceController
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
                            Toggle("録音前に接続を準備する", isOn: $controller.geminiPrewarmEnabled).labelsHidden()
                        }
                        Divider()
                        SettingsRow("日本語での認識を優先する",
                                    description: "日本語を中心に話す場合に有効にしてください。Geminiに日本語の言語設定を送ります。オフでは言語を指定しません。", icon: "character.book.closed") {
                            Toggle("日本語での認識を優先する", isOn: $controller.japaneseHint)
                                .labelsHidden().toggleStyle(.switch)
                        }
                        .id("japanese")
                        Divider()
                        SettingsRow("文字起こしスタイル",
                                    description: controller.transcriptionStyle.explanation,
                                    icon: "text.alignleft") {
                            SettingsTranscriptionStylePicker("文字起こしスタイル", selection: $controller.transcriptionStyle)
                            .pickerStyle(.menu)
                            .frame(width: 220)
                            .accessibilityLabel("文字起こしスタイル")
                        }
                        .id("smart")
                        if controller.transcriptionStyle == .agent {
                            Text("AIエージェント指示ではGeminiの逐語認識を使います。専門用語の補助は、選択した項目だけを使用します。音声の聞き間違いや文字列の完全一致までは保証できません。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 8)
                        }
                        Divider()
                        SettingsRow("LLM後処理",
                                    description: "認識結果が確定したあと、別のLLM処理で文を整えます。失敗した場合は元の認識結果がそのまま入力されます。エージェントスタイルでは適用されません。") {
                            Toggle("LLM後処理", isOn: $controller.postProcessEnabled)
                                .labelsHidden().toggleStyle(.switch)
                        }
                        SettingsRow("後処理モード", description: "Appleの認識結果にも適用できます。Gemini APIキーが必要です。") {
                            Picker("後処理モード", selection: $controller.postProcessMode) {
                                ForEach(PostProcessingMode.allCases.filter { $0 != .off }, id: \.self) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.menu).frame(width: 220)
                            .disabled(!controller.postProcessEnabled)
                        }
                        Divider()
                        vocabularyAssistanceSettings
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("固有名詞・専門用語を登録")
                                .font(.system(size: 14, weight: .medium))
                            Text("認識してほしい製品名や技術用語を1行に1語ずつ入力します。「登録した用語を使う」がオンのときに、登録順で優先してGeminiへ送信します。他の候補と合わせて最大100語です。表記を強制する機能ではありません。")
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
                        Divider()
                        contextCheckSettings
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

    private var vocabularyAssistanceSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("専門用語の補助")
                .font(.system(size: 14, weight: .medium))
            Toggle(isOn: $controller.registeredVocabularyEnabled) {
                Text("登録した用語を使う")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            Toggle(isOn: $controller.topicVocabularyEnabled) {
                Text("開発・ITの用語を使う")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
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
        .id("vocabulary-assistance")
    }

    private var contextCheckSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文脈チェック")
                .font(.system(size: 14, weight: .medium))
            Toggle(isOn: $controller.textContextCheckEnabled) {
                Text("文章のつながりと句読点を確認する")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            Text("「という。こと」など、限られた日本語の区切りをMac内で整えます。語句の追加や言い換えは行いません。追加の通信・API料金はありません。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $controller.audioRecheckEnabled) {
                Text("音声を再認識して照合する")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            Text("同じ録音をGoogleのAPIへもう一度送り、認識結果を比べます。追加の通信・待ち時間・API料金が発生します。語句が異なる場合は自動入力せず、元の文章と候補を履歴に残します。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if controller.audioRecheckEnabled {
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
                    Text("長い音声・通信待ちでは未完了となり、元の確定文を使います。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 20)
            }
            Divider().padding(.vertical, 4)
            Toggle("文脈を使って再チェックを補助する", isOn: $controller.recheckContextEnabled)
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("アプリ名", isOn: $controller.contextAppEnabled)
                Toggle("選択テキスト", isOn: $controller.contextSelectionEnabled)
                Toggle("周辺テキスト", isOn: $controller.contextSurroundingEnabled)
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
            Text("両方を外すと、追加の文脈チェックを行いません。Geminiで認識できた録音に適用し、Appleローカルで認識した場合は実行しません。設定の選択は保持されます。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .id("context-check")
    }
}
#endif
