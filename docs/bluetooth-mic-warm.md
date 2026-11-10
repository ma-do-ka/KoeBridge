# Bluetooth microphone keep-warm (Build 47)

The microphone settings toggle 「Bluetoothマイクの接続を温めておく」 defaults
OFF and is saved as `bluetoothMicWarm`. When enabled, microphone permission
must already be granted. Warming never opens a permission prompt. The selected
input must resolve to a Bluetooth transport (`blth` or `blea`). Selection uses
the same device store and selection policy as dictation, including following
the system default and refusing fallback for a missing explicit device.

Between takes the warmer exclusively leases the same process-retained
AVAudioEngine used by MicrophoneCapture, binds the input, and installs an empty
tap. Audio buffers are discarded immediately in that tap. They are never read,
copied, converted, analysed, recorded, saved, or transmitted by the warmer.
Keeping the audio route open lights the macOS microphone-use indicator and may
keep the headset in its voice audio mode. This is the opt-in trade-off for
reducing Bluetooth route negotiation at recording startup.

Before every capture attempt, suspend is enqueued on the capture lifecycle
queue ahead of capture start. It stops the engine, removes the warm tap, and
releases the warm lease. Capture then uses its existing start, readiness,
admission, conversion, and stop paths unchanged. No warm lease spans a take.
The engine remains retained for process lifetime. The handoff necessarily
stops/restarts it because capture requires a stopped engine; real Bluetooth
hardware must confirm how much startup latency this saves.

Resume re-evaluates selection and policy at launch after store setup, after
microphone teardown (including cancellation/failure), on toggle changes, on
store publications (including the existing two-second settings-page refresh),
and on warm-engine configuration changes. There is no new idle polling cadence.
A new active take prevents warming even if an older take has just torn down.
Permission is rechecked on each resume. Device/bind/start failures silently stay
cold and cannot turn into a take error. Diagnostics contain only `mic warm
start` / `mic warm stop` and plain reason tokens, never device names or UIDs.

The two policy test suites cover all eight Boolean input combinations. macOS
compilation and physical Bluetooth checks are required separately: verify cold
opt-out, opt-in indicator and latency, repeated takes, rapid cancellation and
restart, default/explicit device changes, unplug/reconnect, permissions, and
silent failure recovery. No Swift toolchain or Bluetooth hardware is available
in the implementation VM.
