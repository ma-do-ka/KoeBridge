# Build 56 UI rebuild score / 移行記録

2026-11-10. Baseline: Build 55 (`origin/main` at the start of this change). After: uncommitted Build 56 on `feat/settings-rebuild-b56`. Evidence: source audit only, on a Linux host with **no Swift toolchain**. No screenshots, recordings, VoiceOver sessions or macOS executions were produced. Screenshot/recording identifiers: **未取得・要実機確認**, for both builds. Do not interpret a source path/anchor result as measured user task success.

The Build 56 brief and its night addendum govern this report. No competitor implementation claims are used.

## Research rubric (6 × 5 = 30)

| Dimension | 1 | 2 | 3 | 4 | 5 | Evidence |
|---|---|---|---|---|---|---|
| Findability | <50% task success | 50–69% | 70–84% | 85–94% | ≥95%, all settings indexed | Fixed task list spanning every feature; measure page-path and search success separately, requiring visible target |
| Consistency | ≥8 deviations | 5–7 | 3–4 | 1–2 | 0 | Audit duplicate ownership, terminology, picker/toggle treatment, action placement |
| Captions/help | <50% complete | 50–69% | 70–84% | 85–94% | ≥95%, no misleading safety/privacy text | Applicable controls explain effect, scope, dependencies, transmission/cost and failure outcome |
| Empty/error states | <50% covered | 50–69% | 70–84% | 85–94% | All covered with actionable guidance | Seed no-key, no-history, no-results, empty lists, missing mic, denied permissions and load failures |
| Keyboard access | Core flow blocked | Several blocks | Core flows work; gaps remain | All actions work; minor focus gaps | All actions work, meaningful labels/focus, predictable search return and disclosure | Keyboard/VoiceOver recordings; screenshots alone cannot prove this |
| Visual hierarchy | Core controls clipped/unreadable | Multiple major issues | Usable with crowding | Clear with minor issues | No clipping; clear grouping, contrast, states and scrolling at all tested sizes | Matched light/dark screenshots at default/minimum sizes, long content, expanded lists and small-screen popover |


## Before / after: conservative provisional scoring

| Dimension | Before | Before evidence | After | After evidence |
|---|---:|---|---:|---|
| Findability | 3 | 21 catalog entries omit devices, warming, preview, shortcut actions and new features; Voice overload (`SettingsNavigation`, `SettingsVoicePage`). | 4 | Eight owners, expanded catalog and independently source-backed catalog→anchor test; task paths below. Visibility/user success remains 要実機確認. |
| Consistency | 2 | General duplicates engine/key/input/style; local punctuation collides with context; Help assumes toggle; Gemini scope conflicts. | 4 | Single ownership, shared rows/cards, scoped destructive wording; local operation renamed in profiles too. Mixed native control styles remain. |
| Captions/help | 3 | Wrong Apple scope and toggle-only instructions; new conditional retention needs integration. | 4 | Apple-compatible post-processing and agent exclusion, conditional retention, hold/hybrid help, separate meeting/retention scopes. Full comprehension review pending. |
| Empty/error states | 4 | Existing no-key/no-history/no-results, missing-device, denied-permission and editor empty/error guidance. | 4 | Existing action/error paths retained; learned terms offers history-learning route; list guidance preserved. Seeded runtime state checks pending. |
| Keyboard access | 2 | Search scrolling does not focus; snippets lack keyboard reorder. 要実機確認: no keyboard/VoiceOver recording. | 3 | Return/↓ dispatch search; actual controls use `@FocusState` after scroll; snippet and chain move buttons. 要実機確認: disabled controls, native picker focus, all actions and VoiceOver cannot be proven by source. |
| Visual hierarchy | 3 | Overloaded Voice and duplicate General; fixed widths risk crowding. 要実機確認: no matched screenshots. | 3 | Grouped AI cards, dedicated shortcuts/profiles, quiet popover footer and warning strip. 要実機確認: contrast, clipping, long content, minimum windows and small displays unmeasured. |
| **Total** | **17/30** | Source-based provisional baseline. | **22/30** | **26/30 target not established; keyboard and visual dimensions below 4. Do not inflate pending runtime evidence.** |

