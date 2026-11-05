#!/usr/bin/env bash
# Build into a staging directory and replace the previous app only after
# the new bundle has been built, signed and verified.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: build_app.sh requires macOS. macOS UI code is NOT compiled on Linux." >&2
  exit 1
fi
for executable in swift codesign plutil; do
  if ! command -v "$executable" >/dev/null 2>&1; then
    echo "ERROR: missing required tool: $executable" >&2
    exit 1
  fi
done

# A running process can retain an old executable and permissions while the
# bundle underneath it is replaced. Never update a running KoeBridge.
if pgrep -x KoeBridge >/dev/null 2>&1; then
  echo "ERROR: KoeBridge is running. Quit it from the menu bar before rebuilding/upgrading." >&2
  exit 1
fi

ROOT="$(pwd -P)"
DIST="$ROOT/dist"
ICON_SOURCE="$ROOT/Resources/KoeBridge_AppIcon.icns"
ICON_SHA256="10186e4ecd7927a0d25c2fc26eed8c83db1f21def23f267f4695ca45f04f10f5"
if [ ! -s "$ICON_SOURCE" ]; then
  echo "ERROR: Required KoeBridge icon missing or empty: $ICON_SOURCE" >&2
  exit 1
fi
if [ "$(shasum -a 256 "$ICON_SOURCE" | awk '{print $1}')" != "$ICON_SHA256" ]; then
  echo "ERROR: App icon bytes differ from the approved icon asset." >&2
  exit 1
fi
DEST="$DIST/KoeBridge.app"
BACKUP="$DIST/KoeBridge.previous.app"
# Stable designated requirements allow macOS to recognize later versions as
# the same app, avoiding repeat permission grants. Never silently downgrade.
source scripts/select_signing_identity.sh
select_koebridge_identity
mkdir -p "$DIST"
STAGE="$(mktemp -d "$DIST/.koebridge-stage.XXXXXX")"
cleanup() {
  status=$?
  rm -rf "$STAGE"
  exit "$status"
}
trap cleanup EXIT

swift build -c release --product KoeBridge
BIN="$(swift build -c release --show-bin-path)/KoeBridge"
if [ ! -x "$BIN" ]; then
  echo "ERROR: compiled binary not found: $BIN" >&2
  exit 1
fi
APP="$STAGE/KoeBridge.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/KoeBridge"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp "$ICON_SOURCE" "$APP/Contents/Resources/KoeBridge_AppIcon.icns"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist")" != "KoeBridge_AppIcon.icns" ]; then
  echo "ERROR: Info.plist CFBundleIconFile does not reference the bundled icon" >&2
  exit 1
fi
test -s "$APP/Contents/Resources/KoeBridge_AppIcon.icns"
chmod +x "$APP/Contents/MacOS/KoeBridge"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

# The old application is untouched up to this point. Preserve one rollback
# copy for a failed manual upgrade or a Mac-specific runtime regression.
if [ -d "$DEST" ]; then
  rm -rf "$BACKUP"
  mv "$DEST" "$BACKUP"
fi
if ! mv "$APP" "$DEST"; then
  echo "ERROR: installing new bundle failed, attempting rollback." >&2
  if [ -d "$BACKUP" ] && [ ! -e "$DEST" ]; then mv "$BACKUP" "$DEST"; fi
  exit 1
fi

persist_koebridge_identity_after_success
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "WARNING: Ad-hoc signing was explicitly allowed; macOS permission continuity is NOT guaranteed." >&2
else
  echo 'INFO: Signed with a persistent certificate. The first transition from ad-hoc may require one new permission grant.' >&2
fi
printf 'Built: %s\nPrevious version (if any): %s\n' "$DEST" "$BACKUP"
echo "Open with: open '$DEST'"
