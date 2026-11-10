# LLM post-processing (Build 49)

Normal dictation follows recognition → final confirmed transcript → review session →
optional LLM post-processing → snippet expansion → frozen ordered delivery and History.
The original recognizer recovery/partial text remains untouched.

The Gemini settings page, alongside transcription style, has an independent
「LLM後処理」 master switch (default off) and mode picker. Preferences are
`postProcessEnabled` (false) and `postProcessMode` (`tidy`). Turning the switch
off disables the stage without changing the selected mode. Preferences are
captured when each take begins.

- Off: no post-processing.
- Tidy / 整える: remove hesitations and repetition, adjust punctuation; preserve meaning, vocabulary and style.
- Formal / 丁寧に整える: rewrite in polite, polished language while preserving meaning.

Both Gemini and Apple final transcripts are supported, independently of recognition
style. Agent style bypasses the stage because it already shapes output end-to-end.
Transform takes, save-only, suppressed, review-held, stale and no-input takes bypass
it as well. Snippets expand after post-processing so templates see final wording.

A Gemini API key is required. The text-only gemini-2.5-flash generateContent call
shares the transform endpoint and strict response parser (including newline-only
trimming, preserving spaces/tabs). Empty output, missing keys, invalid responses,
network errors and timeouts retain the original confirmed transcript. Diagnostic
logs contain mode and token counts, never transcript text.

The request uses the existing review deadline budget: at most six seconds, within
the fifteen-second finalization watchdog, with a quarter-second reserve. Both
URLSession request and resource timeouts use that budget. While awaiting the
request, the watchdog retains the pre-process confirmed text and resolves with it
on expiry; resource release cancels the stage and late callbacks cannot replace it.
The delivery and History store the processed text after snippet expansion.
