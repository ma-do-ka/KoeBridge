# Meeting mode and retained audio — Build 55

Both features default **OFF**, independently: `meetingModeEnabled` and
`retainAudioEnabled`. Enable them in Settings → History/privacy. Enabling one
does not enable the other. Normal dictation admission thresholds, microphone
capture, and delivery rules are unchanged.

## Meeting mode

Enable meeting mode to request Screen Recording permission. The app never requests
that permission at launch or for dictation, replay, or retention. The settings row
shows its current state, requests permission, or opens macOS Privacy & Security →
Screen Recording. Refresh after changing permission; macOS may require a restart.
Only when enabled and permitted does the popover's 「会議モードを開始」 become
available. 「会議モードを停止」 remains available while stopping or after revocation.
Microphone permission is also required; Apple may request Speech authorization or
download on-device models. Recording and pending dictation must finish before a
meeting starts; normal dictation is refused until the meeting finishes saving.

`SystemAudioCapture` uses a display-based ScreenCaptureKit audio output, with
`capturesAudio` and `excludesCurrentProcessAudio`. It requests no screen-frame
output and saves no screen images. Other applications' system audio is included,
not just a conferencing app. The actual incoming format is converted using
AVAudioConverter to mono 16 kHz Float32 and then PCM16 little endian. It has its
own NativeSpeechDetector, SpeechAdmissionBuffer, activity meter and bounded queue.
Microphone audio uses the existing MicrophoneCapture path and its independent
classifier/admission state. Audio is never mixed across sources.

`MeetingSession` snapshots the chosen engine, vocabulary, style and language hint.
Apple uses two local recognizers; Gemini uses **two Live sessions**, with usage
for both sources, sending both sources' admitted audio to Google. Source pipelines
roll over independently and sequentially at the existing **50 s Apple / 480 s
Gemini** capture limits. Each capture stops and drains its classifier/admission
buffer, its recognizer finalizes, and only then does that source start a new
chunk. There is no overlap. Preparation/finalization creates recording gaps;
boundaries may cut mid-sentence. This is bounded chunk recording, not continuous
sentence-aligned recording. Capture loss or recognition failure is annotated;
it is never silently promoted to a complete result.

Segments use the same monotonic session origin, with leading admission trim
included in their start offsets. Blocks sort by source capture time rather than
recognition completion time. Live status shows 「会議モード中」, elapsed time and
separate microphone/system activity evidence. Energy without independent speech
evidence is shown as unconfirmed activity.

Labels are **source labels only**: 「自分［マイク］」 and 「相手［システム音声］」.
They do not identify individual speakers. 相手 may include multiple people,
notifications or media; the microphone may include nearby people or speaker bleed.
Headphones are recommended. Explain recording to participants and obtain consent.
If system capture fails or permission is revoked, the microphone continues and the
record says 「システム音声は途中で停止しました」. Microphone failure ends the
session and saves available partial text. Recognition errors are also annotated.
Sleep, user switching and shutdown cancel replay and synchronously save any available
meeting transcript as a single annotated partial record, without waiting for final
recognition or continuing uploads. Update installation treats meetings/replay as
pending work. Force termination or a crash before Stop/interruption can still lose
the in-memory meeting; continuous checkpointing is not implemented.

Stop creates **one** History record, marked `kind = "meeting"`, using the session
engine. The existing `.automaticPasteDisabled` delivery value represents saved-only
success; History displays a meeting-specific saved caption rather than suggesting
delivery failure or that the global paste setting changed. A meeting never captures
an insertion target, enters ordered delivery, pastes, or auto-types. Review,
post-processing, commands and snippets from ordinary dictation are not run on it.
Meeting records have **no retained audio**, even when retention is enabled.

## Retention and deletion

Only normal dictation takes which actually create a text History record can save
audio, including held or interrupted results. At take creation the app snapshots
retention consent and its deletion generation. A later opt-in cannot retain a take
started without consent. Opt-out or 「保存音声をすべて削除」 invalidates pending
consent, preventing a late result from restoring deleted audio (even after a quick
re-enable). No-record takes, command takes and transform/fix instructions save none.

