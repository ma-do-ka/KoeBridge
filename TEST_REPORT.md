# KoeBridge v1.1.0 — 連続入力・独立した認識補助の検証範囲（2026-11-06）

## 公開前の自動検証

対象の同一コミットで、次の検証が成功した場合にのみ開発版アプリを公開します。実際の実行結果は [macOS CI と公開ワークフロー](https://github.com/ma-do-ka/KoeBridge/actions) に記録されます。

アプリの回帰検証では、[Mac CI（コミット `0bbb884`）](https://github.com/ma-do-ka/KoeBridge/actions/runs/42230091540) にて **Swift Testing 167件、portable self-test 133ケース・6,350アサーション、Python 7件が失敗0件**。通常の Release ビルドも成功しました。この実行では複数アーキテクチャを一括指定する Xcode ビルド経路が失敗したため、配布用の生成方式を個別ビルドと `lipo` に変更し、公開前に再検証します。

- 公開ファイルの許可一覧・秘密情報パターン・固定アイコンの監査。
- Python 利用量・追加音声照合の概算テスト。
- Swift Testing と portable self-test。連続入力の位置引継ぎ、選択範囲置換、UTF-16 境界、部分送信、同一欄の未確認入力、変更された入力先の拒否を含む。
- 手動 `activityEnd` と先行音声キューの順序、送信中の早い完了通知、未完了・古い通知・失敗時の確定拒否、同じ発話の反復保持。
- 独立チェックの全組合せ、旧設定の移行、100語上限、JSON 化で用語を失わない eager な辞書構築、音声照合の要求・応答・時間制限。
- 引用・コード・日本語パスの保護、限定した句読点補正、文章チェック OFF 時の原文保持、要確認履歴とメニュープレビュー。
- Universal（arm64 / x86_64）ビルド、Info.plist、アイコン、同梱 LICENSE、アドホック署名の整合性。
- 公開 ZIP の再展開、署名・両アーキテクチャ・LICENSE・SHA-256 の再確認。タグは検証したコミットに固定。

## 実機未確認の範囲

マイクによる連続録音、Gemini 実サービスとの接続、Apple の音声認識、入力先アプリの Accessibility 応答、手動カーソル移動との競合、設定画面の見た目、macOS の起動・権限確認はユーザーの Mac で未検証です。モデルの句読点品質や全アプリへの入力成功を自動テストの結果から保証しません。反映確認できない入力先では、後続文が復旧履歴に残る場合があります。

開発版は Developer ID 署名・Apple 公証を受けていません。正式な公証済み自動更新パッケージとして扱いません。

---

# KoeBridge v1.0.1f — メニューバー直近10件・クリック全文コピー（2026-11-06）

- 現行AppKitの「認識履歴（直近10件）…」を、ホバーで開くネイティブサブメニューに一部置換。
- 保存済み履歴を新しい順に最大10件表示。日付・本文冒頭・途中認識の識別子を表示する。メニューが表示されるたびに履歴のスナップショットを更新。
- 項目クリックでUUIDにより現在の履歴を検索し、保存済み本文を改行も含めてクリップボードへコピー。ホバー・メニュー再表示ではクリップボードに触れない。勝手な自動入力・録音・権限要求はなし。
- コピー操作後、焦点を奪わない浮動パネルで「コピーしました / ⌘Vで貼り付けできます」を約2.2秒表示。失敗なら成功と誤表示せずエラーを表示。
- 現行の「履歴をすべて表示…」から従来の認識履歴ウィンドウを開ける。履歴ファイル、録音、Gemini API、設定データには変更なし。
- 文字数・Unicodeの安全なプレビュー、省略記号、認識途中表示、10件上限、UUIDの整合性をSwift Testingとportable self-testで追加検証。
- macOS CIのSwiftビルド/署名・単体テスト成功後に公開。GUIホバーと非アクティブパネルのE2Eは実機確認が必要。

---

# KoeBridge v1.0.1e — 更新メニューの初回遷移・再移動修正（2026-11-05）

- メニューから設定ウィンドウを初めて生成する際、SwiftUIの購読開始前に発行された画面移動要求を、ViewのonAppearでも回収する。
- @PublishedのwillSet通知で変更直後の値を読むことを避け、MainActor上のTaskで蓄積済み要求を処理する。
- 情報画面を開くだけで終わらせず、実在する設定検索の「updates」項目を使って更新欄に移動。繰り返し選択してもスクロールを再実行する。
- 設定・Gemini通信・録音・保存履歴・OS権限・ソース更新の安全確認は変更しない。
- 静的テストで「updates」移動先の重複・変更を検知。CIのSwift Testing、portable自己テスト、macOSビルド・署名・公開監査で検証する。実機のSwiftUIスクロールと初回ウィンドウ生成のE2Eは未確認。

---

# KoeBridge v1.0.1d — 更新センターと一般画面改善（2026-11-05）

- GitHub Stable Releasesの確認に対応。URL/タグ・バージョンの厳格な検証を行い、オフライン/403/不正データを「最新版」と誤表示しない。自動確認は成功後24時間以上の間隔。
- メニューバーに「アップデートを確認…」を追加し、情報画面の更新セクションを開く。新しいリリースがある場合は安全なソース更新手順を案内。
- 現行のリリースはソースのみで、署名済み・公証済みバイナリの配布なし。自動ダウンロード・インストールは無効と表示。機能していないスイッチをONにしない。
- 「一般」をリンク中心から直接編集できる基本操作・許可状態・トラブル解決・更新状況の画面に改修。既存値と権限は変更しない。
- Swift Testing/portableでリリースタグ順序・悪意あるURL・ドラフト/プレリリース・自動確認間隔を検証。Bash更新スクリプト構文もCIで検証。
- 更新を行うユーザーのMacのSwift Toolchain・署名証明書・ネットワーク・ユーザー権限はCIでは保証できない。実機E2Eと画面表示は未確認。

---

# KoeBridge v1.0.1c — ログイン項目登録の復旧（2026-11-05）

- 実装済みの「ログイン時に自動起動」で `.notFound` に遭遇した場合、これまでトグルが操作不能だった。ユーザーがONを選ぶと登録を試みるよう修正。
- `SMAppService.mainApp.register()` の登録後はmacOSの実状態（enabled/requiresApproval/notRegistered/notFound）を読み直す。承認待ちならシステム設定を開き、手動での最終承認を促す。
- 登録未確認なら手動追加の案内・Finderで現行アプリを表示。失敗を成功と誤表示しない。ログイン時の無断自動登録は行わない。
- Swift Testingとポータブル自己テストで`.notFound` からの登録試行、承認待ち、解除、未知状態を検証。
- 実際のログイン項目への追加・OS承認・再ログイン後の起動はmacOS実機でしか確認できない。GitHub CIのPASSはOS実機承認の成功を意味しない。
- macOSバージョン `1.0.1` / リリース表示 `1.0.1c` / Build `22`。既存のv1.0.1/v1.0.1bタグは維持。

---

# KoeBridge v1.0.1b — AIエージェント指示スタイル（2026-11-05）

- 3つの文字起こしスタイル（逐語、読みやすく、AIエージェント指示）を導入。元のSMARTスイッチ設定値を移行し、未選択のユーザーの従来動作を維持。
- Gemini LiveのVERBATIM/SMART以外のモード・未定義のsystemInstructionを送信しない。新規AI呼び出しなし。
- 補助辞書は利用者の登録語を優先。合計100語まで。技術用語の認識は偏りを促すだけで正確性保証なし。
- 文字起こし結果の段落区切りで原文の文字を削除・置換しない。自動入力時の改行安全処理を維持。
- macOSログイン時の自動起動をSMAppServiceで登録・解除し、OSの承認待ちを表示する。
- CIでは新モードの旧設定移行、APIペイロード、技術用語・コマンド保持、改行による誤送信防止を検証。
- 実機マイク・Gemini実通信・ログイン項目許可、全アプリの文字受理はCIで保証しない。別途ユーザー実機確認が必要。

---

# KoeBridge v1.0.1 — mainブランチの安全性リファクタリング（2026-11-05）

- **構造整理:** `Windows.swift` から設定画面8ページを `SettingsView.swift`、文字起こし表示を `PreviewView.swift`、履歴画面を `HistoryView.swift` に抽出。さらに `VoiceController.swift` から録音単位の状態 `DictationTake.swift` を分離。設定値、Keychain、表示内容、OS利用許可の変更なし。
- **連続録音の競合修正:** マイク停止時のPCM変換・後片付けを専用バックグラウンドキューで完全に終わらせてから次のマイク開始を許可。古い停止処理が新しい録音のconverterやcallbackを消す危険を解消する。
- **短い発話の保護:** 0.70秒以内の入力でも、音量のピークが検出された場合は「音声入力なし」とみなさない。音声データ不足なら従来の明示的なエラー処理に回す。
- **履歴の情報欠落修正:** Geminiの確定済み先頭部分に未確定の続きがあるとき、後半も「途中結果」として復旧履歴に保存。未確定内容を自動入力する仕様には変更しない。
- **回帰試験強化:** macOS CIでSwift Testingに加えてポータブル `KoeBridgeSelfTest` を毎回実行。上述の短い発話と途中結果の復旧には両テストのケースを追加。
- **制約:** CIのSwiftコンパイル／署名／単体テストが成功しても、Mac実機の音声デバイス切替、特殊な連打タイミング、Gemini通信、入力先アプリの挙動は実機E2E検証が必要。CIでは無検証の領域をPASSと扱わない。
- **リリース:** v1.0.1 GitHub Releaseタグは固定のままとし、このリファクタリングはmain更新として扱う（新しい正式配布版を誤って作らない）。

---

# KoeBridge v1.0.1 — release verification scope

- ソース変更：連打による超短時間・ほぼ無音の録音を中立の「音声入力なし」で早期終了。表示は約330msで消える。
- 真の音声結果、長い録音、音声チャンクの欠落、認識エラーは通常の結果・復旧処理を維持。
- Swift Testing と `KoeBridgeSelfTest` に、短い無音・短い発話・音声欠落・古い表示の上書き防止テストを追加。
- CI：`.github/workflows/mac-ci.yml` でmacOS Swiftテスト、Releaseビルド、署名、アイコン検証。
- GitHub Release専用CI：`.github/workflows/release-v1.0.1.yml` でリリース対象の同一コミットを再検証してからタグとReleaseを作成。
- Mac実機のマイク入力、音声認識APIの接続、全アプリへの文字入力、連打タイミングのE2E結果はCIでは保証できない。
- 配布物はGitHubのソースアーカイブ。Apple Developer ID署名・公証済みのインストーラーはありません。アドホック署名の検証ビルドを正式配布バイナリとして扱いません。
- 実際のワークフロー結果はGitHub Actionsで確認し、未実行の検証をPASSとみなしません。

---

# KoeBridge v1.0.0 — validation report

- 対象：2026-11-04 の `KoeBridge_source_v0.4.4.zip` に対する変更。
- `swift run -c release KoeBridgeSelfTest`：**91ケース、6048アサーション、失敗0**。
- `swift test --parallel`：**82テスト、16スイート、失敗0**。
- `swift build -c release --product KoeBridge`：Linuxで成功。macOS専用コードは含まず。
- `swiftc -frontend -parse`：変更したmacOSファイル5つの構文パース成功。AppKit型チェックではない。
- 新規：実ファイルの診断ログローテーション（各192KiB上限）・ファイル0600・手動削除・シンボリックリンク拒否のテストがPASS。
- ソース更新パッチ：基準ハッシュ一致のみ適用、更新対象のバックアップ、異なるソースを上書きしない。
- 未完了：macOSでのビルド／署名／実際の入力イベント／音声認識／新設定画面の表示。

---

## 旧版のテスト履歴

# KoeBridge v0.4.1 — verification report

## Completed on Linux (NOT macOS)

- `swift run -c release KoeBridgeSelfTest`: 79 cases / 6008 assertions / 0 failures.
- `swift test`: 70 tests / 14 suites / 0 failures.
- macOS Swift source was syntax-parsed via `swiftc -frontend -parse`; this does NOT type-check macOS frameworks.
- Safe upgrade patch: matching old source install, repeat application, mismatch refusal, backup/rollback,
  executable-mode correction, ZIP integrity, complete extracted source equality.

## Implementation changes

- First-run app permission guide prompts for microphone and accessibility consent.
- Permission states read from current process and from microphone authorization status.
- Direct text insertion supports AXSelectedText when the AX attribute is writable and safe,
  otherwise Unicode keyboard events. No automatic clipboard paste; no fallthrough after uncertain AX failure.
- Records a code for capture failure, without logging voice or editor content.
- Command+W closes app windows, leaving menu bar app running; Command+Q quits when app window active.

## NOT VERIFIED / Mac-only tests required

- Building of the actual AppKit/AVFoundation/CoreGraphics executable on macOS.
- `AXUIElementIsAttributeSettable` / `AXUIElementSetAttributeValue` behavior in actual TextEdit,
  Chrome, ChatGPT, VS Code and non-AX editors. Delivery can fail even with access allowed.
- Mac-specific keyboard monitor for Command+W / Command+Q and focus on return from System Settings.
- Native microphone and accessibility permission prompts on macOS 28 (end-user observed environment).
- App code signing / TCC trust after rebuilding with ad-hoc signature.

**Important:** no automated API is permitted to toggle Privacy permissions without user consent;
this implementation only invokes official permission request APIs.
