# KoeBridge v1.0.0 — release notes / 2026-11-04

## この版で確定した変更

現在のソースは、ユーザー提供の最新 `KoeBridge_source_v0.4.4.zip` を基準に変更。別の公開 GitHub リポジトリへは変更していません。

| 実在ファイル・位置 | 区分 | 従来の実装 → v1.0.0 |
|---|---|---|
| `Sources/KoeBridge/Windows.swift` → `SettingsView` | **既存ビュー全文置換** | 縦長1ページの `Form` を、音声入力／Gemini／履歴・診断／権限の4ページに分割。既存のキー・エンジン・辞書・履歴・権限導線を維持。 |
| `Sources/KoeBridge/Windows.swift` → `AppWindows.showSettings` | **一部置換** | 固定540×665pt → 710×560pt・サイズ変更可・最小690×520pt。 |
| `Sources/KoeBridge/Main.swift` → `menuNeedsUpdate` | **一部削除** | 操作不能な `status`、自動入力権限、PostEvent許可、ショートカットの4行を削除。ユーザー操作のある項目は保持。 |
| `Sources/KoeBridge/Diagnostics.swift` → `DiagnosticLog` | **全文置換** | 旧・毎回ファイル全体を読み込んで書き戻す処理 → 通常OFF・ユーザーON時だけ追記する小型アダプタ。ログ内に音声本文/APIキーを直接記録しない従来方針を維持。 |
| `Sources/KoeBridgeCore/DiagnosticLogPolicy.swift` | **新規追加** | ON/OFF初期値、1行320B上限、ファイル192KiB上限、2世代の容量ポリシー。 |
| `Sources/KoeBridgeCore/DiagnosticFileStore.swift` | **新規追加** | 追記、古い1世代へのローテーション、0600権限、シンボリックリンクへの追記拒否、ユーザーによる削除。 |
| `Sources/KoeBridge/Windows.swift` → `SettingsView.privacyPage` | **新規追加** | 実在する設定画面の「履歴・診断」タブに「診断ログを保存する」チェックボックスを追加（初期OFF）。「既存ログを削除」は確認ダイアログ付き。 |
| `Sources/KoeBridge/TextInsertion.swift` → `deliver` | **一部置換** | 文字入力後のAXValue観測は診断ON時のみ。通常は従来のフォーカス安全確認／Unicode直接入力／履歴保存を維持。 |
| `Sources/KoeBridge/Main.swift` → `applicationDidFinishLaunching` | **一部追加** | システムスリープ・ユーザー切替・復帰時、保留中の古い文字起こしの自動入力を抑止。 |
| `Sources/KoeBridge/VoiceController.swift` → `DictationTake`／`interruptForSystemEvent`／`deliverOrderedResults` | **一部追加・置換** | システム中断の全保留セッションを、自動入力せず履歴保存へ回す。新しい権限取得や設定の変更なし。 |
| `Sources/KoeBridgeCore/RecentTranscriptArchive.swift` → `Delivery.blockedFocus.label` | **ラベル一部置換** | 「入力先変更」だけでなくシステム中断も説明。**保存形式・enum rawValueは変更なし**（旧履歴読み出し互換）。 |
| `Sources/KoeBridgeSelfTest/DiagnosticLogPolicyTests.swift` / `Tests/KoeBridgeCoreTests/DiagnosticLogPolicyTests.swift` | **新規追加** | 初期OFF・イベント無害化・容量・実書き込み・削除・パーミッション・シンボリックリンク・履歴データ互換テスト。 |
| `Sources/KoeBridgeSelfTest/Runner.swift` | **一部追加** | 上記ポータブル検証を6件追加。 |
| `scripts/Info.plist` | **一部置換** | CFBundleShortVersionString `0.4.4` → `1.0.0`。CFBundleVersion `16` → `17`。Bundle ID `dev.koebridge.app` は変更なし。 |
| その他の音声認識エンジン、マイク、署名スクリプト、ホットキー登録、履歴JSON | **変更なし** | Gemini/Appleのモデル選択・APIキー・辞書・ショートカット設定・録音パネル・直近10件の保持を維持。 |

## 既存設定と表示の扱い

- `UserDefaults` にある `engine`, `recordingShortcut`, `smart`, `japanese`, `autoPaste`, `vocabulary` は読み込み方法やキー名を変更しません。
- `diagnosticsEnabled` のみ新規設定キー。未設定なら **OFF**。ON/OFFは操作後すぐに反映されます。
- `~/Library/Logs/KoeBridge.log` は以前の版で作られたものを含め、**OFFにしても自動削除しません**。「履歴・診断」→「既存ログを削除」で古いログも削除できます。
- ログON時、`KoeBridge.log` と `KoeBridge.log.1` がそれぞれ最大192KiB（通常時、外部で改ざんされていない状態）、計およそ384KiB。192KiBを超えていた従来ログは次回書き込み時に切り替えます。
- 正常動作中の文章・認識履歴はこれまでどおり保存します。ログをOFFにしても音声入力はOFFになりません。
- 実装対象はネイティブmacOSの `SettingsView` であり、別のWebページ、X/Note、システム設定等の入力項目を変更するものではありません。

## 実行済みテスト / 残る制限

- Linux/Swift 6 `swift run -c release KoeBridgeSelfTest`：91ケース、6048アサーション、失敗0。
- Linux/Swift 6 `swift test --parallel`：82テスト、16スイート、失敗0。
- Linux/Swift 6 `swift build -c release --product KoeBridge`：成功。ただしmacOS UIブロックはLinuxでは除外。
- `swiftc -frontend -parse` を主な変更macOSファイルへ実施：構文上成功。
- この環境にはmacOS/AppKit/実マイクがないため、**Mac実機のコンパイル、設定画面レンダリング、F8/右Command、マイク、TCC/署名、Geminiの実通信、ブラウザ入力の受理は未確認**。完全な実機品質保証を意味しません。
- `scripts/verify_and_build.sh`（Mac専用）で `swift test`、ポータブルテスト、macOSビルド、コード署名を実行してください。証明書不明時にアドホックへ無断切り替えしません。

## 安全な更新

`KoeBridge_upgrade_v0.4.4_to_v1.0.0.zip` は、**v0.4.4の正規ソースのみ**を対象にする厳格な差分パッケージです。元ファイルのハッシュを全照合し、編集済みファイルは上書きしません。差分適用前に対象ファイルのバックアップを作成します。MacでKoeBridgeが実行中なら更新を拒否します。

```bash
# 1. KoeBridgeをメニューバーから終了
unzip -q ~/Downloads/KoeBridge_upgrade_v0.4.4_to_v1.0.0.zip -d ~/Downloads/KoeBridge_v100_release
python3 ~/Downloads/KoeBridge_v100_release/KoeBridge_upgrade_v100/upgrade_v100.py ~/KoeBridge --build --open
```

アップデータは既存ログや設定・履歴JSONに触れません。基準バージョンと異なる／ソース改変がある場合は、失敗理由を表示して上書きせず停止します。現環境ではMac側でのビルド／起動は実行できません。
