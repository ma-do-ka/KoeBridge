#!/usr/bin/env bash
# Explicit, interactive source-code update for KoeBridge only. The app must
# be quit first; do not turn this script into a silent elevated installer.
set -euo pipefail

if [[ "${1:-}" == "--syntax-check" ]]; then
  echo "KoeBridge source updater syntax OK"
  exit 0
fi

TAG="${1:-}"
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+[a-z]?$ ]]; then
  echo "ERROR: expected an exact stable tag, e.g. v1.0.1d" >&2
  exit 1
fi

ROOT="$HOME/KoeBridge"
if [[ ! -d "$ROOT/.git" ]]; then
  echo "ERROR: $ROOT is not a Git checkout. Follow the README installation guide." >&2
  exit 1
fi
if pgrep -x KoeBridge >/dev/null 2>&1; then
  echo "ERROR: Quit KoeBridge from the menu bar before updating." >&2
  exit 1
fi

cd "$ROOT"
ORIGIN="$(git remote get-url origin)"
case "${ORIGIN%.git}" in
  https://github.com/ma-do-ka/KoeBridge|git@github.com:ma-do-ka/KoeBridge) ;;
  *) echo "ERROR: refusing nonofficial Git remote: $ORIGIN" >&2; exit 1 ;;
esac

if [[ "$(git branch --show-current)" != "main" ]]; then
  echo "ERROR: switch to main after saving your work; updater will not replace another branch." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo "ERROR: local modifications exist. Back them up or commit them first." >&2
  exit 1
fi

echo "[KoeBridge] Fetching the selected stable tag $TAG"
git fetch --no-tags origin "refs/tags/$TAG:refs/tags/$TAG"
git cat-file -e "$TAG^{commit}"
if ! git show "$TAG:scripts/Info.plist" | grep -Fq "<key>KoeBridgeReleaseLabel</key><string>${TAG#v}</string>"; then
  echo "ERROR: tag and app version metadata disagree. No source change performed." >&2
  exit 1
fi

echo "[KoeBridge] Fast-forwarding main to the release (never force/reset)"
git merge --ff-only "$TAG"

echo "[KoeBridge] Running local tests, signing and atomic app replacement"
bash scripts/verify_and_build.sh --open

INSTALLED="$(/usr/libexec/PlistBuddy -c 'Print :KoeBridgeReleaseLabel' dist/KoeBridge.app/Contents/Info.plist)"
if [[ "$INSTALLED" != "${TAG#v}" ]]; then
  echo "ERROR: unexpected installed version: $INSTALLED" >&2
  exit 1
fi

echo "[KoeBridge] Updated successfully to $TAG"
