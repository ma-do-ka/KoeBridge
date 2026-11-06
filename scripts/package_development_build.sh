#!/usr/bin/env bash
# Explicitly package an ad-hoc signed development build; never claim Developer
# ID signing or notarization. Ordinary local builds retain their stable identity.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
  echo 'ERROR: Packaging requires macOS.' >&2
  exit 1
fi
if [ "${KOEBRIDGE_PACKAGE_DEVELOPMENT:-0}" != 1 ]; then
  echo 'ERROR: Set KOEBRIDGE_PACKAGE_DEVELOPMENT=1 to explicitly package an unnotarized development build.' >&2
  exit 1
fi
RELEASE_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :KoeBridgeReleaseLabel' scripts/Info.plist)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' scripts/Info.plist)"
if [[ ! "$RELEASE_LABEL" =~ ^[0-9]+\.[0-9]+\.[0-9]+[a-z]?$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo 'ERROR: Invalid release identity in scripts/Info.plist.' >&2
  exit 1
fi
ARCHIVE_NAME="KoeBridge-v${RELEASE_LABEL}-macOS-universal-development.zip"
KOEBRIDGE_SIGNING_IDENTITY=- KOEBRIDGE_ALLOW_ADHOC=1 KOEBRIDGE_UNIVERSAL=1 bash scripts/build_app.sh
APP_PATH=dist/KoeBridge.app
ARCHIVE_PATH="dist/$ARCHIVE_NAME"
codesign --verify --deep --strict "$APP_PATH"
lipo "$APP_PATH/Contents/MacOS/KoeBridge" -verify_arch arm64 x86_64
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")" = "$BUILD_NUMBER"
rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
(cd dist && shasum -a 256 "$ARCHIVE_NAME" > SHA256SUMS.txt)
test -s "$ARCHIVE_PATH"
echo "Packaged: $ARCHIVE_PATH (ad-hoc signed; not notarized)"
