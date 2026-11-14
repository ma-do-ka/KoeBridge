# 入力失敗の調査記録（v1.1.2 以降）

この記録は「カーソルが合っているのに入力できない」事象を調査するための内部向け資料です。入力失敗の原因を見た目だけで決めず、実際に実行した操作と判定を追います。ログに文章そのものを残す必要はありません。

## 再発時の記録方法

1. **設定 → 履歴と記録 → 問題調査用の記録を残す**を ON にします。重要記録の優先保持・要約を利用する場合は、設定 → 情報で **v1.1.4／Build 31** を確認してください。
2. 設定を閉じ、普段の入力先で音声入力します。連続入力時の問題なら「確定してすぐ次の録音」を含め、普段と同じ操作を行います。
3. 問題が起きたら、入力処理の終了表示を待ちます。発生時刻と入力先アプリ名は分かる範囲で添えてください。不明でも、残っている録音IDごとの要約から調べられます。
4. Finder の「移動 → フォルダへ移動…」で `~/Library/Logs/` を開き、`KoeBridge.log` と、存在すれば `KoeBridge.log.1`・`.2` を手元にコピーします。マイク・録音開始の問題では `KoeBridge-mic.log` と、存在する `.1`〜`.7` もコピーします。調査相手へ必要なファイルを添付してください。公開 Issue に無断でログを掲載しません。
5. 必要な記録が取れたらスイッチを OFF にできます。OFF にしても既存ファイルは残ります。削除は同じ設定ページの「動作記録を削除」を使用します。

録音開始時に OFF だった場合、その録音の入力 trace は作りません。処理中に OFF にした場合や記録を削除した場合、古い trace は後から書き込みません。再現の途中で OFF / 削除すると、その録音を調べる証拠が残らない点に注意してください。クラッシュ・強制終了などで入力処理が終了しなかった場合も、未保存の trace は残りません。

## 何を区別できるか

| 観測 | 主な理由・項目 | 判断できる範囲 |
| --- | --- | --- |
| 取得失敗 | `*_unavailable*`、`kind=ax` の `error` | macOS の問い合わせが失敗した / 必要な値がなかった。カーソルが動いた証拠ではない |
| 実際の不一致 | `focused_field_changed`、`focused_window_changed`、`caret_or_selection_changed` | 取得した入力先・選択位置が録音開始時と一致しなかった |
| 値が不正 | `*_invalid*`、`invalid_type`、`invalid_range` | 型または数値範囲が不正で照合できなかった |
| 送信前に停止 | `events_posted=0`、`stage=result` | キー入力を送信していない。権限、入力先、取消などの reason を追う |
| 一部だけ送信 | `outcome=partial`、予定数と送信数 | 途中で停止。全部を貼り直すと重複する可能性がある |
| 送信したが確認不能 | `outcome=unconfirmed` | イベントは送信したが、相手アプリへの反映を確認できなかった。送信完了は受理の証明ではない |
| 本文が変わらない | receipt の `reason=unchanged` | 読み取れた本文が送信前と同じ。イベント無視、遅延、同じ文字の置換などはこれだけでは断定できない |
| 本文・位置が不一致 | `textMismatch` / `selectionMismatch` | 期待する変更と読み取れた状態が一致しない。本文は記録しない |
| 待機が長い | `wait_ms`、`remaining_ms`、`deadline_exceeded` | 待機や AX 操作で予算を使い切ったか。次録音の capture と共通時刻で比較する |
| 前の入力が原因で停止 | `prior_input_unverified`、`kind=reconcile` | `related_take` と `prior_reason` から前の録音をたどる。前の入力の受理未確認と、今回の位置変更を区別する |
| 入力対象外 | `automatic_input_disabled`、`review_required`、`system_suppressed` など | 自動入力を試みない設定・状態だった |
| 発話の裏付け不足 | `acoustic_review_required` | 独立した発話確認を満たさず、自動入力しなかった |

