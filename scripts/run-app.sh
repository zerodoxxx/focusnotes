#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [debug|release]\n' "$0" >&2
    exit 2
fi

CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
    debug|release) ;;
    *)
        printf 'Invalid configuration: %s (expected debug or release)\n' "$CONFIGURATION" >&2
        exit 2
        ;;
esac

while IFS= read -r line; do key="${line%%=*}"; value="${line#*=}"
    case "$key" in
        APPNAME) APPNAME="$value" ;;
        BUNDLE_PREFIX) BUNDLE_PREFIX="$value" ;;
    esac
done < "$ROOT_DIR/Config/app.env"

APPNAME_LOWER="$(printf '%s' "$APPNAME" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9-]/-/g')"
BUNDLE_ID="$BUNDLE_PREFIX.$APPNAME_LOWER"
BUNDLE_PATH="$ROOT_DIR/build/$APPNAME.app"

# Install to /Applications, or ~/Applications when /Applications is not writable.
INSTALL_DIR="/Applications"
if [[ ! -w "$INSTALL_DIR" ]]; then
    HOME_DIR="$(cd "$HOME" && pwd -P)"
    INSTALL_DIR="$HOME_DIR/Applications"
fi
INSTALL_PATH="$INSTALL_DIR/$APPNAME.app"

# Reject unsafe names and symlinked output/install parents before invoking the build.
python3 "$SCRIPT_DIR/check-app-path.py" "$APPNAME" "$ROOT_DIR/build"
python3 "$SCRIPT_DIR/check-app-path.py" "$APPNAME" "$ROOT_DIR" .build
python3 "$SCRIPT_DIR/check-app-path.py" "$APPNAME" "$INSTALL_DIR"

"$SCRIPT_DIR/build-app.sh" "$CONFIGURATION"

# Recheck immediately before making the installation directory or removing a prior app.
python3 "$SCRIPT_DIR/check-app-path.py" "$APPNAME" "$ROOT_DIR/build"
python3 "$SCRIPT_DIR/check-app-path.py" "$APPNAME" "$ROOT_DIR" .build
python3 "$SCRIPT_DIR/check-app-path.py" "$APPNAME" "$INSTALL_DIR"
if [[ ! -d "$INSTALL_DIR" ]]; then
    mkdir "$INSTALL_DIR"
fi
python3 "$SCRIPT_DIR/check-app-path.py" "$APPNAME" "$INSTALL_DIR"

pkill -x "$APPNAME" 2>/dev/null || true
rm -rf "$INSTALL_PATH"
ditto "$BUNDLE_PATH" "$INSTALL_PATH"
open "$INSTALL_PATH"
printf 'Installed %s\n' "$INSTALL_PATH"

# SwiftPM's .build grows to several GB; drop it and the staged bundle once installed.
# KEEP_BUILD=1 keeps them for faster incremental rebuilds.
if [[ "${KEEP_BUILD:-0}" != "1" ]]; then
    python3 "$SCRIPT_DIR/check-app-path.py" "$APPNAME" "$ROOT_DIR/build"
    python3 "$SCRIPT_DIR/check-app-path.py" "$APPNAME" "$ROOT_DIR" .build
    rm -rf "$ROOT_DIR/.build" "$BUNDLE_PATH"
    printf 'Removed build artifacts (set KEEP_BUILD=1 to keep them)\n'
fi

printf "Tail logs with: log stream --predicate 'subsystem == \"%s\"'\n" "$BUNDLE_ID"
