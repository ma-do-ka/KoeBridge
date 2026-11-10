# Progressive recording preview (Build 53)

「確定した部分をプレビューで区別する」 is enabled by default and persisted as
`progressivePreviewEnabled`. In Settings → General → 録音プレビュー, turn it off
to restore the previous single-style preview.

Normal, darker text is recognizer-final; secondary, lighter text is provisional
and may still change. Recognizer-final does **not** mean approved for insertion.
Both parts remain subject to the existing acoustic preview policy: when preview
is not permitted, neither part is shown. The existing three-line, 180-character
preview window remains in place. Provider boundaries are preserved; the app does
not infer sentences or finality from pauses or unchanged words.

- macOS 26 SpeechAnalyzer: finalized segments append to the stable prefix; each
  volatile result replaces only the provisional tail. Stability updates are sent
  even if the combined text is unchanged.
- macOS 15+ SFSpeech fallback: the entire cumulative hypothesis stays provisional
  until the recognition request reports its final result.
- Gemini: the existing TranscriptAssembler finals form the stable prefix, while
  its interim tail stays provisional. Existing spacing and conflict handling are
  preserved.

Document insertion still happens once, for the whole take, after stopping and
completing the existing acoustic checks, recognition finalization, review and
processing pipeline. History, usage, snippets and delivery ordering remain per
take. Preview styling neither reduces insertion latency nor extends recording
limits.

## Why document streaming is deferred

The acoustic decision is final only at stop. Later classifier failures, invalid
audio, conflicting Gemini finals or audio recheck disagreements can still hold
the whole take. Recognizer-final segments and several clean seconds cannot
justify inserting an early prefix without weakening that whole-take hold
contract. A timeout or failed finalization must still preserve recovery text
rather than insert a provisional hypothesis.

Sentence-sized child takes are a **future product decision**, not part of this
build. They would change the unit of admission and review: a later failure could
no longer hold the original whole dictation. Such a design also needs aligned
segment audio and review, same-take receipt chaining, uncertain-submission
recovery, focus/edit handling, undo semantics and bounded recording lifecycle
work. This preview does not implement any of those streaming delivery changes.
