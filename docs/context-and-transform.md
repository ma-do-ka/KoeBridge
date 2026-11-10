# Context and voice transformation — Build 48

Both features are off by default. Context assistance has its own master switch;
voice transformation is disabled until a shortcut is assigned in Voice settings.

## Context-assisted audio recheck (R-07)

Enable 「文脈を使って再チェックを補助する」 in Gemini settings and choose
アプリ名 / 選択テキスト / 周辺テキスト. Source defaults are app on, selection on,
surrounding off. The source controls are disabled while the master is off.
Only enabled sources are captured at take start, before showing the overlay.
App names come from the captured target application (frontmost app as fallback).
Selected text is read defensively through Accessibility. Surrounding text uses
the existing insertion snapshot's raw document text and UTF-16 selection range;
no extra document scrape is performed. Unavailable fields are omitted.

Selection and surrounding text are each capped at 2,000 Swift Characters, keeping
the start and truncating the tail. The surrounding window starts up to 1,000
UTF-16 units before the selection, rounded down to a Character boundary. With no
usable range it keeps the document start. App names are also capped at 2,000.
Context stays ephemeral and is never written to History or diagnostic logs.
Logs contain only field tokens, such as `context injected fields=app,selection`.

Only when an audio recheck actually runs is context added as a separate Japanese
background-disambiguation text part to generateContent. Nil context preserves the
previous request bytes. It never enters Gemini Live setup or the prewarm snapshot.
Existing recheck policy, admission rules and comparison behaviour still apply.
Read or network failures retain the original confirmed transcript as before.

The settings caption is: 「有効にした項目だけが、再チェック時にGeminiへ送られます。
録音そのものの送信先は変わりません。」

## Voice transform of selected text (R-05)

Assign 「選択テキストを音声で変換」 a shortcut. It uses the existing Carbon /
modifier monitor and toggle/hold/hybrid activation policy. The recording, transform,
translation and fix actions cannot share a binding. This repository previously
exposed only the recording shortcut;
Build 48 introduces ShortcutAction and reuses the same GlobalShortcut class for
its second action rather than introducing a separate hotkey implementation. Builds
51–52 extend that shared conflict checking to translation and fixing the last input.

Select text in another app, activate the shortcut and speak an instruction such
as 「要約して」 or 「英語にして」. Stop with the same shortcut behaviour as recording.
The existing dictation pipeline records a single instruction take, limited to
30 seconds. Its transform flag bypasses snippet expansion, both normal History
writes (including partial recovery), and normal transcript delivery. Neither the
instruction nor transformed output is saved in History. Audio admission and
review holds still prevent an uncertain instruction from running a transform.

Without a selection, status says 「変換するテキストを選択してください」 and no
recording starts. Selections above 2,000 Characters are rejected rather than
rewriting a larger selection from a truncated source. Missing API keys also
prevent recording. Selected text and the recognized instruction are sent only
when transforming, to Google's generateContent API with the existing key-header
authentication. The text-capable model is gemini-2.5-flash; the audio recheck keeps
its existing gemini-3.5-transcribe endpoint. A Japanese system instruction requests
only the rewritten text and treats the selection as data. Requests use ephemeral
sessions, reject redirects and cap response bodies at the existing 2 MB limit.

An empty, blocked, incomplete or failed response displays an error without
inserting anything. At delivery, both selected contents and the original target
must still match. TextInsertion performs its existing focus/selection/document
checks and verified delivery without modification. A changed or unverified target
causes the result to be copied to the clipboard with a notice; uncertain or partial
input is never retried automatically. Clipboard write failures display an error.
System interruption suppresses delivery. Pending transform targets are never
rebased after another take changes their original selection.

## Verification

Core cap, recheck-context and transform request/response tests are in both Swift
Testing and the portable SelfTest suite, registered with its runner. macOS testing
must still verify AX support across editors, secure-field rejection, shortcut
conflicts and all activation modes, stale target handling, clipboard fallback,
network failures and actual model acceptance of the request schemas. Swift and
interactive AX testing are unavailable in the headless implementation environment.
