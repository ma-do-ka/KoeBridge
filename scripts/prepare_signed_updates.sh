#!/usr/bin/env bash
# Publisher-only, explicit local operation. Never executed by the running app.
# Private keys stay in the login Keychain; this script never exports them.
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] || { echo 'ERROR: macOS required.' >&2; exit 1; }
MODE="${1:-}"
case "$MODE" in configure|package) ;; *) echo 'Usage: bash scripts/prepare_signed_updates.sh configure|package' >&2; exit 1;; esac
ROOT="$(pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/koebridge-publisher.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Download from the reviewed official release; refuse all other bytes.
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  'https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz' \
  -o "$WORK/Sparkle.tar.xz"
[ "$(shasum -a 256 "$WORK/Sparkle.tar.xz" | awk '{print $1}')" = \
  '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27' ] || {
  echo 'ERROR: Sparkle tools checksum mismatch.' >&2; exit 1;
}
mkdir "$WORK/tools"
tar -xJf "$WORK/Sparkle.tar.xz" -C "$WORK/tools"
TOOLS="$WORK/tools/bin"
for tool in generate_keys generate_appcast sign_update; do test -x "$TOOLS/$tool"; done
PLIST="$ROOT/scripts/Info.plist"
EXISTING="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"

if [ "$MODE" = configure ]; then
  if [ -z "$EXISTING" ]; then "$TOOLS/generate_keys"; fi
  PUBLIC_KEY="$("$TOOLS/generate_keys" -p)"
  [[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo 'ERROR: invalid public key.' >&2; exit 1; }
  [ "$(printf '%s' "$PUBLIC_KEY" | /usr/bin/base64 -D | wc -c | tr -d ' ')" = 32 ]
  if [ -n "$EXISTING" ] && [ "$EXISTING" != "$PUBLIC_KEY" ]; then
    echo 'ERROR: published key and Keychain key differ. Refusing key rotation.' >&2; exit 1
  fi
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" "$PLIST"
  echo 'Configured the PUBLIC verification key. Commit scripts/Info.plist before building a release.'
  echo 'Keep the private Keychain entry safe. Never add it to GitHub or a release ZIP.'
  exit 0
fi

# Packaging requires an explicitly provisioned key, never a key created silently.
[ -n "$EXISTING" ] || { echo 'ERROR: run configure on the publisher Mac first.' >&2; exit 1; }
[ "$("$TOOLS/generate_keys" -p)" = "$EXISTING" ] || { echo 'ERROR: signing key mismatch.' >&2; exit 1; }
if pgrep -x KoeBridge >/dev/null; then echo 'ERROR: Quit KoeBridge before building.' >&2; exit 1; fi
# Do not silently use the reduced test path for a release candidate.
python3 scripts/audit_public_release.py
python3 -m unittest discover -s scripts -p 'test_*.py' -v
swift test
swift run -c release KoeBridgeSelfTest
KOEBRIDGE_PACKAGE_DEVELOPMENT=1 bash scripts/package_development_build.sh
bash scripts/verify_development_archive.sh
LABEL="$(/usr/libexec/PlistBuddy -c 'Print :KoeBridgeReleaseLabel' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
[[ "$LABEL" =~ ^[0-9]+\.[0-9]+\.[0-9]+[a-z]?$ ]] && [[ "$BUILD" =~ ^[0-9]+$ ]]
ARCHIVE="KoeBridge-v${LABEL}-macOS-universal-development.zip"
mkdir "$WORK/feed"
cp "dist/$ARCHIVE" "$WORK/feed/"
"$TOOLS/generate_appcast" --download-url-prefix "https://github.com/ma-do-ka/KoeBridge/releases/download/v${LABEL}/" "$WORK/feed"
python3 scripts/validate_update_feed.py "$WORK/feed/appcast.xml" "$WORK/feed/$ARCHIVE" "$LABEL" "$BUILD"
# Feed content has just been validated/normalized, so sign AFTER the last edit.
"$TOOLS/sign_update" "$WORK/feed/appcast.xml"
mkdir -p dist/signed-update
cp "$WORK/feed/appcast.xml" dist/signed-update/appcast.xml
printf 'Prepared %s and dist/signed-update/appcast.xml\n' "dist/$ARCHIVE"
echo 'NOT PUBLISHED. Upload and verify the matching release ZIP first, then publish this exact signed feed.'
echo 'Do not edit the feed after signing. Initial adoption still needs one manual installation.'
