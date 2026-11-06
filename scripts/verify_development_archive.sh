#!/usr/bin/env bash
# The same archive gate is used by pull requests and public releases.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
  echo 'ERROR: Archive verification requires macOS.' >&2
  exit 1
fi
RELEASE_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :KoeBridgeReleaseLabel' scripts/Info.plist)"
if [[ ! "$RELEASE_LABEL" =~ ^[0-9]+\.[0-9]+\.[0-9]+[a-z]?$ ]]; then
  echo 'ERROR: Invalid release label in scripts/Info.plist.' >&2
  exit 1
fi
ARCHIVE_NAME="KoeBridge-v${RELEASE_LABEL}-macOS-universal-development.zip"
test -s "dist/$ARCHIVE_NAME"
(cd dist && shasum -a 256 --check SHA256SUMS.txt)
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/koebridge-verify.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "dist/$ARCHIVE_NAME" "$VERIFY_DIR"
APP_PATH="$VERIFY_DIR/KoeBridge.app"
test -x "$APP_PATH/Contents/MacOS/KoeBridge"
plutil -lint "$APP_PATH/Contents/Info.plist"
cmp scripts/Info.plist "$APP_PATH/Contents/Info.plist"
cmp LICENSE "$APP_PATH/Contents/Resources/LICENSE"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_PATH/Contents/Info.plist")" = KoeBridge_AppIcon.icns
ICON_SHA256="$(shasum -a 256 "$APP_PATH/Contents/Resources/KoeBridge_AppIcon.icns" | awk '{print $1}')"
test "$ICON_SHA256" = 10186e4ecd7927a0d25c2fc26eed8c83db1f21def23f267f4695ca45f04f10f5
codesign --verify --deep --strict "$APP_PATH"
lipo "$APP_PATH/Contents/MacOS/KoeBridge" -verify_arch arm64 x86_64
echo "Verified: $ARCHIVE_NAME (metadata, license, icon, signature, architectures, SHA-256)"
