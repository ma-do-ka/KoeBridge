#!/usr/bin/env bash
# Read-only diagnostics. Does not change permissions, pasteboard or API keys.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
printf 'KoeBridge diagnostics (read-only)\n'
if [ "$(uname -s)" != "Darwin" ]; then
  echo "NOT VERIFIED: this diagnostic is intended for macOS."
  exit 2
fi
printf '\n[OS]\n'
sw_vers 2>&1
uname -m
printf '\n[Developer tools]\n'
xcode-select -p 2>&1 || true
swift --version 2>&1 || true
if command -v xcodebuild >/dev/null 2>&1; then xcodebuild -version 2>&1; fi
printf '\n[App bundle]\n'
APP="$(pwd -P)/dist/KoeBridge.app"
if [ ! -d "$APP" ]; then
  echo "NOT BUILT: $APP"
else
  plutil -lint "$APP/Contents/Info.plist" 2>&1 || true
  codesign --verify --strict --deep "$APP" 2>&1 && echo 'SIGNATURE: verification passed' || echo 'SIGNATURE: verification failed'
  /usr/bin/codesign -dv --verbose=1 "$APP" 2>&1 | grep -E 'Identifier=|TeamIdentifier=|Authority=|Signature=' || true
fi
printf '\n[Local debug log — no transcript body expected]\n'
if [ -f "$HOME/Library/Logs/KoeBridge.log" ]; then
  tail -n 25 "$HOME/Library/Logs/KoeBridge.log"
else
  echo 'No debug log yet.'
fi
printf '\n[Manual checks still required]\n'
echo 'macOS System Settings > Privacy & Security > Accessibility: check KoeBridge permission.'
echo 'macOS System Settings > Privacy & Security > Input Monitoring: for Right Command / Fn.'
echo 'KoeBridge Settings: confirm chosen shortcut and automatic paste.'
echo 'The tool does not read or grant macOS TCC permissions.'