`kind=ax` の `error` は AXError の数値です。`error=0` はその API 呼び出しの成功であり、キー入力の受理成功ではありません。`cannotComplete` のような通信失敗を、数値だけで「タイムアウト」と断定しません。要求した時間、設定結果、実測時間と合わせて読みます。[Apple の AXUIElement 仕様](https://developer.apple.com/documentation/applicationservices/axuielement_h)。

## 行の読み方

詳細行は `input_diag v=1`、v1.1.4で追加した要約行は `input_summary v=2` で識別します。既存の短い動作記録も同じファイルに残ります。

| 項目 | 意味 |
| --- | --- |
| `take` | 録音ごとの UUID。認識内容は含まない |
| `event` | 録音内の連番。0 は保持・省略件数の要約 |
| `t_ms` | trace 開始からの経過ミリ秒 |
| `uptime_ms` | 同じ Mac の単調時計。複数録音の実際の重なりを比較するための時刻 |
| `stage` | `requested` / `capture` / `preflight` / `posting` / `receipt` / `reconcile` / `result` |
| `part` | 同じイベントが複数行に分かれた場合の位置。`take` と `event` でまとめる |
| `elapsed_ms` | 対象操作の実測時間。AX では時間設定・読取・必要なリセットを含む |
| `timeout_ms` | AX へ要求した時間、または受理確認の時間予算。AX では `timeout_error` も確認する |
| `timeout_error` / `reset_error` | AX timeout の設定 / 既定値へのリセット結果。設定失敗時は要求値が有効だったと解釈しない |
| `modifiers` / `hardware_modifiers` | 送信直前の統合 / ハードウェア側の修飾キー状態。通常キーの内容は記録しない |
| `deadline_exceeded` | 受理確認の 600 ms の期限を実際に超えたか。最後の AX 呼び出しによる超過も含む |
| `budget_insufficient` | 次の確認前に残りが 20 ms 以下になり、確認開始を打ち切ったか。期限超過とは別 |
| `polls` | 実際に受理確認を試みた回数。最大 10 回 |
| `related_take` / `prior_reason` | 位置引継ぎの判定に関係した前後の録音と、先行入力の結果理由 |
| `dropped` / `retained` / `total` | メモリ内で省略した数 / 保持数 / 記録要求数 |

ファイル行頭の ISO 時刻は **保存時刻** です。入力診断は処理終了時にまとめて書き込むため、発生順や録音間の競合は `uptime_ms` と `t_ms` を使って追います。以前の起動・OS 再起動をまたいだ単調時計を、そのまま同一セッションとして比較しません。

`matches` は診断用の比較結果です。最終的な `verified_value_and_selection` には既存の受理確認、フォーカス再確認、取消・期限確認も必要です。診断結果だけで次の入力を許可することはありません。

## v1.1.4の要約と重要記録の保持

要約は元のイベントを整理して再表示したもので、新しい操作や成功判定ではありません。`take`、`event`、`t_ms`、`uptime_ms` は元のイベントと一致します。詳細と要約に同じイベントが現れるため、録音数や送信回数を二重に数えないでください。

| `section` | 内容 |
| --- | --- |
| `requested` / `target` | 実行Build・認識設定、取得した入力先アプリ |
| `captured` / `recognition` | 録音開始時の取得値、認識結果の文字数 |
| `preflight` / `focus` / `before` | 送信対象か、入力先の確認、送信前の取得値 |
| `payload` / `posted` | 送信予定文字数・修飾キー状態、実際の送信状況 |
| `expected` | 送信後に期待する本文長・カーソル位置 |
| `first_observed` / `observed` | 最初と最後の取得できた読取値 |
| `counts` / `result` | 照合回数と不一致の内訳、最終結果・終了理由 |
| `first_reconcile` / `reconcile` | 前後の録音との最初と最後の照合 |

その処理が実行されなければ該当sectionはありません。不明な値を成功やゼロで埋めません。`snapshot` に由来する要約では、2回の選択位置読取の最初を `first_read_start` / `first_read_length` に改称します。`section=expected` の `expected_start` は送信後に期待する位置です。この2種類を混同しないでください。互換性のため、`input_diag v=1` の元のフィールド名は変更していません。

## 保存する情報の境界

trace の文字列は固定コードと検証済みのアプリ bundle ID に限定します。本文・音声・API キー・ウィンドウ名・URL・本文ハッシュは渡しません。選択位置や長さ、入力前後の文字数、処理時間、PID、OS / Build 番号などは含みます。これらも動作状況を表す情報なので、調査に必要な相手だけに共有してください。

1 録音につき最大 128 イベントで、先頭 32 件に加え、上記sectionに対応する重要イベントと最近の情報を優先保持します。繰り返しのAX応答などは途中で省略されることがあります。各行のイベント部分は、先頭の ISO 時刻と改行を除いて 320 bytes 以下に分割します。要約も含めて主ログは各 256 KiB、3 世代まで（マイク専用の長期保持ミラーは各 256 KiB、8 世代まで）のため、古い trace はローテーションで消えます。

入力診断の収集中はファイル I/O を行わず、入力と後続録音の照合が終わってから batch 保存します。Build 65 の追加観測は下記の送信後チェックに限定し、本文は記録しません。既存のマイク・認識処理などの短い動作記録は従来の同期保存を継続します。

## Build 65（v1.1.10）の観測と送信間隔

`section=capability` は送信前の選択位置読取・本文読取の状態、`section=eligibility` はその配送の受理確認可否です。`receipt_skipped_reason` のコードは次の集合に限定します。

| コード | 意味 |
| --- | --- |
| `marker_not_numeric` | 不透明な marker 選択で、数値位置付き snapshot を作れない |
| `selection_missing` | 取得時に選択位置がなかった |
| `selection_unavailable` | 数値選択の再読取が失敗・欠落・不正だった |
| `value_unavailable` | 選択位置は読めたが本文を利用できなかった |
| `snapshot_invalid` | 本文と選択位置を安定した有効な snapshot にできない、または期待する編集を構成できない |
| `no_observable_delta` | 期待する編集後の本文が編集前と同一 |
| `snapshot_available` | 正確な編集前 snapshot が利用可能。受理成功を意味しない |
| `not_attempted` | その段階の観測に進まなかった |
| `unknown` | 既知の分類を決める情報がない |

`selection_read` と `value_read_result` は `not_attempted` と失敗を区別します。`value_read_attempted` は AXValue 呼び出し自体の有無です。secure 判定で除外した場合は `value_read_attempted=0 value_read_result=secure`、追加観測で secure 除外を確定できない場合は `unknown` です。サイズ上限は既存どおり 200,000 UTF-16 units です。`exact_baseline_available` は正確な数値位置と本文の組を取得できたかを表します。

数値選択には `numeric_selection_v1`（version 1、gap 3 ms、累積 300 ms、100 gap 後は 0 ms）、marker / 選択なしには `unobservable_selection_v1`（version 1、gap 20 ms、予算 2,000 ms）を使います。最初の chunk は即時です。後者は予算超過でも 20 ms を維持し、`pacing_budget_exceeded=1` を記録します。途中停止も後半の間隔圧縮も行いません。取消・入力先チェックは各 chunk の前に従来どおり実行します。

`section=progress` に予定数・送信数、`last_posted_ordinal`、gap 数、要求 gap と実測 gap の最小・最大・最終値（`*_us`、マイクロ秒）、`posting_stall_total_us`、停止した段階・理由（`abort_phase` / `abort_reason`）を集約します。実測 gap は前の keyUp の post 呼び出しが戻ってから次の keyDown の post 呼び出し開始までです。stall 合計は post 呼び出し時間と、要求 sleep を超えた gap 時間の和で、AX・スケジューラ・イベント構築などを含みます。相手アプリ内部の処理時間ではありません。投稿中に chunk ごとのファイル保存は行いません。

各 full checkpoint の `require_original_selection` は照合の要求、`selection_comparison` は `same` / `different` / `unknown` / `skipped` の観測です。`chunk_ordinal` は直前に検査する chunk の 1 始まり番号、preflight は 0、送信後は最後に送信した番号です。`section=first_checkpoint` / `checkpoint` に最初と最後の投稿前チェックを優先保持します。

受理確認できない経路で全 chunk を送った後、記録が有効な場合だけ、1 回の入力先 identity チェックと本文だけの独立観測を行います。各 AX 読取の要求 timeout は 10 ms、secure でないことを確認でき、入力先が一致する場合だけ本文を読みます。`section=observation` の `outcome` は入力先の `same` / `different` / `unknown`、`receiver_observation` は `value_only` / `unavailable` です。本文観測は数値位置付きの受理確認ではなく、Report・次の入力の許可には使いません。marker / 選択なしの受理不明表示は従来どおりです。

これらの section も 128 イベントの同じ予算内で優先保持し、`dropped` は省略数を引き続き記録します。sender の計測だけで相手側の完全受理・部分受理・後からの巻戻りを証明することはできません。

## 調査で残る限界

この仕組みで、どの段階・どのチェックで失敗したかを絞り込めます。ただし、相手アプリが合成イベントを無視した内部理由や、OS 内部の通信失敗原因までログだけで確定できるわけではありません。本文は記録しないため、文字の差分も復元できません。必要に応じ、入力先アプリの種類・版、失敗時刻、操作順と照合します。受理不明の文章を自動再送する処理は追加していません。

## v1.1.3のPCM数値とビルドによる違い

`kind=session stage=capture` に `acoustic`（`near_silence`／`uncertain`／`activity`／`unavailable`）、`audio_frames`（20ms区間数）、`active_frames`、`max_rms_ppm`（最大区間RMS×100万）、`modulation_pct`（時間変動率の概算％）、`invalid_samples` を記録します。

**Build 29のactivityは音量・変動条件だけでした。Build 30以降のactivityは独立したSoundAnalysis分類が発話を確認した状態です。** 同じ名前でもビルドを混同しないでください。Build 30以降では、小声を失わないため、分類で確認されていない低音量の信号を単純な閾値で無音扱いしません。`near_silence` は全ゼロの信号を確認した状態です。どの判定も本人の意図や認識内容の正しさを証明しません。

`stage=requested` の `registered_terms`・`topic_terms`・`vocabulary_count` により用語候補の設定と件数、`stage=result` の `engine`・`recognized_utf16` により結果を返した認識方式と文字数を追えます。**単語そのものは残しません。**

## Build 30以降の発話分類記録

- `speech_classifier_started capture=<UUID> build=<Build番号>`：マイク処理単位の診断開始。
- `speech_classifier capture=<UUID> state=... windows=... positives=... max_permille=... allowed=...`：分類終了時の数値。

`capture` はマイク処理専用のUUIDで、入力診断の `take` とは別です。`started` と終了行を同じ `capture` で結び、時刻と入力診断の録音順序を照合してください。`windows` は分類区間数、`positives` はスコア条件を満たした区間数、`max_permille` は最大分類スコアの1000倍、`allowed` は分類結果による許可状態です。スコアは成功率や認識精度そのものではありません。

`state=failed` または `timedOut` は分類処理の失敗・待機期限超過であり、無音の証拠ではありません。この場合は自動入力を許可しません。`completed` でも `allowed=false` なら発話確認は得られていません。`allowed=true` の誤検出もあり得るため、ユーザーの実際の状況と合わせて調査します。

これらの行はONで開始した録音に限定し、OFF・再ON・削除で古い診断を失効させます。新しいログ画面はありません。音声・本文の保存や自動アップロードは追加していません。
