#if os(macOS)
import SwiftUI
import KoeBridgeCore

/// Dedicated settings page for AmiVoice Cloud Platform configuration.
/// Draft API key text and notices live in SettingsView so navigation preserves drafts.
struct SettingsAmiVoicePage: View {
    @ObservedObject var controller: VoiceController
    @Binding var apiKeyDraft: String
    @Binding var apiKeyNotice: String
    let focusRequest: SettingsFocusRequest?
    let requestKeyDeletion: () -> Void
    let navigateToTerms: () -> Void
    @State private var showSyncConsent = false
    @State private var showVocabularyManagement = false
    @State private var showSyncHistory = false
    @State private var showSyncDeleteAll = false
    @State private var stepBNotice = ""

    private var copy: AmiVoiceVocabularyManagementCopy.Type { AmiVoiceVocabularyManagementCopy.self }

    /// First ON requires the consent panel unless a consent record is already
    /// persisted; OFF always applies directly through B-1's opt-in setting.
    private var autoSyncBinding: Binding<Bool> {
        Binding(
            get: { controller.amiVoiceDictionarySyncEnabled },
            set: { newValue in
                if newValue {
                    if controller.hasAmiVoiceDictionarySyncConsent {
                        controller.amiVoiceDictionarySyncEnabled = true
                        stepBNotice = copy.syncEnabledNotice
                    } else {
                        showSyncConsent = true
                    }
                } else {
                    controller.amiVoiceDictionarySyncEnabled = false
                    stepBNotice = copy.syncDisabledNotice
                }
            }
        )
    }

    private func postSettingsDestination(_ id: String) {
        SettingsDestination.pending = id
        NotificationCenter.default.post(name: .settingsDestinationRequested, object: id)
    }

