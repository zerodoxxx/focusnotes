#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

if [[ $# -ne 2 ]]; then
    printf 'Usage: %s <path/to/App.app> <output.dmg>\n' "$0" >&2
    exit 2
fi

APP_PATH="$1"
OUTPUT_PATH="$2"

if [[ ! -d "$APP_PATH" || "$APP_PATH" != *.app ]]; then
    printf 'App bundle not found or not a .app directory: %s\n' "$APP_PATH" >&2
    exit 2
fi
if [[ "$OUTPUT_PATH" != *.dmg ]]; then
    printf 'Output must end in .dmg: %s\n' "$OUTPUT_PATH" >&2
    exit 2
fi
OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
if [[ ! -d "$OUTPUT_DIR" ]]; then
    printf 'Output parent directory does not exist: %s\n' "$OUTPUT_DIR" >&2
    exit 2
fi

while IFS= read -r line; do key="${line%%=*}"; value="${line#*=}"
    case "$key" in
        APPNAME) APPNAME="$value" ;;
        VERSION) VERSION="$value" ;;
    esac
done < "$ROOT_DIR/Config/app.env"

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/make-dmg.XXXXXX")"
trap 'if [[ -n "${STAGING:-}" && -d "$STAGING" ]]; then rm -rf "$STAGING"; fi' EXIT

ditto "$APP_PATH" "$STAGING/$(basename "$APP_PATH")"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "$APPNAME $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$OUTPUT_PATH" >/dev/null
hdiutil verify "$OUTPUT_PATH" >/dev/null

printf '%s\n' "$OUTPUT_PATH"
