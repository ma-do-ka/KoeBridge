# Gemini connection preparation

Build 45 prepares one Gemini Live connection in advance by default. The Gemini
settings toggle can disable preparation immediately. Switching to Apple also
cancels preparation. A warm connection completes setup and maintains its socket;
it never sends audio or starts a speech activity before recording. No audio
leaves the Mac before recording.

Preparation starts after controller setup when Gemini is selected and a key is
available, and after a take completes and releases its resources, provided
no take is active. Idle changes to vocabulary, vocabulary assistance, style,
Japanese preference, engine, or API key also refresh preparation. All preparation
triggers are debounced by 600 milliseconds and use the current settings.

A prepared connection is discarded after five minutes. Adoption independently
requires an age of at least zero and strictly less than 300 seconds, exact matching
vocabulary (including order), transcription style, Japanese hint, and API key
fingerprint, plus a healthy connection. Missing, expired, mismatched, failed, or
unfinished preparation uses the existing cold connect/setup path without waiting
for preparation. There is no background retry loop after a warm failure or expiry;
the next normal trigger can prepare again.

The fingerprint combines the key's UTF-8 byte count with a stable local FNV-1a
hash. It is compared only in memory, never logged or persisted. Preparation
success/failure and adoption hit/miss diagnostics contain no transcript or key
material. The recording take owns an adopted connection and drives audio,
finalization, and cancellation through the same lifecycle as a cold connection.
