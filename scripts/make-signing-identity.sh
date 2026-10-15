#!/usr/bin/env bash
# Create the stable self-signed code-signing identity used by every build of this app.
#
# Run ONCE, ever, on the maintainer's Mac. The identity lives in its own keychain
# (not the login keychain). macOS keys Accessibility and Screen Recording grants to
# the signing requirement, so replacing this identity resets every user's grants.
#
# Usage: scripts/make-signing-identity.sh [keychain-path]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [keychain-path]\n' "$0" >&2
    exit 2
fi

while IFS= read -r line; do key="${line%%=*}"; value="${line#*=}"
    case "$key" in
        APPNAME) APPNAME="$value" ;;
        BUNDLE_PREFIX) BUNDLE_PREFIX="$value" ;;
    esac
done < "$ROOT_DIR/Config/app.env"

APPNAME_LOWER="$(printf '%s' "$APPNAME" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9-]/-/g')"
BUNDLE_ID="$BUNDLE_PREFIX.$APPNAME_LOWER"
CN="$APPNAME Release Signing"
KEYCHAIN="${1:-$HOME/Library/Keychains/$APPNAME-signing.keychain-db}"
BACKUP="$HOME/$APPNAME-signing-identity.p12"
REQ_FILE="$ROOT_DIR/Config/signing-requirement.txt"

# Refuse before doing any work if an identity already exists.
if [[ -e "$KEYCHAIN" || -L "$KEYCHAIN" ]]; then
    fail "signing keychain already exists: $KEYCHAIN
Replacing the identity would reset every user's Accessibility and Screen Recording permissions.
If the identity is lost, restore it from backup with scripts/import-signing-identity.sh <identity.p12> instead."
fi
if [[ -e "$BACKUP" || -L "$BACKUP" ]]; then
    fail "backup already exists: $BACKUP (move it aside first; it is an existing signing identity)."
fi
if [[ -e "$REQ_FILE" || -L "$REQ_FILE" ]]; then
    fail "requirement file already exists: $REQ_FILE
Replacing it would reset every user's Accessibility and Screen Recording permissions.
If the identity is lost, restore it from backup with scripts/import-signing-identity.sh <identity.p12> instead."
fi

is_modern_openssl() {
    local version
    version="$("$1" version 2>/dev/null)" || return 1
    [[ "$version" =~ ^OpenSSL\ ([0-9]+) ]] || return 1
    (( BASH_REMATCH[1] >= 3 ))
}

find_openssl() {
    local candidate
    for candidate in /opt/homebrew/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
        if [[ -x "$candidate" ]] && is_modern_openssl "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    candidate="$(command -v openssl 2>/dev/null || true)"
    if [[ -n "$candidate" ]] && is_modern_openssl "$candidate"; then
        printf '%s' "$candidate"
        return 0
    fi
    return 1
}

OPENSSL="$(find_openssl)" || fail "OpenSSL 3 or newer is required (macOS LibreSSL cannot write the needed PKCS#12). Install it with: brew install openssl@3"

read_new_secret() {
    local prompt="$1" value confirm
    read -rsp "$prompt: " value || fail "a terminal is required to enter passwords (or set the env variables)"
    printf '\n' >&2
    [[ -n "$value" ]] || fail "password must not be empty"
    read -rsp "Confirm $prompt: " confirm || fail "a terminal is required to enter passwords (or set the env variables)"
    printf '\n' >&2
    [[ "$value" == "$confirm" ]] || fail "passwords do not match"
    printf '%s' "$value"
}

KC_PW="$(read_new_secret "keychain password")"
P12_PW="$(read_new_secret "backup .p12 password")"

WORK="$(mktemp -d)"
chmod 700 "$WORK"
KEYCHAIN_CREATED=0
REQ_WRITTEN=0
BACKUP_WRITTEN=0
SUCCESS=0
prev=()
cleanup() {
    rm -rf "$WORK"
    if [[ "$KEYCHAIN_CREATED" == 1 ]]; then
        security list-keychains -d user -s "${prev[@]+"${prev[@]}"}" >/dev/null 2>&1 || true
    fi
    if [[ "$SUCCESS" != 1 ]]; then
        if [[ "$REQ_WRITTEN" == 1 ]]; then
            rm -f "$REQ_FILE"
        fi
        if [[ "$BACKUP_WRITTEN" == 1 ]]; then
            rm -f "$BACKUP"
        fi
        if [[ "$KEYCHAIN_CREATED" == 1 ]]; then
            security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
            printf 'Setup did not finish; removed the partial keychain %s\n' "$KEYCHAIN" >&2
        fi
    fi
}
trap cleanup EXIT

CNF="$WORK/cert.cnf"
cat > "$CNF" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = codesign_ext

[dn]
CN = $CN

[codesign_ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

printf '==> creating certificate (RSA 3072, 7300 days)\n'
"$OPENSSL" req -x509 -newkey rsa:3072 -nodes -sha256 -days 7300 \
    -config "$CNF" -extensions codesign_ext \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1 \
    || fail "openssl req failed"

P12="$WORK/identity.p12"
P12_PW="$P12_PW" "$OPENSSL" pkcs12 -export -legacy -name "$CN" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$P12" -passout env:P12_PW >/dev/null 2>&1 \
    || fail "openssl pkcs12 export failed"

printf '==> creating keychain %s\n' "$KEYCHAIN"
while IFS= read -r kc; do
    kc="${kc#"${kc%%[![:space:]]*}"}"
    kc="${kc%"${kc##*[![:space:]]}"}"
    kc="${kc#\"}"
    kc="${kc%\"}"
    [[ -n "$kc" ]] && prev+=("$kc")
done < <(security list-keychains -d user)

security create-keychain -p "$KC_PW" "$KEYCHAIN"
KEYCHAIN_CREATED=1
security list-keychains -d user -s "${prev[@]+"${prev[@]}"}"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KC_PW" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$P12_PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KEYCHAIN" >/dev/null

HASH="$(security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$CN\"" | grep -Eo '[0-9A-Fa-f]{40}' | head -n 1 || true)"
[[ "$HASH" =~ ^[0-9A-Fa-f]{40}$ ]] || fail "could not read the SHA-1 of the new identity from $KEYCHAIN"
HASH="$(printf '%s' "$HASH" | tr '[:upper:]' '[:lower:]')"

# noclobber: never overwrite an existing requirement file.
(set -C; printf 'identifier "%s" and certificate leaf = H"%s"\n' "$BUNDLE_ID" "$HASH" > "$REQ_FILE") \
    || fail "could not create $REQ_FILE (it must not already exist)"
REQ_WRITTEN=1
printf '==> wrote %s\n' "$REQ_FILE"

printf '==> writing backup %s\n' "$BACKUP"
BACKUP_WRITTEN=1
cp "$P12" "$BACKUP"
chmod 600 "$BACKUP"

SUCCESS=1

cat <<EOF

Signing identity created: $CN
  keychain:    $KEYCHAIN
  backup:      $BACKUP
  requirement: $(cat "$REQ_FILE")

Next steps:
  1. Store the backup .p12 and both passwords in a password manager, then delete the .p12:
       rm "$BACKUP"
  2. Commit Config/signing-requirement.txt.
  3. For CI, copy the .p12 as base64 into the secret SIGNING_P12_BASE64:
       base64 -i "$BACKUP" | pbcopy
     and add the secrets SIGNING_P12_PASSWORD and SIGNING_KEYCHAIN_PASSWORD.
  4. Never replace this identity. Replacing it resets every user's Accessibility
     and Screen Recording permissions.
EOF
