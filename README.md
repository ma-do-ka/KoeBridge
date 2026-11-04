# KoeBridge 🎙️

**Google AI Proなどの特典で、利用可能なGoogle Cloudクレジットが余っている人にも。**  
macOSのための、**超軽量を目指したオープンソース音声入力アプリ**です。

> **録音キー → 話す → 同じキーで確定。** 文字起こし結果を、元の入力欄へ直接送ります。  
> Swift製のネイティブなメニューバーアプリ。Electron・Webブラウザー・Python常駐サーバーは不要です。

**v1.0.0 / MIT License / 自由に改造・再配布OK**（ライセンス表示の維持が条件）

## こんな人向け

- Google AI Pro契約者で、**Gemini APIに適用可能な**Google Cloudクレジットを活用したい人
- ChatGPT・ブラウザー・エディターなどで、日本語の音声入力を使いたい人
- 大きな常駐アプリを避け、ローカルのSwiftコードを自分好みに変更したい人
- クラウド音声認識を使わず、Appleオンデバイス認識を選びたい人

**重要：Google AI Proへの加入だけでGemini APIが無制限・無料になるわけではありません。** Google AI ProにはDeveloper Program特典として月額10米ドル相当のGoogle Cloudクレジットが案内されていますが、*そのクレジットがGemini APIの利用料金に充当されるか* は、種類・利用条件・請求先の紐付けに依存します。無料トライアル/ウェルカムクレジットはGemini API対象外の場合があります。前払い設定を要求されるケースもあります。必ず本人のGoogle AI Studio / Cloud Billing上で確認してください。料金を自動制限する機能はありません。

## 主な機能

| 機能 | 内容 |
| --- | --- |
| Gemini音声認識 | Gemini 3.5 Transcribe LiveをWebSocketで利用（APIキーが必要） |
| Appleローカル認識 | macOSのオンデバイス音声認識へ切替可能（対応環境のみ） |
| ショートカット | 同じキーで録音開始・停止。F8、右Commandなどを設定から選択 |
| 自動入力 | 元の入力先が維持されている場合に直接入力を試みる。入力先が変わった場合は中止 |
| 認識履歴 | 直近10件を端末内に保持。入力失敗時はコピー可能 |
| Gemini辞書 | 専門用語のヒントを設定可能 |
| 診断ログ | **初期OFF**。設定画面でON、上限約384KiB、手動削除可能 |

※ アプリ側が合成キー入力を受理しない場合があります。どのアプリにも必ず自動入力されるわけではありません。

## ゼロからインストール・アプリ生成（コマンド付き）

**対象：Apple Silicon / macOS 15以降。** 完成済みの署名・公証済みインストーラーではなく、ソースから自分のMac用にビルドする方式です。以下のコマンドはMacの「ターミナル」で実行してください。

### Step 1 — 開発環境を準備

```bash
# Command Line Toolsを未導入の場合だけ実行（画面の案内に従う）
xcode-select --install

# インストール状態を確認
xcode-select -p
swift --version
git --version
```

`xcode-select --install` が「既にインストールされています」と表示されたら再インストールは不要です。Swift 6系を推奨します。`swift --version` が失敗する場合はXcodeまたはCommand Line Toolsの選択状態を確認してください。

### Step 2 — リポジトリを取得

```bash
cd ~
git clone https://github.com/ma-do-ka/KoeBridge.git
cd KoeBridge
```

**既に `~/KoeBridge` がある場合**、cloneを繰り返して既存のコードを上書きしないでください。更新前に自分の変更をバックアップしてください。

### Step 3 — テストと .app の生成

```bash
# Swift Testingの単体テスト
swift test --parallel

# ポータブルな自己テスト
swift run -c release KoeBridgeSelfTest

# ビルド・署名検証・アプリ起動
bash scripts/verify_and_build.sh --open
```

ビルド後のアプリ：`dist/KoeBridge.app`。`verify_and_build.sh` は署名証明書がない場合、自動的に不安定なアドホック署名へ切り替えず停止します。**証明書がない開発・個人テスト用途のみ**、次を明示的に実行できます。

```bash
KOEBRIDGE_ALLOW_ADHOC=1 bash scripts/verify_and_build.sh --open
```

アドホック署名ではビルド更新後にmacOSの各種許可を再設定する場合があります。OSのセキュリティ機能を無効にする必要はありません。

アプリが生成されたか確認・再起動する場合：

```bash
ls -ld dist/KoeBridge.app
open dist/KoeBridge.app
```

