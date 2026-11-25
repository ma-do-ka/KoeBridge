# AmiVoice連携と3エンジンベンチマーク

この文書では、KoeBridgeにおけるAmiVoice連携の位置づけと、Appleオンデバイス認識・Gemini Live・AmiVoiceを同じ音声で比較する `KoeBridgeBench` の使い方を説明します。

## AmiVoice連携とは

AmiVoiceはKoeBridgeの3つ目の音声認識エンジンです。既存のAppleオンデバイス認識とGemini Liveに加えて、日本語向けのクラウド音声認識を選択できます。

ベンチマークで使うAmiVoice WebSocket接続は **`nolog` エンドポイント** です。プロバイダ側でログ保存しない契約の接続先であり、APIキーはWebSocketのアップグレード時の `Authorization: Bearer` ヘッダーでのみ送信します。リダイレクトは拒否し、別ホストへキーが転送されないようにしています。

`KoeBridgeBench` は `KoeBridge.app` には組み込まれない開発用の実行ターゲットです。アプリ本体の製品構成には含めず、リリースアプリへの同梱もしません。

## 同一音声であることの保証

3エンジンの比較は、入力が少しでも違うと精度差か音声差かを区別できません。`KoeBridgeBench` は次の方法で同一入力を確認します。

1. **正準PCMだけを受け付ける**
   - すべてのWAVを `PCM16WAV.extractPCM` で読みます。
   - 正確に 16 kHz、16-bit signed little-endian、モノラル、規定どおりの44バイトヘッダーを持ち、45秒以内のWAVだけが有効です。
2. **SHA-256で固定する**
   - ファイル全体ではなく、WAVから取り出したPCMバイト列のSHA-256を使います。
   - 実行前に `pcm_sha256` を計算し、マニフェストにロック済みの値と比較します。
   - 全エンジンの結果行に同じ `pcm_sha256` と `pcm_bytes` を記録し、集計前にクリップごとの一致を確認します。
3. **同じチャンクと速度で送る**
   - 同じ immutable なPCMデータを、どのエンジンでも 1,600 バイト（50 ms）ずつに分割します。
   - 既定の `--pacing realtime` では、50 ms間隔を `ContinuousClock` のドリフト補正版スケジュールで送ります。個々の送信遅延を次回以降の待ち時間に累積させません。
4. **順序効果を抑える**
   - 既定の `--order round-robin` では、クリップごとに Gemini Live → AmiVoice → Apple の開始位置を巡回します。
   - エンジン間には1秒のクールダウンを入れます。
5. **ベースライン条件を揃える**
   - 語彙指定なし、Gemini Live は `verbatim` と `japaneseHint`、後処理やレビュー処理なし、クリップごとの新規接続です。
   - AmiVoiceは `nolog` 接続、既定のセグメンタ設定、既定では `-a2-ja-general` です。
   - AppleはOSが提供するローカル認識器を使い、OSバージョンとバックエンドを結果に記録します。
   - 任意の `--vocab-file` はベースラインとは別の語彙アブレーションです。同じ語彙リストをGeminiとAmiVoice E2Eへ渡します。Appleはこの指定に非対応として記録します。

## コーパス

コーパス定義は `Tools/KoeBridgeBench/corpus/manifest.json` 1件に統合されています。音声そのものはGitに入れません。

| Track | 内容 | 本数 | 用途 |
| --- | --- | ---: | --- |
| Track 1 | 固定台本の実音声録音 | 24本（6カテゴリ×4本） | 主データセット |
| Track 2 | macOS TTSの決定的な合成音声 | 12本（6カテゴリ×2本） | 再現性付録 |

カテゴリは次の6種類です。

1. 会話メモ
2. ビジネス・敬語と同音異義語
3. 日本語＋英語の技術用語
4. 数字・日付・金額・バージョン
5. 実音声では言い淀みと間、TTSでは口語・短い区切り
6. 長めの連続発話

音声、結果、クォータ台帳は既定で次の場所に置きます。

```text
~/.cache/koebridge-bench/audio/*.wav
~/.cache/koebridge-bench/results/<run-id>.jsonl
~/.cache/koebridge-bench/results/<run-id>-report.md
~/.cache/koebridge-bench/quota-ledger.json
```

