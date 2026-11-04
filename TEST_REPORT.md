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
