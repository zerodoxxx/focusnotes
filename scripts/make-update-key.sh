#!/usr/bin/env bash
# One-time maintainer setup for Sparkle updates. Creates the EdDSA update key in the
# login Keychain (or reuses the existing one), writes its public half to
# Config/app.env, and exports a private-key backup. Never run this in CI.
# Losing or replacing the key breaks updates for every installed copy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ENV_FILE="$ROOT_DIR/Config/app.env"
PUB_RE='^[A-Za-z0-9+/]{43}=$'

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ $# -gt 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi

while IFS='=' read -r key value; do
    case "$key" in
        APPNAME) APPNAME="$value" ;;
    esac
done < "$ENV_FILE"
[[ -n "${APPNAME:-}" ]] || fail "APPNAME is missing from Config/app.env"

ACCOUNT="$APPNAME"
BACKUP="$HOME/$APPNAME-update-key.txt"

# Check everything that can fail before creating or changing anything.
grep -q '^SPARKLE_PUBLIC_ED_KEY=' "$ENV_FILE" || fail "Config/app.env has no SPARKLE_PUBLIC_ED_KEY= line."
if [[ -e "$BACKUP" || -L "$BACKUP" ]]; then
    fail "$BACKUP already exists. Store it in a password manager and delete it, then rerun. Not overwriting."
fi

SPARKLE_BIN="$("$ROOT_DIR/scripts/fetch-sparkle-tools.sh")"
GENERATE_KEYS="$SPARKLE_BIN/generate_keys"

# generate_keys prints the key inside a longer message on create, so take the last base64 match.
read_public_key() {
    grep -oE '[A-Za-z0-9+/]{43}=' <<<"$1" | tail -n 1 || true
}

if existing_out="$("$GENERATE_KEYS" --account "$ACCOUNT" -p 2>/dev/null)"; then
    printf 'Found an existing Sparkle key for account %s; not creating a new one.\n' "$ACCOUNT"
    PUB="$(read_public_key "$existing_out")"
else
    printf 'No Sparkle key for account %s; creating one in the login Keychain.\n' "$ACCOUNT"
    "$GENERATE_KEYS" --account "$ACCOUNT"
    pub_out="$("$GENERATE_KEYS" --account "$ACCOUNT" -p)" || fail "could not read the new public key from the Keychain."
    PUB="$(read_public_key "$pub_out")"
fi
[[ "$PUB" =~ $PUB_RE ]] || fail "could not parse the Sparkle public key from generate_keys output."

# Backup first: if the export fails, Config/app.env stays untouched.
(
    umask 077
    "$GENERATE_KEYS" --account "$ACCOUNT" -x "$BACKUP"
)
[[ -s "$BACKUP" ]] || fail "export failed: $BACKUP is missing or empty."
chmod 600 "$BACKUP"

count="$(grep -c '^SPARKLE_PUBLIC_ED_KEY=' "$ENV_FILE" || true)"
[[ "$count" == 1 ]] || fail "expected exactly one SPARKLE_PUBLIC_ED_KEY= line in Config/app.env, found $count."
sed -i '' "/^SPARKLE_PUBLIC_ED_KEY=/s|^SPARKLE_PUBLIC_ED_KEY=.*|SPARKLE_PUBLIC_ED_KEY=$PUB|" "$ENV_FILE"
grep -Fxq "SPARKLE_PUBLIC_ED_KEY=$PUB" "$ENV_FILE" || fail "could not write the public key to Config/app.env"

printf '\nSPARKLE_PUBLIC_ED_KEY set in Config/app.env: %s\n' "$PUB"
printf 'Private key backup: %s (this file holds the PRIVATE key)\n' "$BACKUP"
printf '\nNext steps:\n'
printf '  1. Store the backup in a password manager, then delete it: rm "%s"\n' "$BACKUP"
printf '  2. Commit Config/app.env (the public key is not secret).\n'
printf '  3. For CI, store the backup as the secret SPARKLE_ED_PRIVATE_KEY:\n'
printf '       gh secret set SPARKLE_ED_PRIVATE_KEY < "%s"\n' "$BACKUP"
printf '     (then delete the local backup as in step 1)\n'
printf '\nWARNING: never lose or replace this key. Installed copies trust only this public key;\n'
printf 'a new key means existing users cannot receive updates.\n'
