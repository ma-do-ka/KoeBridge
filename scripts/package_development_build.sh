#!/usr/bin/env bash
# Explicitly package an unnotarized development build. Feed packages must use
# stable signing; ad-hoc signing remains the default for throwaway archives.
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
PACKAGE_SIGNING="${KOEBRIDGE_PACKAGE_SIGNING:-adhoc}"
case "$PACKAGE_SIGNING" in
  stable|adhoc) ;;
  *) echo 'ERROR: KOEBRIDGE_PACKAGE_SIGNING must be stable or adhoc.' >&2; exit 1 ;;
esac
RELEASE_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :KoeBridgeReleaseLabel' scripts/Info.plist)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' scripts/Info.plist)"
if [[ ! "$RELEASE_LABEL" =~ ^[0-9]+\.[0-9]+\.[0-9]+[a-z]?$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo 'ERROR: Invalid release identity in scripts/Info.plist.' >&2
  exit 1
fi
ARCHIVE_NAME="KoeBridge-v${RELEASE_LABEL}-macOS-universal-development.zip"
if [ "$PACKAGE_SIGNING" = stable ]; then
  # Reuse the ordinary local build's identity selection and pinning unchanged.
  KOEBRIDGE_UNIVERSAL=1 bash scripts/build_app.sh
else
  KOEBRIDGE_SIGNING_IDENTITY=- KOEBRIDGE_ALLOW_ADHOC=1 KOEBRIDGE_UNIVERSAL=1 bash scripts/build_app.sh
fi
APP_PATH=dist/KoeBridge.app
ARCHIVE_PATH="dist/$ARCHIVE_NAME"
codesign --verify --deep --strict "$APP_PATH"
if [ "$PACKAGE_SIGNING" = stable ]; then
  if ! SIGNATURE="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"; then
    echo 'ERROR: Cannot inspect the stable package signing identity.' >&2
    exit 1
  fi
  if printf '%s\n' "$SIGNATURE" | grep -Eq '^Signature=adhoc$' ||
     ! printf '%s\n' "$SIGNATURE" | grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$'; then
    echo 'ERROR: Stable packages require a non-ad-hoc signature with an Apple TeamIdentifier.' >&2
    exit 1
  fi
fi
lipo "$APP_PATH/Contents/MacOS/KoeBridge" -verify_arch arm64 x86_64
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")" = "$BUILD_NUMBER"
rm -f "$ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
(cd dist && shasum -a 256 "$ARCHIVE_NAME" > SHA256SUMS.txt)
test -s "$ARCHIVE_PATH"
echo "Packaged: $ARCHIVE_PATH ($PACKAGE_SIGNING signing; not notarized)"
