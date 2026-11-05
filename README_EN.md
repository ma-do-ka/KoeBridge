# KoeBridge — lightweight native macOS dictation

[日本語 README](README.md)

KoeBridge is a **Swift-native, menu-bar dictation tool** for macOS 15+. Press your configured shortcut to record and press it again to finish. It attempts to type the recognized text into the original input field, with a ten-item local recovery history.

It supports **Gemini 3.5 Transcribe Live** (requires your own Gemini API key) and **Apple on-device speech recognition** (where supported). No Electron or always-on web server. Diagnostic file logging defaults to **OFF** and can be enabled in **Settings → 履歴・診断**.

**For Google AI Pro subscribers with unused Cloud credits:** This can be an interesting way to use API-eligible credits, but **Google AI Pro does not automatically mean unlimited or free Gemini API calls**. Check credit eligibility, your linked billing project, prepayment conditions, and actual usage in [Google AI Studio](https://aistudio.google.com/) and the [official billing documentation](https://ai.google.dev/gemini-api/docs/billing).

The supplied macOS app icon is packaged from `Resources/KoeBridge_AppIcon.icns` into the signed `.app` bundle; `Resources/KoeBridge_AppIcon_1024.png` is the corresponding source artwork. Finder and the settings brand header use the icon. The menu bar retains a monochrome waveform for legibility.

## Run from source on a Mac

```bash
cd KoeBridge
bash scripts/verify_and_build.sh --open
```

The build requires Swift/Xcode tools and a stable code-signing identity. For local development only, `KOEBRIDGE_ALLOW_ADHOC=1 bash scripts/verify_and_build.sh --open` allows ad-hoc signing, which may cause macOS privacy permissions to be requested again.

Add the API key in **Settings → Gemini**. macOS Keychain holds the key; it is not included in this repository. Allow microphone, Accessibility and keyboard event posting when requested. Apple local mode does not need a Gemini API key. Some editors reject synthesized key events.

**MIT license**: fork, modify and redistribute with attribution/license notice. This is an independent community project, not affiliated with Google or Apple. **macOS runtime testing is still required**; see [TEST_REPORT.md](TEST_REPORT.md).
