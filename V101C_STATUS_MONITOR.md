# KoeBridge v1.0.1-c（試験機能）：ステータスモニター

- 変更箇所：既存の設定画面 SettingsView の TabView に「ステータスモニター」タブを新規追加。既存4タブの項目・設定値は変更しない。
- Gemini 3.5 Transcribe Live / Apple オンデバイスに実際に処理を試みた回数、成功・失敗、Gemini指定からAppleへの切替、各エンジンへ送信・投入したPCMデータの秒数を記録。
- GeminiからWebSocketで到着した usageMetadata.totalTokenCount の値を、各メタデータ受信時刻で記録。推定トークンは追加しない。複数報告は別々の報告として合算するが、請求額との一致は保証しない。
- 表示粒度：1分（直近60分）・1時間（直近24時間）・1日（直近14日）。各グラフで同じ間隔を使用。時刻はこのMacのローカル時間帯で表示。
- 変更対象：GeminiWireのトークン解析、GeminiLiveConnectionのカウンタ、VoiceControllerのエンジン計測、設定タブ、新規Swift Charts画面、新規デバイス内JSON統計保存。
- 音声・文字起こし・APIキー・生のレスポンスは利用統計に保存しない。保存先：~/Library/Application Support/KoeBridge/usage-monitor.json。30日保持、最大6,000処理イベント・20,000トークンイベント・8MiB。診断ログは引き続き初期OFF。
- 使用秒数は処理した16kHz/16-bit/mono PCMバイト数÷32,000。無音も含むため「発話時間」ではない。Gemini→Apple救済の場合、両エンジンにデータを渡すため両方に計上する。
- Apple音声認識は SFSpeechRecognizer の requiresOnDeviceRecognition=true に限る。「Apple Intelligence」テキスト処理はこのアプリの別エンジンではない。
- 利用統計は録音の完了時に更新。途中で通信断が起こった場合も既に収集されたメタデータがあれば記録する。usageMetadata未受信の際は未取得と表示する。
- アプリ表示は v1.0.1-c、CFBundleShortVersionString はApple形式に合わせ1.0.1、CFBundleVersionは18。公開リリース確定ではない。

## macOSでの受け入れ確認（未実施）
1. swift test --parallel
2. swift build -c release
3. KOEBRIDGE_ALLOW_ADHOC=1 bash ./scripts/build_app.sh（開発確認時のみ。日常署名は既存の固定署名を使う）
4. 設定画面の既存4タブと新規タブ、ウィンドウ幅、棒グラフの表示崩れがないこと。
5. Gemini指定で録音→確定し、Gemini試行とPCM秒数、APIが報告したトークン数を確認する。トークン情報が返らない場合は「未取得」となる。
6. Apple指定で録音→確定し、AppleのみのカウントとPCM秒数を確認する。
7. Gemini認識失敗からApple救済になった場合、両エンジンの試行と各PCM秒数、フォールバック1回を確認する。
8. 1分/1時間/1日の切替、再起動後の履歴復元、統計削除、診断ログOFF保持、認識履歴が残ることを確認する。
9. Google AI Studioで同じAPIキーの使用状況と大きな乖離がないか確認する（完全一致を要求しない）。

注意：CIの単体テスト/ビルドはMac実機のマイク・API通信・権限ダイアログを再現しない。実機でのE2E確認は別途必要。
