#!/usr/bin/env bash
# One-time maintainer setup for Windows update-index signing. Generates an Ed25519 key,
# writes the private half to a 0600 backup file (never printed), and appends the public
# half to WINDOWS_UPDATE_ED_KEYS in Config/app.env. Run once per key: K1 now, K2 later
# (the offline rotation key). Never run this in CI. Dropping a key from app.env makes
# installed copies refuse indexes signed with it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ENV_FILE="$ROOT_DIR/Config/app.env"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

SLOT="${1:-}"
if [[ $# -ne 1 || ! "$SLOT" =~ ^[12]$ ]]; then
    printf 'Usage: %s <1|2>   (1 = online signing key K1, 2 = offline rotation key K2)\n' "$0" >&2
    exit 2
fi

while IFS= read -r line; do key="${line%%=*}"; value="${line#*=}"
    case "$key" in
        APPNAME) APPNAME="$value" ;;
    esac
done < "$ENV_FILE"
[[ -n "${APPNAME:-}" ]] || fail "APPNAME is missing from Config/app.env"

BACKUP="$HOME/$APPNAME-windows-update-key-K$SLOT.txt"
count="$(grep -c '^WINDOWS_UPDATE_ED_KEYS=' "$ENV_FILE" || true)"
[[ "$count" == 1 ]] || fail "expected exactly one WINDOWS_UPDATE_ED_KEYS= line in Config/app.env, found $count."
if [[ -e "$BACKUP" || -L "$BACKUP" ]]; then
    fail "$BACKUP already exists. Store it in a password manager and delete it, then rerun. Not overwriting."
fi

# Build first so build chatter can't mix into keygen's output, then run the built dll.
# The key is generated in a private temp dir and only moved to $BACKUP once the public key parsed.
WORK="$(umask 077 && mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
dotnet build "$ROOT_DIR/windows/tools/IndexSigner" -c Release --artifacts-path "$WORK/art" >/dev/null || fail "could not build IndexSigner."
OUTPUT="$(dotnet "$WORK/art/bin/CaptureApp.IndexSigner/release/CaptureApp.IndexSigner.dll" keygen --out "$WORK/key.txt")" || fail "IndexSigner keygen failed."
ENTRY="$(tail -n 1 <<<"$OUTPUT")"
[[ "$ENTRY" =~ ^[A-Za-z0-9]+:[A-Za-z0-9+/]{43}=$ ]] || fail "could not read the public key from IndexSigner keygen."
[[ -s "$WORK/key.txt" ]] || fail "key generation failed: no key file was written."
[[ ! -e "$BACKUP" && ! -L "$BACKUP" ]] || fail "$BACKUP appeared meanwhile. Not overwriting."
(umask 077 && mv "$WORK/key.txt" "$BACKUP")
chmod 600 "$BACKUP"

CURRENT="$(sed -n 's/^WINDOWS_UPDATE_ED_KEYS=//p' "$ENV_FILE")"
if [[ -n "$CURRENT" ]]; then
    UPDATED="$CURRENT,$ENTRY"
else
    UPDATED="$ENTRY"
fi
sed -i.bak "s|^WINDOWS_UPDATE_ED_KEYS=.*|WINDOWS_UPDATE_ED_KEYS=$UPDATED|" "$ENV_FILE"
rm -f "$ENV_FILE.bak"
grep -Fxq "WINDOWS_UPDATE_ED_KEYS=$UPDATED" "$ENV_FILE" || fail "could not write the public key to Config/app.env"

printf '\nWINDOWS_UPDATE_ED_KEYS in Config/app.env now trusts: %s\n' "$UPDATED"
printf 'Private key file (PRIVATE): %s\n' "$BACKUP"
printf '\nNext steps:\n'
if [[ "$SLOT" == 1 ]]; then
    printf '  1. Store the file as the CI secret WINDOWS_UPDATE_ED_KEY_1:\n'
    printf '       gh secret set WINDOWS_UPDATE_ED_KEY_1 < "%s"\n' "$BACKUP"
    printf '  2. Keep the file in a password manager, then delete it: rm "%s"\n' "$BACKUP"
else
    printf '  1. Keep K2 OFFLINE (password manager / hardware). Do not add it to CI.\n'
    printf '  2. Delete the local file once stored: rm "%s"\n' "$BACKUP"
    printf '     To rotate, sign releases with K2 after K2 has shipped inside a release signed by K1.\n'
fi
printf '  3. Commit Config/app.env (public keys are not secret).\n'
printf '\nWARNING: only releases built after this commit trust the new key.\n'
