# Bluetooth microphone startup recovery — implementation candidate

2026-11-08. Base: `a986a8c695d8fa3fa35c909a34f3976441e750a9`.

## Status

Source implementation and portable tests are complete for the changes below. This is **not a verified macOS release**. No version metadata, release notes, update feed, workflows, or distribution archives are changed. The base already identifies itself as v1.1.4 / Build 31; this change neither increments nor downgrades it.

Reported device: Shokz OpenComm2, Bluetooth connection. Reported symptoms: the first microphone start fails and repeated key presses eventually work; dictation is unreliable while video is playing. Hardware root cause is not confirmed by a device trace. Video-app pause/resume and speaker identification are **not implemented**; do not claim this resolves video sound leaking into the microphone.

## Changes

| Location | Type | Change |
|---|---|---|
| `Sources/KoeBridge/MicrophoneCapture.swift` | Partial replacement | Wait for live, converted PCM; validate formats; monitor interruptions; timestamp at tap arrival; join asynchronous stop receipts; retain interruption evidence through stop. |
| `Sources/KoeBridge/VoiceController.swift`, `startPrepared` | Partial replacement | Own the microphone during preparation; up to four attempts within a ten-second application budget; wait for teardown before retry; start the recognition worker only after a successful attempt, and never from a cancelled take. |
| `Sources/KoeBridge/PreviewView.swift` | Partial replacement | Show the existing progress indicator during preparation. No new controls. |
| `Sources/KoeBridge/MicrophoneRouteSnapshot.swift` | New | Read-only Core Audio input/output transport snapshot. |
| `Sources/KoeBridgeCore/MicrophoneStartupGate.swift` | New | Thread-safe readiness/retry policy and shared asynchronous stop completion latch. |
| `Tests/KoeBridgeCoreTests/MicrophoneStartupGateTests.swift` | New | 67 portable state, timing, cancellation, concurrency, and stop-receipt tests. |

The full before/after change is the Git diff. Changes outside these areas are not required. Swift sources are UTF-8. macOS-only sources pass syntax parsing with their OS guards removed; macOS SDK type checking and UI rendering remain unverified.

## Behaviour and safety

- `engine.start()` returning is not readiness. At least two nonempty converted buffers must span the stability window (default 150 ms), with fresh arrivals and a running engine. Silent PCM is accepted: speaking is not required to start a microphone.
- Failed preparation does not send its pre-roll to either recognizer or the speech classifier. A successful attempt preserves its pre-roll. Converter, engine and readiness state belong to one attempt; late callbacks from an old attempt cannot resolve a new one.
- Maximum four total attempts, with 200/400/600 ms backoff, 2.5 seconds per attempt and ten seconds of application-side budget. Synchronous OS/driver calls cannot be force-interrupted by that budget.
- Changing the input format or route, or losing live PCM, is not interpreted as silence. After recording starts, an interruption ends the take rather than silently inserting a potentially incomplete transcript. Automatic mid-recording reconstruction is deliberately not attempted because missing words cannot be recovered reliably.
- Interruption state survives a simultaneous user stop even when the UI no longer accepts the queued device-change callback. The final capture receipt reports a failure to the existing no-auto-delivery path.
- Buffered audio retains its tap-arrival time; processing backlog cannot masquerade as a fresh microphone stream.
- Multiple stop/cancel callers join the same asynchronous classifier/admission finalization. No second caller receives an early success receipt. Callbacks run outside the latch lock and exactly once.
- No always-on microphone, media-key toggle, private media-control API, volume write, default-device write, or new OS permission is introduced. Existing opt-in logging and text-insertion safeguards remain in force.

## User-visible text

The existing `マイクを準備しています…` remains. Retries use the existing status field: `マイクの接続準備を待っています…（2/4）` (actual attempt number). The old `録音中にマイク構成が変わりました` becomes `マイク入力が変更または中断されたため録音を終了しました`. The preparation progress indicator has the accessibility label `マイクの接続準備中` in the existing 38-by-38 icon area. Invalid input, no PCM and unstable transition errors have distinct descriptions in `CaptureError`.

## Validation actually performed

- Swift 6.2.1 on Linux: **67 tests passed** (49 readiness/retry tests, 9 interruption/freshness regressions, 9 stop-latch tests).
- Source application/safety: **10 tests passed** using exact pinned originals, including the complete 904-line `VoiceController.swift`, verified against its Git blob SHA. These cover dry-run, conflicts, backup, rollback, concurrent edits and symlink refusal. This is source application, not execution of the macOS application.
- All four modified/new macOS Swift files pass syntax parsing in Swift 5 language mode, with OS guards removed to avoid a vacuous Linux parse. This is **not** SDK type checking or linking.
- Two negative controls deliberately reintroduced lost interruption evidence and early stop completion; the regression tests failed on behavioural assertions, then the restored source passed all 67 tests.
- No GitHub Actions, paid APIs, actual microphone recording, release packaging or installation was used for these checks.

## Required Mac verification before merge/release

Run the existing full test suite, self-test executable and release build on a Mac, without GitHub Actions. Confirm the actual running app path/version before replacement; preserve unrelated local changes. Test first connection, idle headset, wake from sleep, preparing cancellation, rapid stop/start, unplug/disconnect, and video playback already active and starting during preparation. Test Apple and Gemini only under existing usage permissions. Confirm silent PCM reaches ready, truncation never automatically inserts text, and the microphone is released after every exit. Do not publish a release or label the reported hardware symptoms resolved until those checks pass.

For playback interference, first identify the actual player and supported pause-state API. Do not send a blind play/pause toggle, enable browser automation permissions silently, or resume media that KoeBridge did not pause. Acoustic leakage and Bluetooth profile transition are different problems.

## Public API references

Apple documents that input/output sample-rate or channel-count changes stop and uninitialize AVAudioEngine (`AVAudioEngineConfigurationChange`). Apple also documents the Bluetooth playback-versus-microphone audio-mode transition. These explain the recovery design, not a confirmed diagnosis for this device.

- https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange
- https://developer.apple.com/documentation/avfaudio/avaudioengine/inputnode
- https://support.apple.com/en-us/102217