For both builds, use identical fixtures: missing/valid API key; all permissions granted/denied; no/10/100 history records with original, alternative and learning; empty and long profile/snippet/preset lists; disconnected selected microphone; long status and error messages; all activation modes. Capture light/dark at 1050×710 and 850×610, plus expanded popover on a small display. Record defect, screenshot/recording ID and source location before changing these provisional scores.

## Completed migration table

All existing key spellings, types and read/write owners remain unchanged. Model/loader implementations are unmodified; the controller gains only a read-only presentation getter for the live local backend (including its fallback), with no persistence or recognition-path changes. Rows below reproduce the research inventory; evidence labels refer to the original source audit, not line numbers in the rebuilt files. No defaults migration was added for the UI.

| Feature / persisted key(s) | New page → section | Persistence evidence |
|---|---|---|
| `engine` | 音声入力 → 認識エンジン; show actual local backend as status | VoiceController:28 |
| `microphoneInputUID`, `bluetoothMicWarm` | 音声入力 → マイク・接続準備 | device store:138, controller:38 |
| `autoPaste` | 音声入力 → 入力と安全確認 | controller:69 |
| `progressivePreviewEnabled` | 音声入力 → 録音プレビュー | controller:21 |
| `recordingShortcut`, `shortcutActivationMode`, `mouseTriggerButton` | ショートカット → 録音操作; retain retry/conflict feedback | recording key:1530, activation/mouse:371 |
| `transformShortcut`, `translateShortcut`, `fixLastShortcut` | ショートカット → 選択テキスト・直前入力 | transform/translation:90, fix:336 |
| `geminiPrewarm`, `japanese` | AI・Gemini → 接続 / 認識言語 | controller:45 |
| `transcriptionStyle`, legacy `smart` | AI・Gemini → 文字起こしスタイル; `smart` remains a compatibility mirror/fallback, not another control | write compatibility:55, restoration:481 |
| `vocabulary`, `registeredVocabularyEnabled`, `topicVocabularyEnabled`, `learnedTerms` | AI・Gemini → 辞書と学習; retain editing/deletion and history-learning route | vocabulary:384, learned terms:318 |
| `textContextCheckEnabled` | AI・Gemini → 認識後の確認 → Mac内の句読点整理; clearly label local processing | controller:402, behavior caption:203 |
| `audioRecheckEnabled`, `audioRecheckPolicy` | AI・Gemini → 認識後の確認 → 音声の再照合 | controller:405 |
| `recheckContextEnabled`, `contextAppEnabled`, `contextSelectionEnabled`, `contextSurroundingEnabled` | AI・Gemini → 再照合に送る文脈; retain subordinate values when disabled | controller:78 |
| `postProcessEnabled`, `postProcessMode` | AI・Gemini → LLM後処理; explain Apple compatibility and agent exclusion | controller:72, captions:89 |
| `translationDirection` | AI・Gemini → 翻訳; link to shortcut assignment | controller:111 |
| `transformMode`, `selectedTransformPresetID`, `transformPresets` | AI・Gemini → 選択テキストの変換・プリセットチェーン; retain names, ordered steps, selection, add/delete/reorder and instruction helpers | persistence:114, editor:64 |
| `snippets` | 音声入力 → 定型文; retain triggers/templates and DATE/TIME/CLIPBOARD helpers | persistence:364, editor:18 |
| `appProfiles` | アプリ別 → プロファイル一覧・継承と上書き | persistence:311 |
| `diagnosticsEnabled` | 履歴とデータ → 診断記録 | AppStorage:24 |
| `checkUpdatesAutomatically` | について → アップデート | update manager:25 |
| `lastSuccessfulUpdateCheckAt`, `lastAutomaticUpdateCheckAttemptAt` | について → アップデート; retain internal timestamps, display successful check | update loading:50 |
| `transcriptionOptionsVersion` | Internal migration metadata; retain existing loader, no editable control | migration:41 |
| `permissionsIntroRequestedV044` | Internal permission-onboarding marker; retain, never reset during UI rebuild | first-launch flow:304 |


