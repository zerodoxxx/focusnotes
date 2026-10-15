#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
while IFS= read -r line; do key="${line%%=*}"; value="${line#*=}"
    if [[ "$key" == "APPNAME" ]]; then
        APPNAME="$value"
    fi
done < "$ROOT_DIR/Config/app.env"

python3 - "$ROOT_DIR" "$APPNAME" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
app_name = sys.argv[2].casefold()
matches = []
files = [root / "Package.swift"]

for directory_name in ("Sources", "Tests", "scripts"):
    directory = root / directory_name
    for path in directory.rglob("*"):
        if not path.is_file():
            continue
        if directory_name == "Sources" and path.relative_to(directory).parts[0] == "CSQLite":
            continue
        files.append(path)

for path in files:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        continue
    for number, line in enumerate(lines, start=1):
        if app_name in line.casefold():
            matches.append(f"{path.relative_to(root)}:{number}:{line.strip()}")

if matches:
    print("App name found outside Config/app.env:")
    print("\n".join(matches))
    sys.exit(1)

print("App name is not duplicated in the checked files.")
PY
