# KoeBridge：Gemini API利用料金の目安

2026年11月6日時点の参考資料。KoeBridgeが使用するモデルは **Gemini 3.5 Transcribe Live**（gemini-3.5-transcribe-live）です。

## Google公式の有料枠の参考単価

2026年11月6日に確認したGoogle Gemini API公式料金表：

- 音声入力：100万トークンあたり **3.50 USD**、参考値 **約0.005 USD/分**
- 文字出力（思考トークンを含む）：100万トークンあたり **21 USD**、参考値 **約0.004 USD/分**
- 標準的な出力量を仮定した音声文字起こしの合計：**約0.009 USD/分**

出典：[Gemini API公式料金](https://ai.google.dev/gemini-api/docs/pricing?hl=ja)

以下の円換算は、2026年11月6日の参考為替を丸めた **1 USD = 158 JPY** の例であり、実際の請求為替レートではありません。

| Geminiへの音声入力時間 | 目安 USD | 目安 JPY |
| --- | ---: | ---: |
| 1分 | $0.009 | 約1.42円 |
| 10分 | $0.090 | 約14.22円 |
| 30分 | $0.270 | 約42.66円 |
| 60分 | $0.540 | 約85.32円 |
| 毎日10分 × 30日 | $2.700 | 約426.60円 |
| 毎日60分 × 30日 | $16.200 | 約2,559.60円 |

**重要：これは有料枠の標準的な文字起こし量を仮定した料金の例であり、実際の請求金額ではありません。** 無料枠、割引、クレジット、使用した文字出力トークン数、価格改定、為替などによって異なります。KoeBridgeアプリ本体はMITライセンスですが、Gemini APIの利用条件は別です。

Appleオンデバイス音声認識を使う場合、KoeBridgeはGemini APIを呼び出しません。

## Macで利用統計を安全に集計する

KoeBridgeの設定 → **利用統計** では、Gemini/Appleの試行回数、処理音声秒数、Geminiから受信できたトークン数が表示されます。

ローカルの保存先：
**~/Library/Application Support/KoeBridge/usage-monitor.json**

GitHubから最新のコードを取得済みの環境なら、ターミナルで次のコマンドを実行します。

~~~bash
cd "$HOME/KoeBridge"
python3 scripts/estimate_usage_cost.py --days 30 --usd-jpy 158
~~~

- このコマンドは**読み取り専用**で、ネットワーク接続やファイル変更を行いません。
- **日別**のGemini試行回数、Geminiへ送った音声分数、Apple試行回数、Appleへの切替回数、トークン報告合計、推定USD/JPYを表示します。
- 利用統計の日時はSwift JSONEncoderの**2001年1月1日基準**の秒数で保存されるため、日本時間に変換して集計します。
- **認識本文、録音、APIキー、音声ファイル、診断ログは読み取らず、表示もしません**。
- 為替レートは --usd-jpy オプションで手動指定します。省略すればUSDのみ表示します。
- 診断ログのON/OFFは不要です。通常の利用統計だけを使用します。

## 算出式と誤差

~~~text
有料枠参考料金（USD）＝ Gemini送信PCM音声秒数 ÷ 60 × 0.009
円換算参考額（JPY）＝ 上のUSD額 × 指定した円/ドル
~~~

**これは請求データから算出した料金ではありません。** 記録には無音や失敗した試行の送信音声も含まれます。実際に課金対象となったかはCloud Billingで確認が必要です。Appleの処理分数はGemini料金に加算しません。

また、GeminiのusageMetadataは欠落したり、複数回送信された値が累計だったりする可能性があるため、**報告トークンの単純合計は請求計算に使用しません**。あくまで参考表示です。

実際の請求額はGoogle Cloud Billingで対象の **プロジェクト・サービス・SKU・利用期間・無料枠・クレジット適用前後** を確認してください。同じ請求先にKoeBridge以外のAPI使用が含まれている場合、Google Cloudの合計料金をKoeBridge単独料金と表現することはできません。請求の反映が遅れる場合もあります。

公式請求資料：[Cloud Billingの詳細データ](https://docs.cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/detailed-usage)

**公開リポジトリに個人の請求明細・利用統計JSON・認識履歴・APIキーをアップロードしないでください。**
