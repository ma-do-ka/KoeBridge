# Menu-bar popover (build 42)

Left-click the waveform status item to toggle the SwiftUI popover. While recording,
its symbol becomes record.circle. Right-click or Control-click opens a small native
menu containing Settings, Check for Updates, and Quit. The delegate presents this
with NSMenu.popUp anchored to the status button; no persistent status-item menu or
recursive performClick is needed.

A transient popover closes on the status button's mouseDown, before the button's
mouseUp action runs, so the delegate records popoverDidClose and ignores a show
request within 200 ms of a close — otherwise the click that closed the popover
would immediately reopen it instead of toggling it shut.

The transient, animated NSPopover is reused and shown only with
show(relativeTo:of:preferredEdge:) on the status button. Opening it never explicitly
activates the app. Recording, finalizing, discarding, and copying first close the
popover, then wait 100 ms on MainActor before calling existing controller actions.
This gives the original editor a chance to retain focus before insertion-target
capture. Copy uses the exact stored record and the existing no-focus clipboard HUD;
it does not type text. Window actions close the popover before opening the existing
windows. The two engine buttons set requestedMode directly and display its label;
selection does not start recognition.

Today's usage and the zero-filled seven-day bars come from the controller's existing
monitorEvents through the Foundation-only UsageSummary helper. Calendar day buckets
use the current calendar and time zone. Each primary engine sample counts as an
attempt, including success, failure, and cancellation, matching the monitor's sample
count convention. Optional audioRecheck samples are excluded. Audio minutes sum
Gemini and Apple PCM durations (including silence); Gemini fallback and Apple samples
remain separate attempts as recorded. No usage recording or storage is changed.

Estimated cost uses Gemini primary seconds / 60 × $0.009/minute: Google's published
blended estimate for gemini-3.5-transcribe-live audio input plus text output. This is
an estimate only, not token billing, an invoice, or a price for optional rechecks.
Apple seconds do not contribute to the estimate. The cost is displayed to two decimal
places, and audio minutes to zero decimal places. With no events the chart shows an
empty-state message.

On a Mac, verify left/right/Control-click, light and dark appearance, disclosure
resizing, engine selection, permissions, window actions, and clipboard feedback.
Especially verify that opening and closing the popover preserves the original text
field and caret, and that starting/finalizing dictation inserts into that field after
the close-then-act delay. These AppKit behaviors require a running macOS application.
