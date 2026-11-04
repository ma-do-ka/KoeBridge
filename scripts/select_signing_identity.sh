#!/usr/bin/env bash
# Sourced by build_app.sh. Refuse silent ad-hoc signing, which changes TCC
# identity on every update. An existing stable certificate is reused/pinned.
set -euo pipefail

select_koebridge_identity() {
  local base="${HOME}/Library/Application Support/KoeBridge"
  local pinned_file="${base}/signing-identity.sha1"
  local found=""
  local n=0
  local line hash
  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  SIGN_IDENTITY=""
  SIGN_IDENTITY_PERSIST=""

  if [ "${KOEBRIDGE_SIGNING_IDENTITY:-}" = "-" ]; then
    if [ "${KOEBRIDGE_ALLOW_ADHOC:-0}" != "1" ]; then
      echo 'ERROR: Ad-hoc signing explicitly requires KOEBRIDGE_ALLOW_ADHOC=1.' >&2
      return 1
    fi
    SIGN_IDENTITY="-"
    return 0
  fi

  if [ -f "$pinned_file" ]; then
    SIGN_IDENTITY="$(tr -d '\r\n' < "$pinned_file")"
    if ! [[ "$SIGN_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
      echo "ERROR: Invalid pinned signing identity in $pinned_file" >&2
      return 1
    fi
    if ! printf '%s\n' "$identities" | grep -Fiq "$SIGN_IDENTITY"; then
      echo "ERROR: Pinned signing certificate $SIGN_IDENTITY is unavailable. Refusing to sign with a different identity." >&2
      return 1
    fi
    if [ -n "${KOEBRIDGE_SIGNING_IDENTITY:-}" ] && [ "${KOEBRIDGE_SIGNING_IDENTITY}" != "$SIGN_IDENTITY" ]; then
      echo 'ERROR: Requested signing identity differs from the pinned identity. Keeping TCC identity stable.' >&2
      return 1
    fi
    return 0
  fi

  # Only accept an explicit SHA-1 fingerprint or auto-select one unambiguous
  # valid code-signing certificate. Do not silently use the first of several.
  if [ -n "${KOEBRIDGE_SIGNING_IDENTITY:-}" ]; then
    SIGN_IDENTITY="${KOEBRIDGE_SIGNING_IDENTITY}"
    if ! [[ "$SIGN_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]] ||
       ! printf '%s\n' "$identities" | grep -Fiq "$SIGN_IDENTITY"; then
      echo 'ERROR: KOEBRIDGE_SIGNING_IDENTITY must be the SHA-1 of a valid code-signing identity.' >&2
      return 1
    fi
    SIGN_IDENTITY_PERSIST="$SIGN_IDENTITY"
    return 0
  fi

  while IFS= read -r line; do
    case "$line" in
      *\"Apple\ Development:*|*\"Developer\ ID\ Application:*|*\"KoeBridge\ Local\ Signing\"*|*\"Mac\ Developer:*)
        hash="$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]{40}) .*/\1/p')"
        if [ -n "$hash" ]; then found="$hash"; n=$((n + 1)); fi
        ;;
    esac
  done <<< "$identities"

  if [ "$n" -eq 1 ]; then
    SIGN_IDENTITY="$found"
    SIGN_IDENTITY_PERSIST="$found"
    echo "INFO: Found an existing stable signing identity. Pinning after successful installation."
    return 0
  fi
  if [ "${KOEBRIDGE_ALLOW_ADHOC:-0}" = "1" ]; then
    SIGN_IDENTITY="-"
    echo 'WARNING: Ad-hoc signing explicitly permitted. Accessibility grants may need to be repeated after updating.' >&2
    return 0
  fi
  if [ "$n" -gt 1 ]; then
    echo 'ERROR: Multiple code signing identities found. Select one by SHA-1 with KOEBRIDGE_SIGNING_IDENTITY, once.' >&2
  else
    echo 'ERROR: No stable code-signing certificate found.' >&2
    echo 'Create a local Code Signing certificate once using Keychain Access > Certificate Assistant > Create a Certificate,' >&2
    echo 'or use an existing Apple Development certificate. Then retry the build.' >&2
    echo 'Temporary development-only override: KOEBRIDGE_ALLOW_ADHOC=1 bash scripts/build_app.sh' >&2
  fi
  echo 'Available identities: security find-identity -v -p codesigning' >&2
  return 1
}

persist_koebridge_identity_after_success() {
  if [ -n "${SIGN_IDENTITY_PERSIST:-}" ]; then
    local base="${HOME}/Library/Application Support/KoeBridge"
    mkdir -p "$base"
    chmod 700 "$base" || true
    (umask 077; printf '%s\n' "$SIGN_IDENTITY_PERSIST" > "$base/signing-identity.sha1")
  fi
}