    var body: some View {
        SettingsPageScrollView(section: .amivoice, focusRequest: focusRequest) {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AmiVoice APIキー（APPKEY）")
                                .font(.system(size: 14, weight: .medium))
                            Text("AmiVoice Cloud Platformで発行したAPPKEYを登録します。Macのキーチェーンに保存し、保存済みの値は表示しません。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SecureField("AmiVoice APIキーを入力", text: $apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .settingsControlFocus("amivoice-apikey")
                        HStack(spacing: 10) {
                            Label(controller.hasAmiVoiceKey ? "キーチェーンに登録済み" : "APIキー未登録",
                                  systemImage: controller.hasAmiVoiceKey ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("APIキーを保存") {
                                do {
                                    try controller.saveAmiVoiceKey(apiKeyDraft)
                                    apiKeyDraft = ""
                                    apiKeyNotice = "APIキーを保存しました"
                                } catch {
                                    DiagnosticLog.record("AmiVoice API key save failed: \(error.localizedDescription)")
                                    let mappedError: Error
                                    if let keyError = error as? KeychainStore.KeyError, case .security(let status) = keyError {
                                        mappedError = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                                    } else {
                                        mappedError = error
                                    }
                                    apiKeyNotice = UserFacingErrorMessage.message(for: mappedError, operation: "APIキーの保存")
                                }
                            }
                            .disabled(apiKeyDraft.isEmpty)
                            Button("APIキーを削除", role: .destructive) { requestKeyDeletion() }
                                .disabled(!controller.hasAmiVoiceKey)
                        }
                        Text("新しいキーを保存すると登録済みのキーを置き換えます。削除後にAmiVoiceを使うには再登録が必要です。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !apiKeyNotice.isEmpty {
                            Text(apiKeyNotice)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("API接続", systemImage: "key.horizontal")
                }
                .settingsTarget("amivoice-apikey")

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsRow("認識エンジン",
                                    description: "使用するAmiVoiceの認識エンジンを選びます。初期値は「日本語E2E_汎用（-a2-ja-general）」です。",
                                    icon: "waveform") {
                            Picker("認識エンジン", selection: $controller.amiVoiceEngine) {
                                ForEach(AmiVoiceEngine.allCases) { engine in
                                    Text("\(engine.label)（\(engine.rawValue)）").tag(engine)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 240)
                            .settingsControlFocus("amivoice-engine")
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("選択中のエンジン：\(controller.amiVoiceEngine.label)（\(controller.amiVoiceEngine.rawValue)）")
                                .font(.system(size: 13, weight: .medium))
                            Text(controller.amiVoiceEngine.supportsInterimPreview
                                 ? "・暫定プレビュー：対応（録音中に認識途中の文字を表示します）"
                                 : "・暫定プレビュー：非対応（バッチエンジンのため、録音終了後に確定結果を表示します）")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(controller.amiVoiceEngine.supportsWrittenOnlyBoost
                                 ? "・専門用語の補助（profileWords）：対応（E2Eエンジンは登録語句をそのまま送信します）"
                                 : "・専門用語の補助（profileWords）：非対応（ハイブリッドエンジンは読み仮名登録が必要なため送信しません）")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("各エンジンの違い")
                                .font(.system(size: 12, weight: .medium))
                            Text("・E2E系（-a2-ja-general / -a2b-ja-general）：表記のみの専門用語補助に対応。バッチ（-a2b-ja-general）は暫定プレビューを行いません。")
                            Text("・ハイブリッド系（-a-general-input / -a-general）：暫定プレビューに対応。単語ごとの読み仮名が必要なため、現在のバージョンでは専門用語を送信しません。")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                } label: {
                    Label("認識エンジン", systemImage: "cpu")
                }
                .settingsTarget("amivoice-engine")

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("E2Eエンジン（日本語E2E_汎用 / バッチ）では、「登録した用語を使う」がオンのときに、登録済みの固有名詞・専門用語および学習した語彙を profileWords としてAmiVoiceへ送信します（最大100語・4,096バイト上限）。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("ハイブリッドエンジン（音声入力_汎用 / 会話_汎用）は単語ごとに読み仮名の登録が必要なため、現在のバージョンでは専門用語リストを送信しません。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Label(controller.registeredVocabularyEnabled ? "「登録した用語を使う」は現在オンです" : "「登録した用語を使う」は現在オフです",
                                  systemImage: controller.registeredVocabularyEnabled ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("専門用語の登録を開く") { navigateToTerms() }
                        }
                        Divider()
                        // Step B: vocabulary auto-sync opt-in + management
                        // (GD-369 §3 / GD-469 01). The toggle is consent-gated.
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: autoSyncBinding) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(copy.autoSyncToggleTitle)
                                        .font(.system(size: 14, weight: .medium))
                                    Text(AmiVoiceDictionaryEngineFamily(engine: controller.amiVoiceEngine) == .hybrid
                                         ? copy.autoSyncToggleSupplementHybrid
                                         : copy.autoSyncToggleSupplementE2E)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .settingsControlFocus("amivoice-vocabulary-sync")
                            AmiVoiceSyncStatusSection(
                                controller: controller,
                                onOpenManagement: { showVocabularyManagement = true },
                                onOpenApiKey: { postSettingsDestination("amivoice-apikey") }
                            )
                            HStack(spacing: 12) {
                                Button(copy.openManagementButton) { showVocabularyManagement = true }
                                Button(copy.rollbackButton) { showSyncHistory = true }
                                    .disabled(!controller.amiVoiceDictionarySyncEnabled
                                              || controller.amiVoiceVocabularyManagement
                                                .snapshotHistory(for: controller.amiVoiceDictionaryProfileKey).count < 2)
                                Spacer()
                                Button(copy.deleteAllButton, role: .destructive) { showSyncDeleteAll = true }
                                    .controlSize(.small)
                            }
                            .settingsTarget("amivoice-vocabulary-management")
                            if !stepBNotice.isEmpty {
                                Text(stepBNotice)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .settingsTarget("amivoice-vocabulary-sync")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } label: {
                    Label("専門用語の補助", systemImage: "character.book.closed")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AmiVoiceの利用中は、録音した音声を株式会社アドバンスト・メディア（Advanced Media）のクラウドサーバーへ送信します。")
                        Text("接続先は「\(AmiVoiceWire.nologWebSocketEndpoint)」（nolog/・ログ保存なしエンドポイント）を使用します。")
                        Text("無料枠：エンジンごとに月60分（3,600秒）のVAD検出発話時間（音声が検出された発話区間）が無料です（毎月1日0:00 JSTにリセット）。")
                        Text("超過料金：無料枠を超えた分は ¥0.04125/秒（¥2.475/分、税込）です。実際の利用量・請求額はAmiVoice Cloud Platformのマイページで確認してください。")
                        Text(LocalizedStringKey(copy.privacyAddendum))
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                } label: {
                    Label("プライバシーと料金", systemImage: "lock.shield")
                }
                .settingsTarget("amivoice-privacy")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showSyncConsent) {
            AmiVoiceSyncConsentPanel(
                onAgree: {
                    controller.agreeAmiVoiceDictionarySyncConsentAndEnable()
                    stepBNotice = copy.syncEnabledNotice
                    showSyncConsent = false
                },
                onCancel: { showSyncConsent = false },
                onShowDetails: {
                    showSyncConsent = false
                    postSettingsDestination("amivoice-privacy")
                }
            )
        }
        .sheet(isPresented: $showVocabularyManagement) {
            AmiVoiceVocabularyManagementSheet(
                controller: controller,
                onOpenApiKey: { postSettingsDestination("amivoice-apikey") }
            )
        }
        .sheet(isPresented: $showSyncHistory) {
            AmiVoiceSyncHistorySheet(controller: controller) { stepBNotice = $0 }
        }
        .sheet(isPresented: $showSyncDeleteAll) {
            AmiVoiceDeleteAllSheet(controller: controller) { stepBNotice = $0 }
        }
    }
}
#endif
