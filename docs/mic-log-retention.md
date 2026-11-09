# Microphone evidence retention (Build 39)

On the user's Mac on 2026-11-09, Build 38 retained only about 11 minutes
of active use (five takes) in two 192 KiB generations. In that measured window,
mic_start breadcrumbs accounted for 65% (148 KB), input_diag 21%, input_summary
5%, and mic_prepare_* less than 5%. Evidence averaged about 45 KB per take.
Older microphone failures rotated away before investigation.

Build 39 keeps the main log at 256 KiB × 3 generations (768 KiB total) and
mirrors microphone evidence into `~/Library/Logs/KoeBridge-mic.log` at
256 KiB × 8 generations (2 MiB total). Current files count as one generation;
older files use `.1` through `.2` for main and `.1` through `.7` for microphone.
The target is days of typical use and 60+ takes; actual retention depends on
recorded byte volume and must be measured on macOS.

The mirror receives existing mic_start breadcrumbs, mic_prepare_* events,
speech classifier results, microphone interruptions, startup/stopped summaries,
and audio activity summaries. Their text and the capture/recognition behavior
are unchanged. Input diagnostics remain in the main log. DiagnosticFileStore's
default limits remain 192 KiB × 2 for compatibility; the app selects presets.

## Privacy and deletion

Both stores share the single `diagnosticsEnabled` opt-in, which defaults to OFF.
Microphone traces use the same consent token and revocation checks as input
traces. OFF/ON transitions and deletion invalidate buffered evidence; old traces
cannot write after revocation. There is no second consent setting.

Only the existing sanitized diagnostic event strings are mirrored: no transcript,
audio, API keys, device names or device UIDs. Both stores enforce 0600 permissions,
reject symlink/nonregular destinations, and clean oversized generations. No
automatic upload is added. Turning logging OFF leaves existing files in place;
the existing “動作記録を削除” action removes both stores and all their generations.

## Collecting a microphone investigation

1. Enable **設定 → 履歴と記録 → 問題調査用の記録を残す** before reproducing.
2. Reproduce normally and note the approximate failure time and operation order.
3. Open `~/Library/Logs/` in Finder and copy `KoeBridge.log`, its existing `.1`
   and `.2`, plus `KoeBridge-mic.log` and all existing `.1` through `.7`.
4. Share only with the investigator who needs them, without publishing logs in
   a public issue without permission. Turn logging OFF when finished; use the
   existing deletion action when the retained files are no longer needed.

## Verification still required

No Swift toolchain is available in the implementation environment. Swift tests
have not been run here. macOS verification is still required: compile and run
both test suites, reproduce microphone startup evidence in both files, check
rotation and permissions, test OFF/ON and deletion while traces are pending,
and measure the retained take window under typical use. This change does not
claim to fix microphone failures or guarantee a number of days of retention.
