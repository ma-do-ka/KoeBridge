# Developer Diagnostics

KoeBridge 2.0 preparation uses an explicit, local-only developer diagnostics mode for real-device investigation. It is **OFF by default** and is separate from ordinary `~/Library/Logs/KoeBridge.log`.

## Where the control exists

The control is intentionally collapsed at the bottom of:

`設定 → 情報 → 開発者向け → 開発用診断を表示`

Turning it ON requires a confirmation that audio samples and recognized text will be stored locally. Turning it OFF invalidates the current diagnostics token immediately and starts deletion of the developer diagnostics directory.

## Storage

All developer-diagnostics artifacts, including temporary encoded audio, are kept under:

`~/Library/Application Support/KoeBridge/DeveloperDiagnostics/`

Typical layout:

- `global.jsonl` — content-free lifecycle breadcrumbs.
- `sessions/<take-id>/timeline.jsonl` — detailed timing and microphone stages.
- `sessions/<take-id>/input-trace.log` — bounded input/focus/receipt evidence.
- `sessions/<take-id>/recognition.json` — raw confirmed recognition, final processed text, recoverable partial text and optional comparison result.
- `sessions/<take-id>/delivery.json` — outgoing sanitized transport text and, when observable, the receiving field's changed segment.
- `sessions/<take-id>/audio.m4a` — optional short audio sample encoded from the same 16 kHz mono PCM prefix submitted to the recognizer.
- `.tmp/` — transient audio encoding files; this directory is inside DeveloperDiagnostics so OFF/deletion also removes temporary data.

No developer-diagnostics file is uploaded automatically.

## Audio and disk limits

- Audio source: recognizer-submitted 16 kHz / mono / signed 16-bit PCM.
- Stored prefix: at most 20 seconds per recording.
- Encoding request: AAC in M4A, mono 16 kHz, 24 kbps, low encoder quality.
- Encoded audio hard limit: 96 KiB. If encoding exceeds it, audio is omitted.
- Text field cap: 16 KiB UTF-8 per stored text value.
- Timeline: 64 KiB per recording.
- Input trace: 160 KiB per recording.
- Recognition JSON: 96 KiB per recording.
- Delivery JSON: 64 KiB per recording.
- Session hard cap: 512 KiB.
- Retention count: at most 30 recording sessions.
- Total DeveloperDiagnostics cap: 8 MiB; oldest sessions are removed first.
- Global developer log: 256 KiB.

If an individual session unexpectedly exceeds 512 KiB, optional evidence is removed in this order: audio, input trace, timeline. If the session is still oversized, the session is deleted rather than retained beyond the advertised limit.

## Deletion and consent revocation

OFF does two things:

1. The stored diagnostics epoch is invalidated synchronously so already-running async work can no longer publish results.
2. The DeveloperDiagnostics directory is deleted asynchronously.

If deletion fails, the UI reports the failure. On the next app launch, when developer diagnostics is OFF, KoeBridge attempts to remove any stale DeveloperDiagnostics directory left by a prior crash or interrupted deletion.

The **診断データを削除** button rotates the epoch before deletion. Active recordings that began before that deletion cannot repopulate the deleted data.

Ordinary transcript history, usage statistics, settings, `KoeBridge.log`, and macOS crash logs are not deleted by these controls.

## Privacy boundary

Ordinary diagnostics remain content-free. Recognized text and audio are allowed only inside this explicit developer mode.

Never store:
- Gemini API keys or other credentials.
- Full input-field baseline text as a diagnostic artifact.
- Browser URLs or window titles.
- Any automatic cloud upload of developer diagnostics.

The receiving application's text is reduced to the observed changed segment when a comparison is possible; the full baseline field is not persisted.

## Sharing for investigation

For a specific failure, share the corresponding `sessions/<take-id>/` directory and, when startup routing is involved, `global.jsonl`. The recording timestamp in `recognition.json` can be used to match a session to the reproduction.

Before sharing, the developer should still inspect the files because developer mode intentionally contains short audio and recognized text.