### Build 54/55 additions enumerated from current source

| Exact key / payload | Type and existing owner | Destination |
|---|---|---|
| `voiceCommandsEnabled` | Bool; `VoiceController` didSet | 音声入力 → 音声コマンド |
| `voiceCommand.cancelTake` | Bool, missing defaults to true; `VoiceController.enabledVoiceCommands` | 音声入力 → 音声コマンド → 入力をキャンセルして |
| `voiceCommand.newline` | Bool, missing defaults to false; same existing setter | 音声入力 → 音声コマンド → 改行して |
| `voiceCommand.paragraph` | Bool, missing defaults to false; same existing setter | 音声入力 → 音声コマンド → 段落を変えて |
| `meetingModeEnabled` | Bool; existing controller setter requests screen-recording permission when enabled | 音声入力 → 会議モード |
| `retainAudioEnabled` | Bool; existing controller setter clears retained audio on disable | 履歴とデータ → 音声の保存 |
| `TranscriptRecord.audioAsset` | Optional Codable `AudioAsset`: `relativeFileName`, `pcmByteCount`, `recordedAt`, `expiresAt` | Same `recent-transcripts.json`, history detail; WAV stays in private `RetainedAudio` directory |
| `TranscriptRecord.audioUnavailableReason` | Optional String | Same archive and history audio status |
| `TranscriptRecord.retranscriptions` | Codable array of `Retranscription(engine, date, text)` | Same archive and history retranscription capabilities |
| `TranscriptRecord.kind` | Optional String (meeting records included) | Same archive; meeting history remains available |

There are no additional Build 55 UserDefaults keys in `MeetingSession`, `RetainedAudioStore` or the meeting settings. Retention remains seven days / 250 MB with existing PCM/WAV limits. These rules are descriptions, not new persistence fields.

### Schema / non-defaults preservation

| Setting or capability | Destination / preservation rule |
|---|---|
| API key | AI・Gemini → API接続. Preserve Keychain service `dev.koebridge.gemini-api` and account `personal-key`; retain save/replace/delete feedback. KeychainStore:5 |
| Launch at login | 一般 → 起動. Continue using actual `SMAppService` state, registration and approval handling; do not introduce a fictitious defaults flag. LoginItemManager:8 |
| Permissions | 権限 → existing three rows, refresh and guide; add explicit visibility for applicable Speech/input-monitoring requirements. Existing guidance is scattered across General and Voice. permission rows, Speech guidance, input monitoring |
| Transcript archive and all history actions | 履歴とデータ → 文字起こし履歴; preserve file-backed records, review alternatives, learning, copy and deletion. archive presentation, history actions |
| Usage charts, bucket selector, deletion | 履歴とデータ → 利用統計; retain separate deletion scope. UsageMonitorView:142, deletion:264 |
| Timing/readiness/help/update information | 一般 → readiness/timings; について → help, version/license/repository and full update center. General, support |


`appProfiles` remains encoded Data containing `id`, `bundleIdentifier`, `displayName`, `isEnabled`, optional `engine`, optional `style`, `additionalVocabulary`, optional `registeredVocabularyEnabled`, `topicVocabularyEnabled`, `textContextCheckEnabled`, `audioRecheckEnabled`, `audioRecheckAlways`, `postProcessEnabled`, `postProcessMode`. Every optional keeps **nil = inherit**, including false-vs-nil distinctions.

`snippets`, `transformPresets`, `learnedTerms` Codable definitions and their JSON Data paths remain unchanged. `smart` is still the controller's readable-style compatibility mirror/fallback; there is no smart checkbox. `TranscriptionOptions.load` retains its versioned migration and missing-vs-false handling. `permissionsIntroRequestedV044` is never reset. Keychain service/account remain `dev.koebridge.gemini-api` / `personal-key`. Login continues through `SMAppService`, not a preference flag.