The retained bytes are **audioBackup: the admitted recognition-input audio**,
not necessarily the complete wall-clock recording. Leading silence may have been
trimmed by admission. Format: mono / 16,000 Hz / signed PCM16 little endian,
**32,000 PCM bytes per second**, wrapped in a canonical 44-byte WAV header.
`PCM16WAV` is shared by GeminiRecheckWire and retention/replay. Extraction checks
all header fields and exact lengths and returns precisely the original PCM.
WAV headers are never fed to Apple or wrapped twice for Gemini.

Files are `~/Library/Application Support/KoeBridge/RetainedAudio/<recordUUID>.wav`.
Directory permissions are 0700 and files 0600, matching the History archive.
The existing archive does not set backup-exclusion resource values; retained audio
follows that pattern. API keys and PCM are never embedded in History JSON or logs.
History stores an optional asset reference, byte count, recording and expiry dates.
Old archives decode with no asset, no kind and an empty retranscription list.

Bounds are **7 days from recording**, **250,000,000 total WAV bytes**, and
**14,000,000 PCM bytes per record**. A larger take is simply not retained; there is
no truncation or segmentation. Expiry is not extended by replay. The main-actor
store sweeps at launch, after writes, before replay and after archive mutations:
expired assets first, then oldest recordings until under quota. Record deletion,
clear-all and the archive's 500-record eviction reconcile files too. Launch removes
orphan files and clears references to missing files, showing the reason in History.
Expiry while the app is closed is enforced at next launch. Settings shows actual
bytes, file count, cap and period. Opt-out removes all files and references.
Filesystem failures are logged without audio/text and never fail a dictation or
its text record. Deletion failures can leave files until a subsequent successful
sweep; the status counts actual remaining files.

## Replay from History

Records with an asset offer 「音声から再文字起こし」 with progress and cancel:

- **Apple**: on-device through LocalTranscriberFactory, using
  start → appendPCM16 in 3,200-byte chunks → endAudioAndAwaitFinal.
  More than **50 seconds / 1,600,000 PCM bytes** is refused with a visible reason.
  The on-device model may need installation; no cloud recheck/post-processing runs.
- **Gemini**: needs the current API key; GeminiAudioRechecker receives extracted
  PCM and **current** registered/learned/topic vocabulary according to current
  vocabulary switches. Audio and vocabulary are sent to Google; historical
  context is not sent. The History engine choice explicitly shows this disclosure.

Results append to `retranscriptions` with engine, date and a copy action. Original
text, review alternative and delivery status remain unchanged. Nothing is pasted
or automatically replaced. Deleting the record, clearing History/audio, or opting
out cancels active replay and rejects late results. Files which expire or vanish
before replay lose their asset reference and show the reason; text remains.

## Deferred and verification

Deferred: meeting audio retention, segmented retention, automatic meeting detection,
true participant diarization, echo cancellation and participant naming. The
non-streaming Gemini transcribe endpoint documents diarization, but it is
incompatible with custom vocabulary; v1 does not enable it.

Swift Testing and portable SelfTest cover WAV byte-exact round trips, malformed
headers, the 14 MB boundary, backward decoding, append-only results and ordering
of source-labeled segments. macOS app tests cover file permissions, quota/expiry,
orphans, missing/corrupt files, write failure, oversize rejection, clear and record
deletion. Run `swift test` and `swift run KoeBridgeSelfTest` on a Swift-equipped
Mac. Build 55 was implemented on a VM without Swift; those tests and framework
compilation have not been run here. Live dual Apple recognition, ScreenCaptureKit
conversion/API availability, permission denial/revocation, long-session rollover,
stop during preparation, queue loss and real Google requests require macOS checks.

Apple references: [ScreenCaptureKit setup and usage string](https://developer.apple.com/documentation/screencapturekit),
[stream audio configuration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration),
[PCM buffer copying](https://developer.apple.com/documentation/coremedia/cmsamplebuffercopypcmdataintoaudiobufferlist(_:at:framecount:into:)).
