#!/usr/bin/env bash
# Non-destructive troubleshooting. Logs only non-transcript metadata.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$(pwd -P)/dist/KoeBridge.app"
LOG="$HOME/Library/Logs/KoeBridge.log"
printf '[bundle signature] %s\n' "$APP"
if [ -d "$APP" ]; then
  codesign --verify --strict "$APP" >/dev/null 2>&1 && echo 'signature: valid' || echo 'signature: INVALID'
  codesign -dv "$APP" 2>&1 | grep -E 'Identifier=|Signature=|TeamIdentifier=|Authority=' || true
  codesign -d -r- "$APP" 2>&1 | grep 'designated =>' || true
else
  echo 'app not built'
fi
printf '\n[recent input decisions: no transcript bodies or API keys]\n'
if [ -f "$LOG" ]; then
  grep -E 'startup; version=|session preparing;|session resolved;|direct typing |direct input path=|delivery blocked:|target captured=' "$LOG" | tail -n 45 || true
else
  echo 'No KoeBridge log exists yet.'
fi