Engine/style/language/vocabulary bindings still reach warming side effects; Bluetooth reaches the keeper; activation/mouse/transform changes reach input configuration. All four shortcut selections call transactional setters and retain conflict/retry feedback. Diagnostics consent still synchronously calls `DiagnosticLog.preferenceDidChange`. Log/key deletion remains in parent alerts. API draft/notices and preset step UUID state live at settings-window scope; pages are mounted only when selected.

## Fixed findability task list: AFTER paths

One task per indexed feature/control area. `Source path OK` means routing and a concrete section anchor exist; **visible target and first-control focus are 要実機確認**, including disabled/dependent controls. Search results keep whitespace AND matching. Profile aliases intentionally exclude 「モード」. The table is fixed for follow-up runtime evaluation of both builds.

| Task | Page path / source result | Search path / source result |
|---|---|---|
| 基本設定・準備状況 | 一般 → `general` / Source path OK | 「基本設定・準備状況」 → `general` / Source path OK（AND） |
| アプリ別プロファイル | アプリ別 → `app-profiles` / Source path OK | 「アプリ別プロファイル」 → `app-profiles` / Source path OK（AND） |
| 文字起こしの方法 | 音声入力 → `engine` / Source path OK | 「文字起こしの方法」 → `engine` / Source path OK（AND） |
| 録音の開始・終了キー | ショートカット → `shortcut` / Source path OK | 「録音の開始・終了キー」 → `shortcut` / Source path OK（AND） |
| 認識した文章を自動入力する | 音声入力 → `autopaste` / Source path OK | 「認識した文章を自動入力する」 → `autopaste` / Source path OK（AND） |
| Gemini APIキー | AI・Gemini → `apikey` / Source path OK | 「Gemini APIキー」 → `apikey` / Source path OK（AND） |
| 日本語での認識を優先する | AI・Gemini → `japanese` / Source path OK | 「日本語での認識を優先する」 → `japanese` / Source path OK（AND） |
| 文字起こしスタイル | AI・Gemini → `smart` / Source path OK | 「文字起こしスタイル」 → `smart` / Source path OK（AND） |
| 専門用語の補助 | AI・Gemini → `vocabulary-assistance` / Source path OK | 「専門用語の補助」 → `vocabulary-assistance` / Source path OK（AND） |
| 固有名詞・専門用語を登録 | AI・Gemini → `words` / Source path OK | 「固有名詞・専門用語を登録」 → `words` / Source path OK（AND） |
| Mac内の句読点整理 | AI・Gemini → `context-check` / Source path OK | 「Mac内の句読点整理」 → `context-check` / Source path OK（AND） |
| 認識エンジンの利用回数 | 履歴とデータ → `usage` / Source path OK | 「認識エンジンの利用回数」 → `usage` / Source path OK（AND） |
| Gemini APIのトークン使用量 | 履歴とデータ → `token` / Source path OK | 「Gemini APIのトークン使用量」 → `token` / Source path OK（AND） |
| 文字起こし履歴 | 履歴とデータ → `history` / Source path OK | 「文字起こし履歴」 → `history` / Source path OK（AND） |
| 問題調査用の記録を残す | 履歴とデータ → `logging` / Source path OK | 「問題調査用の記録を残す」 → `logging` / Source path OK（AND） |
| 入力先へのアクセスを許可 | 権限 → `accessibility` / Source path OK | 「入力先へのアクセスを許可」 → `accessibility` / Source path OK（AND） |
| 文字の入力操作を許可 | 権限 → `post` / Source path OK | 「文字の入力操作を許可」 → `post` / Source path OK（AND） |
| マイクの使用を許可 | 権限 → `microphone` / Source path OK | 「マイクの使用を許可」 → `microphone` / Source path OK（AND） |
| 使い方とトラブル対処 | について → `help` / Source path OK | 「使い方とトラブル対処」 → `help` / Source path OK（AND） |
| KoeBridgeについて | について → `about` / Source path OK | 「KoeBridgeについて」 → `about` / Source path OK（AND） |
| アップデート | について → `updates` / Source path OK | 「アップデート」 → `updates` / Source path OK（AND） |
| ログイン時に自動起動 | 一般 → `launchAtLogin` / Source path OK | 「ログイン時に自動起動」 → `launchAtLogin` / Source path OK（AND） |
| 直近の処理時間 | 一般 → `timings` / Source path OK | 「直近の処理時間」 → `timings` / Source path OK（AND） |
| マイクを選択 | 音声入力 → `microphone-device` / Source path OK | 「マイクを選択」 → `microphone-device` / Source path OK（AND） |
| Bluetoothマイクの接続準備 | 音声入力 → `bluetooth-warm` / Source path OK | 「Bluetoothマイクの接続準備」 → `bluetooth-warm` / Source path OK（AND） |
| 録音プレビュー | 音声入力 → `preview` / Source path OK | 「録音プレビュー」 → `preview` / Source path OK（AND） |
| 定型文・スニペット | 音声入力 → `snippets` / Source path OK | 「定型文・スニペット」 → `snippets` / Source path OK（AND） |
| 音声コマンド | 音声入力 → `voice-commands` / Source path OK | 「音声コマンド」 → `voice-commands` / Source path OK（AND） |
| 会議モード | 音声入力 → `meeting` / Source path OK | 「会議モード」 → `meeting` / Source path OK（AND） |
| 録音キーの動作 | ショートカット → `activation` / Source path OK | 「録音キーの動作」 → `activation` / Source path OK（AND） |
| マウスボタン | ショートカット → `mouse` / Source path OK | 「マウスボタン」 → `mouse` / Source path OK（AND） |
| 選択テキストを変換 | ショートカット → `transform-shortcut` / Source path OK | 「選択テキストを変換」 → `transform-shortcut` / Source path OK（AND） |
| 選択テキストを翻訳 | ショートカット → `translate-shortcut` / Source path OK | 「選択テキストを翻訳」 → `translate-shortcut` / Source path OK（AND） |
| 直前の入力を修正 | ショートカット → `fix-shortcut` / Source path OK | 「直前の入力を修正」 → `fix-shortcut` / Source path OK（AND） |
| 録音前に接続を準備する | AI・Gemini → `prewarm` / Source path OK | 「録音前に接続を準備する」 → `prewarm` / Source path OK（AND） |
| LLM後処理 | AI・Gemini → `post-processing` / Source path OK | 「LLM後処理」 → `post-processing` / Source path OK（AND） |
| 後処理モード | AI・Gemini → `post-mode` / Source path OK | 「後処理モード」 → `post-mode` / Source path OK（AND） |
| 学習した語彙 | AI・Gemini → `learned-terms` / Source path OK | 「学習した語彙」 → `learned-terms` / Source path OK（AND） |
| 音声の再照合とタイミング | AI・Gemini → `audio-recheck` / Source path OK | 「音声の再照合とタイミング」 → `audio-recheck` / Source path OK（AND） |
| 再照合に送る文脈 | AI・Gemini → `context` / Source path OK | 「再照合に送る文脈」 → `context` / Source path OK（AND） |
| 文脈のアプリ名 | AI・Gemini → `context-app` / Source path OK | 「文脈のアプリ名」 → `context-app` / Source path OK（AND） |
| 文脈の選択テキスト | AI・Gemini → `context-selection` / Source path OK | 「文脈の選択テキスト」 → `context-selection` / Source path OK（AND） |
| 文脈の周辺テキスト | AI・Gemini → `context-surrounding` / Source path OK | 「文脈の周辺テキスト」 → `context-surrounding` / Source path OK（AND） |
| 翻訳の方向 | AI・Gemini → `translation` / Source path OK | 「翻訳の方向」 → `translation` / Source path OK（AND） |
| 選択テキストの変換・プリセットチェーン | AI・Gemini → `presets` / Source path OK | 「選択テキストの変換・プリセットチェーン」 → `presets` / Source path OK（AND） |
| 音声の保存と削除 | 履歴とデータ → `retention` / Source path OK | 「音声の保存と削除」 → `retention` / Source path OK（AND） |
| 音声認識と入力監視の案内 | 権限 → `permission-guide` / Source path OK | 「音声認識と入力監視の案内」 → `permission-guide` / Source path OK（AND） |
| 登録した用語を使う | AI・Gemini → `registered-vocabulary` / Source path OK | 「登録した用語を使う」 → `registered-vocabulary` / Source path OK（AND） |
| 開発・ITの用語を使う | AI・Gemini → `topic-vocabulary` / Source path OK | 「開発・ITの用語を使う」 → `topic-vocabulary` / Source path OK（AND） |
| 音声と照合するタイミング | AI・Gemini → `audio-policy` / Source path OK | 「音声と照合するタイミング」 → `audio-policy` / Source path OK（AND） |
| 変換キーの動作 | AI・Gemini → `transform-mode` / Source path OK | 「変換キーの動作」 → `transform-mode` / Source path OK（AND） |
| 実行するプリセット | AI・Gemini → `selected-preset` / Source path OK | 「実行するプリセット」 → `selected-preset` / Source path OK（AND） |

