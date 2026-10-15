#!/usr/bin/env bash
# Restore the stable code-signing identity from its backup .p12 into a
# dedicated keychain, and check it matches Config/signing-requirement.txt.
#
# Usage: scripts/import-signing-identity.sh <identity.p12> [keychain-path]
# Passwords come from SIGNING_P12_PASSWORD and SIGNING_KEYCHAIN_PASSWORD when set
# (CI), otherwise they are prompted for.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'Usage: %s <identity.p12> [keychain-path]\n' "$0" >&2
    exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
P12="$1"
[[ -f "$P12" ]] || fail "identity file not found: $P12"

while IFS= read -r line; do key="${line%%=*}"; value="${line#*=}"
    case "$key" in
        APPNAME) APPNAME="$value" ;;
    esac
done < "$ROOT_DIR/Config/app.env"

CN="$APPNAME Release Signing"
KEYCHAIN="${2:-$HOME/Library/Keychains/$APPNAME-signing.keychain-db}"
REQ_FILE="$ROOT_DIR/Config/signing-requirement.txt"

[[ -f "$REQ_FILE" ]] || fail "missing $REQ_FILE; it must be committed before importing"
EXPECTED="$(sed -n 's/.*H"\([0-9a-f]\{40\}\)".*/\1/p' "$REQ_FILE")"
[[ "$EXPECTED" =~ ^[0-9a-f]{40}$ ]] || fail "could not read the expected certificate hash from $REQ_FILE"

if [[ -e "$KEYCHAIN" || -L "$KEYCHAIN" ]]; then
    fail "keychain already exists: $KEYCHAIN (refusing to overwrite an existing signing keychain)"
fi

read_secret() {
    local name="$1" prompt="$2" value
    if [[ -n "${!name:-}" ]]; then
        printf '%s' "${!name}"
        return 0
    fi
    read -rsp "$prompt: " value || fail "a terminal is required to enter passwords (or set the env variables)"
    printf '\n' >&2
    [[ -n "$value" ]] || fail "$prompt must not be empty"
    printf '%s' "$value"
}

P12_PW="$(read_secret SIGNING_P12_PASSWORD ".p12 password")"
KC_PW="$(read_secret SIGNING_KEYCHAIN_PASSWORD "keychain password")"

CREATED=0
OK=0
prev=()
cleanup() {
    if [[ "$CREATED" == 1 ]]; then
        security list-keychains -d user -s "${prev[@]+"${prev[@]}"}" >/dev/null 2>&1 || true
    fi
    if [[ "$CREATED" == 1 && "$OK" != 1 ]]; then
        security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
        printf 'Import failed; removed the partial keychain %s\n' "$KEYCHAIN" >&2
    fi
}
trap cleanup EXIT

printf '==> creating keychain %s\n' "$KEYCHAIN"
while IFS= read -r kc; do
    kc="${kc#"${kc%%[![:space:]]*}"}"
    kc="${kc%"${kc##*[![:space:]]}"}"
    kc="${kc#\"}"
    kc="${kc%\"}"
    [[ -n "$kc" ]] && prev+=("$kc")
done < <(security list-keychains -d user)

security create-keychain -p "$KC_PW" "$KEYCHAIN"
CREATED=1
security list-keychains -d user -s "${prev[@]+"${prev[@]}"}"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KC_PW" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$P12_PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KEYCHAIN" >/dev/null

HASH="$(security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$CN\"" | grep -Eo '[0-9A-Fa-f]{40}' | head -n 1 || true)"
HASH="$(printf '%s' "$HASH" | tr '[:upper:]' '[:lower:]')"

if [[ "$HASH" != "$EXPECTED" ]]; then
    fail "imported identity hash '${HASH:-none}' does not match Config/signing-requirement.txt ($EXPECTED). Wrong .p12 file? Signing with it would reset every user's Accessibility and Screen Recording permissions."
fi

OK=1
printf 'Imported "%s" into %s (SHA-1 %s matches the requirement file).\n' "$CN" "$KEYCHAIN" "$HASH"
