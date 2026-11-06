# KoeBridge — lightweight native macOS dictation

[日本語 README](README.md)

KoeBridge is a **Swift-native, menu-bar dictation tool** for macOS 15+. Press your configured shortcut to record and press it again to finish. It attempts to type the recognized text into the original input field, with a ten-item local recovery history.

It supports **Gemini 3.5 Transcribe Live** (requires your own Gemini API key) and **Apple on-device speech recognition** (where supported). No Electron or always-on web server. Diagnostic file logging defaults to **OFF** and can be enabled in **Settings → 履歴と記録**.

**For Google AI Pro subscribers with unused Cloud credits:** This can be an interesting way to use API-eligible credits, but **Google AI Pro does not automatically mean unlimited or free Gemini API calls**. Check credit eligibility, your linked billing project, prepayment conditions, and actual usage in [Google AI Studio](https://aistudio.google.com/) and the [official billing documentation](https://ai.google.dev/gemini-api/docs/billing).

The supplied macOS app icon is packaged from `Resources/KoeBridge_AppIcon.icns` into the signed `.app` bundle; `Resources/KoeBridge_AppIcon_1024.png` is the corresponding source artwork. Finder and the settings brand header use the icon. The menu bar retains a monochrome waveform for legibility.

**v1.0.1 source release:** Accidental rapid, silent shortcut toggles now dismiss as a short, neutral "音声入力なし" notice rather than a transcription failure. Real speech and real hardware/API errors retain their existing paths. See [release notes](docs/releases/v1.0.1.md). There is no notarized installer.

## v1.1.0 — continuous dictation and independent assistance

[Download the universal development app](https://github.com/ma-do-ka/KoeBridge/releases/download/v1.1.0/KoeBridge-v1.1.0-macOS-universal-development.zip) for macOS 15+ (Apple Silicon and Intel). **Ad-hoc signed, not Developer ID signed or notarized.** Quit KoeBridge before replacing the app; macOS privacy permissions may need to be granted again. Source builds with an existing persistent certificate remain supported. See [release notes](docs/releases/v1.1.0.md).

Overlapping recordings now share only verified changes caused by the preceding automatic input; user focus and caret changes remain protected. Gemini Live uses explicit activity start/end around a recording, so a thinking pause does not itself send an end marker. Registered and developer vocabulary are separate checkboxes; neither checked means neither is sent. Additional local punctuation checks and optional audio re-recognition are independently selectable and default off. Audio rechecks cost an additional API request, have a bounded deadline, and retain lexical disagreements for review instead of silently replacing words or numbers. Apple recognition never invokes the cloud recheck.

The downloadable development app is built and tested in macOS CI. Actual microphone, Gemini service and target-editor behavior still require runtime verification on a user Mac.

## v1.0.1b agent-instruction mode

Choose **Settings → Gemini → 文字起こしスタイル → AIエージェント指示**. This uses the supported Gemini Live `VERBATIM` transcription. Registered terminology and the built-in developer glossary are used only when their respective assistance checkboxes are enabled. Unlike SMART, it prioritizes preserving repetitions, command syntax, file paths, URLs, technical terms, negations, and numeric constraints. It never sends unsupported system-instruction fields. The style itself does not request a second model; v1.1.0 audio review is a separate opt-in. Short line breaks may be added to history, but the safe auto-typing path replaces newlines with spaces to prevent accidental submission. Transcription accuracy and exact command spelling are not guaranteed.

That source release introduced **Settings → 一般 → ログイン時に自動起動** using the actual macOS login-item registration. For v1.0.1b, the internal macOS version was `1.0.1` (build 21), and the in-app release label was `1.0.1b`.

[Release notes](docs/releases/v1.0.1b.md).

## v1.0.1c — macOS Login Items registration

In **Settings → 一般 → 起動と常駐**, turning on **ログイン時に自動起動** now attempts to register the main KoeBridge app even when macOS returns `SMAppService.Status.notFound`. If macOS reports `requiresApproval`, the app opens the system Login Items settings for user approval. If macOS still cannot register the app, the UI clearly reports failure and offers to reveal KoeBridge.app in Finder for manual addition. This does not bypass consent, move the app, or register it until the user operates the toggle. User approval is not always required by macOS; registration may enable immediately. See [v1.0.1c notes](docs/releases/v1.0.1c.md).

## v1.0.1d — Update Center and actionable General settings

The menu bar has **Check for Updates…** and **Settings → 情報 → アップデート** shows official stable GitHub Releases, version status, the last successful check, and an optional daily automatic check. No executable is downloaded silently. Releases provide source archives and an explicitly labelled development app, but no Developer ID signed/notarized automatic-update package; automatic installation remains disabled. When a newer stable tag is found, a version-pinned, safety-checked source update command can be copied and run **after quitting KoeBridge**.

**Settings → 一般** now directly edits the recognition engine, shortcut, auto-typing, and Gemini transcription style, and shows permission/API key readiness without requiring multiple page jumps. Read the [v1.0.1d release notes](docs/releases/v1.0.1d.md).

## v1.0.1e — reliable update navigation

The menu-bar **アップデートを確認…** command directs the first opening of Settings to the actual Update Center. Subsequent selections refocus the Updates section, even when the Information page is already open. No installer is downloaded automatically. v1.0.1e was a source-only release; v1.1.0 adds the explicitly labelled manual development download above. See [v1.0.1e notes](docs/releases/v1.0.1e.md).

## v1.0.1f — menu-bar transcript submenu and copy confirmation

Hover over **認識履歴（直近10件）** in the KoeBridge menu-bar menu to open a native submenu with up to ten saved transcript previews, with dates and a marker for interrupted/partial results. Clicking a preview copies the **entire unchanged transcript** (not just the preview) to the system clipboard for **⌘V**, and shows a short non-activating success/failure banner. No automatic paste or new permission request is performed. The existing history window is still available via **履歴をすべて表示…**. See [release notes](docs/releases/v1.0.1f.md).

## Indicative Gemini API cost and local usage summary

For Gemini 3.5 Transcribe Live, the official paid-tier illustration is approximately **USD 0.009 per audio minute** including typical text output. At an *assumed* USD/JPY rate of 158, this is roughly JPY 1.42 per minute, **before free tiers or credits**. This is not a real invoice.

Run **python3 scripts/estimate_usage_cost.py --days 30 --usd-jpy 158** from your KoeBridge checkout to summarize locally recorded audio usage. The tool only reads aggregated usage metadata; it does not read transcripts, audio, diagnostic logs, or API keys. See [pricing assumptions and limitations](docs/cost-estimate.md).

## Run from source on a Mac

```bash
cd KoeBridge
bash scripts/verify_and_build.sh --open
```

The build requires Swift/Xcode tools and a stable code-signing identity. For local development only, `KOEBRIDGE_ALLOW_ADHOC=1 bash scripts/verify_and_build.sh --open` allows ad-hoc signing, which may cause macOS privacy permissions to be requested again.

Add the API key in **Settings → Gemini**. macOS Keychain holds the key; it is not included in this repository. Allow microphone, Accessibility and keyboard event posting when requested. Apple local mode does not need a Gemini API key. Some editors reject synthesized key events.

**MIT license**: fork, modify and redistribute with attribution/license notice. This is an independent community project, not affiliated with Google or Apple. **macOS runtime testing is still required**; see [TEST_REPORT.md](TEST_REPORT.md).