History stays a launcher to the existing full `HistoryView`: search, selected detail, original/alternative, copy, single delete, confirmed delete-all and correction-learning remain. Usage has its own chart scale and deletion scope within 履歴とデータ. The four deletion confirmations identify scope explicitly: history, statistics, diagnostic log and retained WAVs; each uses 「…をすべて削除しますか？」 / 削除 / キャンセル and states other data is unchanged.

## Popover mechanism and post-apply acceptance checklist — all 要実機確認

`Main.swift` keeps transient NSPopover and does not activate the application on show. `FirstMouseHostingView.acceptsFirstMouse` accepts the initial mouse event. Engine selection is two explicit SwiftUI buttons, rather than an AppKit segmented picker or switch. Content geometry updates the popover size when history/status expands; initial fitting-size measurement is retained. Hosting overrides alone do not prove per-control behavior.

While shown only: global mouse-down monitor closes for outside coordinates, including App X → same App X (no activation notification); local mouse/key monitor handles own-app windows and Esc; global key monitor handles Esc while another app stays key; workspace observer handles activating another application. All monitors and observer are removed on popover close. Global key delivery depends on macOS monitoring permissions; verify with granted and denied permissions. No unconditional app activation is added. The 100 ms capture delay is retained, including the meeting control.

- [ ] Open from App X; first click **音声入力を開始** once starts recording after close; intended App X field is captured and receives text.
- [ ] Repeat independently for **音声入力を確定**, **録音を破棄**, partial-transform copy, meeting start/stop and history record copy.
- [ ] Open anew for each **Gemini** and **Apple** engine button; first click changes engine once without activating KoeBridge.
- [ ] Open anew; first click **history disclosure** expands/collapses; first click a recent record copies; newest 10 and all-history launcher still work.
- [ ] Open anew; first click usage card opens 履歴とデータ; permission strip opens 権限; Settings/Updates/Quit each responds once. No duplicate permission action.
- [ ] Open → Esc closes while App X remains key (also test with monitoring permissions denied); no stale key observer after close.
- [ ] Open → switch to App Y closes; open from App X → **click back into the SAME App X** closes; repeat right/other mouse-down outside.
- [ ] Dictation target stays App X after all popover interactions; no focus stealing. Verify left-click popover and right/Control-click menu and the 200 ms reopening guard.
- [ ] Permission strip remains when all granted; warning remains visible when missing. Seven-day chart stays visible, including empty state; bars readable at small display size.
- [ ] Long statuses / expanded recent-history fit at small display height; no control clipping; only history scrolls in the popover.

