#!/usr/bin/env bash
# Build KoeBridge even if this Mac's selected Swift toolchain lacks Swift Testing.
# Never claim full unit tests have passed when the module is missing.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: This helper must run on macOS." >&2
  exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: Swift CLI not found." >&2
  exit 1
fi
printf '[developer directory]\n'
xcode-select -p 2>&1 || true
printf '[swift version]\n'
swift --version

# Attempt full Swift Testing only if 'import Testing' can be resolved.
# Uses the *same selected toolchain* as swift test and swift build.
if printf 'import Testing\n' | swiftc -typecheck - >/dev/null 2>&1; then
  echo '[full Swift Testing available] running swift test'
  swift test
else
  echo 'NOTICE: Swift Testing module unavailable in selected toolchain.'
  echo 'NOTICE: Running portable core tests instead. Full Swift Testing suite SKIPPED.'
fi

# Portable tests work without either Testing or XCTest.
# This also protects the app build when the full unit-test module is absent.
swift run -c release KoeBridgeSelfTest

# The actual macOS executable must compile. Core-only tests are not enough.
bash ./scripts/build_app.sh
printf '[app ready] %s\n' "$(pwd -P)/dist/KoeBridge.app"
echo 'REMINDER: macOS must grant Accessibility and microphone permission to the signed app at least once.'
echo 'A stable signing identity is used when available. A macOS permission grant is never made by this script.'
if [ "${1:-}" = '--open' ]; then
  open dist/KoeBridge.app
fi
