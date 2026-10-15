#!/usr/bin/env bash
# Fetches the pinned Sparkle release tools (generate_appcast, generate_keys, sign_update).
# Progress goes to stderr; the tools' bin directory is the only thing printed to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

usage() {
    printf 'Usage: %s [dest-directory]\n' "$0" >&2
    exit 2
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ $# -gt 1 ]]; then
    usage
fi

DEST="${1:-$ROOT_DIR/build/sparkle-tools}"
mkdir -p "$(dirname "$DEST")"
DEST="$(cd "$(dirname "$DEST")" && pwd -P)/$(basename "$DEST")"

if [[ -x "$DEST/bin/generate_appcast" && -f "$DEST/.archive-sha256" \
    && "$(cat "$DEST/.archive-sha256")" == "$SPARKLE_SHA256" ]]; then
    printf 'Sparkle %s tools already present and verified.\n' "$SPARKLE_VERSION" >&2
    printf '%s\n' "$DEST/bin"
    exit 0
fi

WORK="$(mktemp -d "$(dirname "$DEST")/.sparkle-fetch.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

printf 'Downloading Sparkle %s tools.\n' "$SPARKLE_VERSION" >&2
curl --fail --location --silent --show-error --retry 3 "$SPARKLE_URL" -o "$WORK/Sparkle.tar.xz"
actual="$(shasum -a 256 "$WORK/Sparkle.tar.xz" | cut -d ' ' -f 1)"
[[ "$actual" == "$SPARKLE_SHA256" ]] || fail "SHA-256 mismatch for $SPARKLE_URL (got $actual, want $SPARKLE_SHA256)"

mkdir "$WORK/extract"
tar -xJf "$WORK/Sparkle.tar.xz" -C "$WORK/extract"
[[ -x "$WORK/extract/bin/generate_appcast" ]] || fail "archive has no bin/generate_appcast"
printf '%s\n' "$SPARKLE_SHA256" > "$WORK/extract/.archive-sha256"

if [[ -e "$DEST" || -L "$DEST" ]]; then
    mv "$DEST" "$WORK/previous"
fi
mv "$WORK/extract" "$DEST"

printf 'Sparkle %s tools installed.\n' "$SPARKLE_VERSION" >&2
printf '%s\n' "$DEST/bin"