これらをGitに入れない理由は、公開リポジトリの監査が未固定のバイナリと大きなファイルを禁止しているためです。台本とメタデータだけをUTF-8の `manifest.json` として管理し、録音物・合成物・測定結果は常にリポジトリ外に置きます。

## Track 2の生成

macOS上で次を実行します。引数を省略すると `~/.cache/koebridge-bench/audio` に生成します。

```bash
bash scripts/bench_generate_tts.sh
```

別の出力先を使う場合も、リポジトリ内のパスは拒否されます。

```bash
bash scripts/bench_generate_tts.sh "$HOME/.cache/koebridge-bench/audio"
```

スクリプトは `manifest.json` からTrack 2の台本と声（`Kyoko` / `Otoya`）を読み、`say` で合成した後、`afconvert -f WAVE -d LEI16@16000 -c 1` で変換します。最後に正準44バイトヘッダーのWAVへ整形し、生成に成功した一時ファイルから最終ファイルへ置き換えます。繰り返し実行できます。

各行に `pcm_sha256` と `file_sha256` を表示します。マニフェストの `sha256` へロックする値は **PCM SHA-256** です。`file_sha256` はファイル移送時の確認用です。

## ドライラン（既定・ネットワークなし）

`KoeBridgeBench` は既定でドライランです。APIキーがなくても実行でき、ネットワーク呼び出しは行いません。

```bash
swift run KoeBridgeBench \
  --manifest Tools/KoeBridgeBench/corpus/manifest.json \
  --audio-dir "$HOME/.cache/koebridge-bench/audio"
```

確認内容は次のとおりです。

- マニフェストのJSON構造、ID一意性、カテゴリ構成（Track 1は4本×6、Track 2は2本×6）、参照文の非空、音声形式定義
- 存在するWAVの正準形式、PCM SHA-256、ロック済みハッシュとの一致
- 存在するクリップの音声秒数とバイト数の合計
- 月次クォータ台帳の読み取りと、予定使用量の投影

音声ファイルがまだない状態では、各クリップが `missing` と表示されます。これは録音前の通常状態であり、クラッシュではありません。マニフェスト破損またはロック済みハッシュ不一致だけが非ゼロ終了です。

## ライブ実行

ライブ実行には明示的な `--live` が必要です。

```bash
swift run KoeBridgeBench --live \
  --manifest Tools/KoeBridgeBench/corpus/manifest.json \
  --audio-dir "$HOME/.cache/koebridge-bench/audio" \
  --engines gemini,apple,amivoice \
  --amivoice-engine=-a2-ja-general \
  --pacing realtime --order round-robin --usd-jpy 158 \
  --out "$HOME/.cache/koebridge-bench/results"
```

主なオプションです。

- `--engines apple,gemini,amivoice`: ライブ実行するエンジンをカンマ区切りで指定
- `--amivoice-engine`: `-a2-ja-general`、`-a2b-ja-general`、`-a-general-input` など対応エンジンを指定
- `--pacing realtime|fast`: 50 ms実時間ペースか、待ち時間なしの高速送信かを指定。比較用の既定は `realtime`
- `--order round-robin|fixed`: クリップごとのエンジン順を巡回するか固定するかを指定
- `--usd-jpy`: Gemini費用の参考円換算レート（既定158）
- `--monthly-cap-seconds`: AmiVoiceの月次安全上限（既定2700秒）
- `--vocab-file`: 語彙アブレーション用の1行1語のリスト

`--amivoice-engine` は1回の実行につき1種類です。`-a2b-ja-general` や `-a-general-input` も測る場合は値を変えて個別にライブ実行します。結果行の `variant` とレポートのラベルには指定したエンジン名が入るため、別種類の結果として区別できます。

Gemini APIキーは、macOS Keychainのservice `dev.koebridge.gemini-api` / account `personal-key`、または環境変数 `GEMINI_API_KEY` から読みます。AmiVoice APIキーは、service `dev.koebridge.amivoice-api` / account `api-key`、または環境変数 `AMIVOICE_API_KEY` から読みます。要求したエンジンのキーがない場合、そのエンジンの各行へ `missing_key` として記録します。クラッシュや暗黙のスキップはしません。

## クォータガードと台帳