## Settings keyboard / visual acceptance — 要実機確認

2026-11-10: Source-level keyboard-access fixes remove the duplicate Bluetooth focus ID and add target-named accessibility labels to snippet, preset/step, and app-profile actions/editors; runtime keyboard/VoiceOver proof remains pending and scores are unchanged.

- [ ] Search Return and ↓ choose first result; selecting any result repeatedly scrolls then highlights, then focuses the first interactive control. Verify every catalog row, disabled dependencies and permission rows already granted. Back/forward remains bounded and clears stale focus requests.
- [ ] Tab/Shift-Tab and VoiceOver reach every action; snippets and preset/chain 上へ/下へ controls reorder with stable identities. Edit a step, navigate away/back, insert helper and confirm same edited step; API draft and notices survive navigation.
- [ ] Compare matched light/dark screenshots with fixtures above; default/minimum sizes, long labels, empty/error states, conditional controls and full scroll reachability.
- [ ] Launch all-history window and exercise every preserved capability; separately confirm each destructive scope and cancellation.

## Validation record

Swift Core/SelfTest/macOS build: **not run — `swift: command not found`** on this host. Added `SettingsPersistenceTests` exercises isolated defaults, navigation, optional-nil AppProfile, snippet/preset Data round trips, Build 54/55 values, `smart`, and missing-vs-false options migration. Updated navigation tests cover the new IA and catalog→real-source-anchor integrity. These tests are authored, not claimed passing.

