# Learning vocabulary and fixing the last input (Build 52)

Learning is explicit confirmation only. In History, choose 「修正して学習」,
copy/select the nearby original text, enter an erroneous fragment and its corrected
term, then choose 「語彙に学習する」. Both fields must be nonempty, the fragment
must occur literally in the record, and the corrected form must have at most
60 characters. Confirmation does not alter the History record. Relearning a
normalized term updates its fragment and record provenance while preserving its
identity and creation date. No automatic replacements or correction monitoring run.

LearnedTerm records are JSON in UserDefaults `learnedTerms`, separate from the
user vocabulary editor. Settings lists their count, corrected forms, original
fragments, edit/delete controls, and an empty state. Recognition hint ordering is
explicit user terms → learned terms → built-in topic terms. All share trimming,
case/diacritic-insensitive dedupe, and a maximum of 100 hints. Learned terms never
displace explicit user terms. The registered-vocabulary toggle controls both user
and learned terms; the topic toggle controls built-ins. Existing app-profile
additional vocabulary still takes precedence through the existing profile merge.
Prewarming uses the same learned vocabulary as take creation. Hints bias recognition;
they do not force spelling.

The fourth shortcut 「直前の入力を修正」 defaults to unbound. All four bindings
participate in conflict checks. A fix press is a single invocation, independent
of recording activation mode. It starts a spoken instruction take using the
Build 48 transform machinery; use the recording key to finish the instruction.
Further fix presses during pending work are ignored.

An in-memory LastDeliveryAnchor stores only the latest verified ordinary delivery:
field identity, before/after numeric snapshots, the actual sanitized submitted
text, optional History ID, and delivery time. Unconfirmed `.inserted` event posting
never establishes an anchor. A newer delivery clears it, starting a take in a
different application clears it, and use after ten minutes clears it lazily.
Manual transform, translate, and preset-chain deliveries invalidate an old anchor
but do not establish one in this build. A verified fix replacement establishes a
new anchor from its receipt so fixes can chain; a missing/unconfirmed receipt
clears it rather than inferring success.

At invocation, the same frontmost AX field must have exactly the after-snapshot
text and caret (UTF-16 exact comparison). The delivered span starts at the
before-selection location and has the submitted text's UTF-16 length. The app
writes `kAXSelectedTextRangeAttribute`, then reads the numeric range and full value
back, verifies focus and exact selected text, and records that selection as the
transform target. Unsupported/opaque ranges fail closed. Before replacement, fix
checks focus, the full selection snapshot, and selected text again; the existing
insertion preflight and verified receipt path also apply. Manual-selection
transforms retain their Build 48/51 behavior. Fix instructions send the complete
anchored span (bounded by receipt snapshot observability), bypassing the manual
transform context truncation so a long delivery is never silently shortened. AX operations cannot be atomic
against simultaneous edits in a host app.

Failure statuses:
- No anchor or expired: 「修正できる直前の入力がありません」.
- Target, value, caret, selection-write/read-back mismatch:
  「入力後に変更されているため修正できません」. Select text manually and use
  the transform key instead.
- API/recognition/delivery failures use the existing transform feedback and
  clipboard fallback. Successful fixes offer no extra learning prompt.

Deferred: passive learning/post-delivery monitoring, one-level undo, and anchors
for manual transform/translate/chain deliveries. Build 55 adds independently opt-in
retained-audio re-recognition in History; see [meeting and retention](meeting-and-retention.md).
No audio is retained for fixing; the instruction is a new recording. Anchor
snapshots are memory-only and not added to the History archive.
