#!/usr/bin/env bash
# One-shot, new public repository. Never reuse a directory containing git history.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="ma-do-ka/KoeBridge"

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required. Install with: brew install gh" >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo 'git and python3 are required.' >&2
  exit 1
fi
if [ -e .git ]; then
  echo 'This folder already has Git history. Refusing to publish potentially private commits.' >&2
  exit 1
fi
python3 scripts/audit_public_release.py
if ! gh auth status >/dev/null 2>&1; then
  echo 'Sign in first: gh auth login' >&2
  exit 1
fi
login="$(gh api user --jq .login)"
user_id="$(gh api user --jq .id)"
if [ "$login" != "ma-do-ka" ]; then
  echo "Signed into '$login' rather than 'ma-do-ka'. Refusing cross-account publishing." >&2
  exit 1
fi
if gh repo view "$REPO" --json name >/dev/null 2>&1; then
  echo "Repository '$REPO' already exists. Refusing to overwrite." >&2
  exit 1
fi

# Public files only — no 'git add .' and no inherited local Git history.
git init -b main
while IFS= read -r file; do
  [[ -z "$file" || "$file" == \#* ]] && continue
  git add -- "$file"
done < scripts/public_files.txt

staged="$(git diff --cached --name-only | LC_ALL=C sort)"
approved="$(grep -v '^#' scripts/public_files.txt | grep -v '^[[:space:]]*$' | LC_ALL=C sort)"
if [ "$staged" != "$approved" ]; then
  echo 'Staged files do not match allowlist. No GitHub publishing was attempted.' >&2
  git diff --cached --name-only >&2
  exit 1
fi
python3 scripts/audit_public_release.py
# GitHub noreply commits: no personal email address is required.
git -c user.name="$login" -c user.email="${user_id}+${login}@users.noreply.github.com" \
  commit -m 'Initial public release: KoeBridge v1.0.0'

echo "Publishing a NEW PUBLIC repository: $REPO"
gh repo create "$REPO" --public --source . --remote origin --push \
  --description "Lightweight Swift-native macOS dictation with Gemini Live / Apple on-device STT (MIT)"
echo '[verify] checking remote visibility and main commit'
remote_visibility="$(gh repo view "$REPO" --json visibility --jq .visibility)"
if [ "$remote_visibility" != "PUBLIC" ]; then
  echo "ERROR: Expected PUBLIC visibility, got: $remote_visibility" >&2
  exit 1
fi
remote_commit="$(gh api "repos/$REPO/git/ref/heads/main" --jq .object.sha)"
local_commit="$(git rev-parse HEAD)"
if [ "$remote_commit" != "$local_commit" ]; then
  echo 'ERROR: main commit differs from local source. Verify before announcing publication.' >&2
  exit 1
fi
echo "VERIFIED: https://github.com/$REPO [PUBLIC; main=$local_commit]"
echo 'NEXT: Check GitHub Actions for the Mac-specific test outcome.' 