Source preservation review: recognition/delivery/gates/acoustic policies and serialized model implementations have no behavioral diff; `VoiceController.localBackendStatus` is a read-only presentation getter. Public-release allowlist audit: PASS (300 approved files, 6 pinned artworks). `git diff --check`: PASS. Independent Python source-anchor check: PASS (52 catalog entries); this is not execution of the authored Swift tests. run the Swift/macOS checks before accepting the build. No commit or deployment performed.


## Handoff: changed files

The implementation maps ownership to the exact eight pages above. `SettingsShortcutsPage` is new; all other pages reuse existing editors/actions. `VoiceController` changes only by a read-only backend-status getter; recognition, delivery, review and acoustic thresholds remain unchanged.

- `Sources/KoeBridge/HistoryView.swift`
- `Sources/KoeBridge/Main.swift`
- `Sources/KoeBridge/MeetingAndRetentionSettings.swift`
- `Sources/KoeBridge/MicrophoneSettingsRow.swift`
- `Sources/KoeBridge/SettingsAppProfilesPage.swift`
- `Sources/KoeBridge/SettingsAppearance.swift`
- `Sources/KoeBridge/SettingsControls.swift`
- `Sources/KoeBridge/SettingsGeminiPage.swift`
- `Sources/KoeBridge/SettingsGeneralPage.swift`
- `Sources/KoeBridge/SettingsInputControls.swift`
- `Sources/KoeBridge/SettingsPermissionsPage.swift`
- `Sources/KoeBridge/SettingsPrivacyPage.swift`
- `Sources/KoeBridge/SettingsShortcutsPage.swift`
- `Sources/KoeBridge/SettingsSnippetsPage.swift`
- `Sources/KoeBridge/SettingsSupportPages.swift`
- `Sources/KoeBridge/SettingsTransformPresets.swift`
- `Sources/KoeBridge/SettingsView.swift`
- `Sources/KoeBridge/SettingsVoicePage.swift`
- `Sources/KoeBridge/StatusPopoverView.swift`
- `Sources/KoeBridge/UsageMonitorView.swift`
- `Sources/KoeBridge/VoiceController.swift`
- `Sources/KoeBridgeCore/SettingsNavigation.swift`
- `Tests/KoeBridgeCoreTests/SettingsNavigationTests.swift`
- `Tests/KoeBridgeCoreTests/SettingsPersistenceTests.swift`
- `docs/ui-rebuild-score.md`
- `scripts/Info.plist`
- `scripts/public_files.txt`

Final available checks: public-release audit PASS; diff whitespace check PASS; 52-entry catalog/owning-source-anchor check PASS; transactional-setter and unchanged controller/schema/acoustic-source checks PASS. `swift test` and `swift run KoeBridgeSelfTest` both failed to launch because Swift is unavailable. No test success or macOS build success is claimed. All runtime acceptance items above remain 要実機確認.