`quota-ledger.json` はリポジトリ外のキャッシュに保存されます。キーは日本時間の `YYYY-MM` とAmiVoiceエンジン名で、消費した発話秒数を保持します。

ライブ実行前に、台帳の当月消費量に今回の予定秒数を足した投影値を計算します。実行前はVAD発話秒数が分からないため、正準音声の壁時計秒数を保守的な予定値として使います。投影値が `--monthly-cap-seconds`（既定2700秒）を超える場合、**ネットワーク呼び出しを始める前に中止**します。

ドライランでは台帳を読み取って投影だけを表示し、書き込みません。ライブ実行では各AmiVoiceクリップの後に実測発話秒数（得られない場合は送信音声秒数）を台帳へ反映します。台帳を更新できない場合は、以降のネットワーク呼び出しを中止します。

## 録音後のハッシュロック

初期状態では、マニフェストの各 `sha256` は `null` です。録音またはTTS生成後にロックします。

1. Track 1を正準WAVとして `~/.cache/koebridge-bench/audio` に置きます。Track 2は生成スクリプトを使います。
2. ドライランを実行し、各クリップに表示される `pcm_sha256` が期待どおり計算できることを確認します。
3. マニフェストの該当 `sha256` を `null` からPCM SHA-256へ置き換えます。
4. もう一度ドライランし、`locked_verified` が増え、不一致がないことを確認します。

ハッシュはWAVファイル全体ではなくPCMバイト列に対する値です。同一PCMを正準ヘッダーで再包装しても一致し、余分なメタデータ差に左右されません。

## 出力ファイル

ライブ実行ごとに、指定した `--out` へ2種類を書きます。出力先がリポジトリ内なら実行を拒否します。

- `<run-id>.jsonl`: `(clip_id, engine, variant)` ごとの1行JSON。PCMハッシュ、音声秒、発話秒、ステータス、生テキスト、採用テキスト、CER、レイテンシ、トークン、参考費用、OS、Appleバックエンド、Gitコミットを含みます。
- `<run-id>-report.md`: 公開用のMarkdown集計。Track 1とTrack 2は完全に別表です。

## レポートの読み方

- `cer_norm`: Unicode NFKC後にASCII大文字を小文字化し、空白と規定の句読点を除いて計算する主要な文字誤り率です。カテゴリや全体の値は、クリップ平均ではなく `Σedits / ΣN_ref` のマイクロ平均です。`N_ref` 列があるため再計算できます。
- `cer_strict`: Unicode NFCのみに正規化し、空白・句読点・大文字小文字を保持した厳格な文字誤り率です。
- `cer_strict（日本語スペース適用後）`: 参照文と認識結果の双方へ同じ日本語スペース採用変換を適用してから計算するstrict CERです。
- 失敗クリップは、成功分の値だけでなく `成功 x/y` と100%削除ペナルティ込みの値も併記します。全件失敗なら成功分は `N/A` です。
- `connect_ms`: 接続またはローカル認識器の準備時間です。AmiVoiceは遅延接続のため、最初の音声送信に含まれる準備時間を測定します。
- `ttfi_ms`: 最初の音声送信から最初の途中または確定テキストまでの時間です。`-a2b-ja-general` では途中結果がないため `N/A` です。
- `stop_to_final_ms`: 音声終了の送信開始から最終確定までの時間です。
- レイテンシ表はTrackごとに分かれ、`p50` / `p90` / `p95` / `max` を示します。
- 費用表もTrackごとに分かれ、無料枠の扱いと限界単価を分けます。無料枠は月次・エンジン単位で両Trackの合計へ適用されます。AppleはAPI費用なし、Geminiは音声分の参考混合単価と利用可能なトークン報告、AmiVoiceはエンジンごとの月次無料発話秒と `nolog` の発話秒単価を区別します。表示は請求確定値ではありません。
- 失敗表もTrackごとに分かれ、失敗・タイムアウト・音声欠落・キー欠落をすべて列挙します。0件のときは `該当なし（0件）` と明示します。
- 表内のエンジン順は常に Apple → Gemini Live → AmiVoice です。

## 公開時の注意

結果JSONLには認識本文が含まれます。音声ファイル、結果JSONL、クォータ台帳、APIキー、個人的な利用統計を公開リポジトリへ入れないでください。公開するのは集計済みで公開安全なレポート本文だけにしてください。
