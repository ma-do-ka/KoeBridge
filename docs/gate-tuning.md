# Build 41 speech-gate tuning

Build 40 headset measurements showed bimodal classifier scores: one genuine
speech take peaked at 0.452 (0/42 positive windows), while 25 neighbouring takes
peaked at 0.946 or higher. Recognition recovered 15 characters in the held take.
Lowering thresholds would not address this distribution, so speech verification
remains at 0.65 / 0.85 / two consecutive positive windows.

Admission now retains 1.0 second before the first confirmed speech window instead
of 0.25 seconds, clamped to the start of captured audio. Independent speech proof
is still required; the extra pre-roll protects soft first syllables. Pauses,
overflow handling, and unconfirmed non-silent recovery at stop are unchanged.

When acoustic review holds a non-empty recognized result, automatic input remains
blocked. The result is copied using the history copy helper and the overlay says
it was held and copied for three seconds. System-suppressed takes and takes with
automatic paste disabled are excluded. Other skips retain their existing feedback.
The status continues to show the delivery outcome detail.

With diagnostic consent, microphone evidence includes these transcript-free lines
in KoeBridge-mic.log:

- `speech_classifier`: adds `first_speech_ms` (or -1 if unavailable).
- `admission_opened capture=… first_speech_ms=… released_from_ms=… buffered_ms=…`:
  reports the actual sample-aligned release offset and pending duration at opening,
  including confirmation at stop. Invalid release geometry falls back to offset 0.
- `admission_recovered capture=… buffered_ms=…`: unconfirmed audio flushed at stop.
- `held_text_rescued take=… chars=… copied=1`: clipboard rescue with a short take ID.

Compare onset and release offsets to diagnose clipping, and classifier scores,
recovery events, and rescue counts to evaluate headset gate failures. No transcript
text is logged.
