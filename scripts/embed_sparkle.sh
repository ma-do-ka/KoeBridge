#!/usr/bin/env bash
# Called by build_app.sh BEFORE signing the outer app. No downloads or keys here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP="${1:?app bundle path required}"
IDENTITY="${2:?code signing identity required}"
[ "$(uname -s)" = Darwin ] || { echo 'ERROR: macOS required.' >&2; exit 1; }
FOUND=()
while IFS= read -r candidate; do FOUND+=("$candidate"); done < <(
  find "$ROOT/.build/artifacts" -type d -name Sparkle.framework
)
[ "${#FOUND[@]}" -eq 1 ] || { echo 'ERROR: expected exactly one resolved Sparkle.framework.' >&2; exit 1; }
SOURCE="${FOUND[0]}"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Resources/Info.plist")" = '2.10.1' ] || {
  echo 'ERROR: unexpected Sparkle version.' >&2; exit 1;
}
mkdir -p "$APP/Contents/Frameworks"
ditto "$SOURCE" "$APP/Contents/Frameworks/Sparkle.framework"
FW="$APP/Contents/Frameworks/Sparkle.framework"
test -x "$FW/Versions/B/Autoupdate"
test -d "$FW/Versions/B/Updater.app"
# Keep all supplied resources, helpers and licenses. Sign from the inside out.
codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements,flags "$FW/Versions/B/Autoupdate"
while IFS= read -r -d '' nested; do
  codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements,flags "$nested"
done < <(find "$FW/Versions/B" -depth -type d \( -name '*.xpc' -o -name '*.app' \) -print0)
codesign --force --sign "$IDENTITY" "$FW"
codesign --verify --deep --strict "$FW"
otool -L "$APP/Contents/MacOS/KoeBridge" | grep -F '@rpath/Sparkle.framework/' >/dev/null
# The rpath must be relocatable, not dependent on the user's .build directory.
otool -l "$APP/Contents/MacOS/KoeBridge" | grep -F '@executable_path/../Frameworks' >/dev/null