### Step 4 — APIキー・権限・音声入力

1. メニューバーの **KoeBridge → 設定… → 音声入力** で認識エンジンと「録音・確定キー」（例：F8）を選びます。
2. Geminiを使う場合は、[Google AI Studio](https://aistudio.google.com/apikey)で**自分のAPIキー**を作成します。アプリの **設定… → Gemini → Gemini APIキー → 登録・更新** から登録してください（macOSキーチェーン保存）。AppleオンデバイスならAPIキー不要です。
3. **設定… → 権限** でマイク・アクセシビリティ・入力イベント送信の状態を確認します。右Commandなどの単独修飾キーには入力監視の許可が必要な場合があります。
4. メモやChatGPTの**入力欄をクリック** → 録音キー → 話す → 同じキーで停止。対象アプリが受理すれば、認識した文字が入力されます。

## How-to（やりたいこと別の操作）

| やりたいこと | 実際の場所・コマンド |
| --- | --- |
| 録音キーをF8などに変更 | `設定… → 音声入力 → 録音・確定キー` |
| 自動入力を停止 | `設定… → 音声入力 → 録音停止後に元の入力先へ自動入力`をOFF |
| APIキーを追加・変更 | `設定… → Gemini → Gemini APIキー → 登録・更新` |
| APIキーを削除 | `設定… → Gemini → APIキー → 削除` |
| 日本語ヒント／SMART整形を変更 | `設定… → Gemini → 認識精度` |
| 専門用語を登録 | `設定… → Gemini → 認識精度 → 専門用語辞書`（1行1語） |
| Appleオンデバイス認識に変更 | `設定… → 音声入力 → 認識エンジン` |
| 自動入力に失敗した文章をコピー | メニューバー → `認識履歴（直近10件）…` |
| 診断ログON/OFF（初期OFF） | `設定… → 履歴・診断 → 診断ログを保存する` |
| ログだけ削除 | `設定… → 履歴・診断 → 既存ログを削除` |
| コード変更後に再ビルド | KoeBridgeを終了して `bash scripts/verify_and_build.sh --open` |
| テスト | `swift test --parallel` と `swift run -c release KoeBridgeSelfTest` |

**好きに改造してOK：** `Sources/KoeBridge/` が画面・音声入力等のmacOSアプリ、`Sources/KoeBridgeCore/` が共通処理、`Tests/` がテストです。MITライセンスに従って改造・フォーク・再配布・商用利用が可能です（著作権表示とライセンス文を維持してください）。

## Q&A / FAQ

**Q. Google AI ProならGemini APIが完全無料ですか？**  
A. いいえ。Google AI Proの開発者特典には月額$10相当のクレジットが案内されていますが、実際のAPI利用への適用はクレジット種別・請求先の紐付け・前払い方式によります。公式の[特典](https://developers.google.com/profile/help/benefits?hl=ja)・[課金ルール](https://ai.google.dev/gemini-api/docs/billing?hl=ja)を確認してください。KoeBridgeには支出上限を自動設定する機能はありません。

**Q. トークンやクレジットの残高をKoeBridgeから確認できますか？**  
A. できません。Google AI Studio / Cloud Billing側で使用量と請求状況を確認してください。

**Q. APIキーをソースやコマンドに貼る必要はありますか？**  
A. 不要です。キーは`設定… → Gemini`で入力し、macOSキーチェーンへ保存します。Issue・スクリーンショット・GitHubにキーを掲載しないでください。

**Q. F8で録音が始まりません。**  
A. macOSのファンクションキー設定・他アプリとの競合・必要な入力監視権限を確認し、`設定… → 音声入力`で別キーも試してください。

**Q. 認識はできるのにChatGPTやChromeへ文字が入りません。**  
A. `設定… → 権限`で許可を確認し、録音開始前に入力欄を選択してください。途中で入力先が変わった場合は誤入力防止で中止します。一部アプリは合成キー入力に対応しないため、直近10件の認識履歴からコピーできます。

**Q. マイクやアクセシビリティを再び許可する必要がありますか？**  
A. macOSの「システム設定 → プライバシーとセキュリティ」で確認してください。アプリ側ではOSの許可を強制できません。コード署名の変更やアドホック署名への切替で再許可が必要になる場合があります。

**Q. Appleオンデバイス認識ならAPIキーは不要ですか？**  
A. 不要です。対応する言語・端末内モデルが必要です。Geminiモードの音声はGoogle APIへ送信されます。

**Q. ログは肥大化しますか？認識本文も記録されますか？**  
A. 診断ログは初期OFFで、ONの場合もサイズ上限があります。認識履歴はログとは別に、最大10件がMacに平文で保存されます。不要な履歴は履歴画面から削除してください。

**Q. 完成済みインストーラーや動作保証はありますか？**  
A. 公証済みの`.dmg`はありません。macOS実機での全環境の動作確認も完了していません。`TEST_REPORT.md`に検証範囲を記載しています。


## Google AI Proのクレジットを使う前のチェック

1. [Google Developer Programの特典](https://developers.google.com/profile/help/benefits?hl=ja)で自分のプラン・クレジットを確認します。
2. [Google AI StudioのAPIキー](https://aistudio.google.com/apikey)を作成し、**そのプロジェクト**が使うCloud Billingの請求先を確認します。
3. [Gemini APIの請求・クレジット適用条件](https://ai.google.dev/gemini-api/docs/billing?hl=ja)を確認します。特に前払い方式ではクレジット適用に別の前払いが必要なことがあります。
4. [Gemini APIの利用量](https://aistudio.google.com/)で実際のトークン使用量・料金を確認します。モデルごとの料金と無料枠は変動します。

KoeBridgeがクレジット残高を読み取る機能はありません。**「AI Proに入っている＝このアプリのAPI料金がゼロ」とは表明していません。**

## プライバシーとセキュリティ

- **実際のAPIキーは同梱されません。** 初回利用時に設定画面から自分のキーを登録してください。
- Geminiモードでは音声をGoogle APIへ送信します。AppleオンデバイスモードではAppleの対応する端末内音声認識を利用します。
- 認識履歴は `~/Library/Application Support/KoeBridge/recent-transcripts.json` に保存されます。**平文**なのでMacアカウントとバックアップの保護に注意してください。
- 診断ログ `~/Library/Logs/KoeBridge.log` は初期OFF。設定画面 **「履歴・診断」→「診断ログを保存する」** でON/OFF、**「既存ログを削除」** で削除できます。
- 自動入力はOSのアクセシビリティ・入力イベント送信権限に依存し、対象アプリの仕様上動作しない場合があります。
- `.gitignore` と公開前スキャンを同梱しています。**自分のAPIキー、ログ、認識履歴、証明書、環境変数ファイルはGitHubへアップロードしないでください。**

詳しくは [SECURITY.md](SECURITY.md) を参照してください。

## 軽量化の考え方

- Swift + Apple標準フレームワーク中心のネイティブ構成
- Electron、常駐Webサーバー、別途Pythonランタイムなし
- 診断ログ通常OFF、上限付き／不必要な診断観測を省略
- ローカル履歴は最大10件、録音データのファイル保存をしない設計

※ **メモリ使用量やCPU負荷の他製品との比較測定は未実施**です。「超軽量」は設計方針であり、測定済みの性能保証ではありません。

## 開発・改造

ソース: [`Sources/KoeBridge/`](Sources/KoeBridge/) / 共通ロジック: [`Sources/KoeBridgeCore/`](Sources/KoeBridgeCore/) / テスト: [`Tests/`](Tests/)。

```bash
swift test --parallel
swift run -c release KoeBridgeSelfTest
```

GitHub ActionsではmacOS上でSwiftテスト・ビルドを行う設定を用意しています。ただし**CIが実行されるまではmacOSでの成功を確認できません**。プロジェクト所有者向けの安全な新規公開スクリプトは `scripts/publish_to_github.sh` にあります（`ma-do-ka` アカウント専用）。

改造、フォーク、再配布、商用利用も **MITライセンス**に従い自由です。個人利用向けの実験的なアプリなので、使いやすいように好きに変えてください。

## バージョンと既知の制限

- v1.0.0：設定画面を4タブに整理、メニューの操作不能行を削除、ログ初期OFF・容量制限、スリープ等での誤入力対策。
- 開発環境でのLinux側テストは実施済み。**Mac実機でのビルド、Gemini実通信、マイク、各アプリへの入力は、この配布パッケージ作成環境からは未検証です。**
- 詳細：[`V100_RELEASE_NOTES.md`](V100_RELEASE_NOTES.md) / [`TEST_REPORT.md`](TEST_REPORT.md)

---

**KoeBridge はGoogle・Appleとは無関係の個人開発プロジェクトです。** Gemini・Appleの各商標はそれぞれの権利者に帰属します。