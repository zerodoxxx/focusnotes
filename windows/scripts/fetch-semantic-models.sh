#!/usr/bin/env bash
# Downloads the semantic-search models listed in ModelManifest.cs, verifying SHA-256 and size.
# Usage: fetch-semantic-models.sh [models-directory]   (default: windows/.semantic-models)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$WINDOWS_DIR/src/CaptureApp.ModelInstall/ModelManifest.cs"
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [models-directory]" >&2
  exit 2
fi
DEST="${1:-$WINDOWS_DIR/.semantic-models}"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

ensure_file() {
  local target="$1" url="$2" expected_sha="$3" expected_bytes="$4" actual_sha actual_bytes tmp
  if [[ -f "$target" ]]; then
    actual_sha="$(shasum -a 256 "$target" | awk '{print $1}')"
    actual_bytes="$(wc -c < "$target" | tr -d ' ')"
    if [[ "$actual_sha" == "$expected_sha" && "$actual_bytes" == "$expected_bytes" ]]; then
      return
    fi
    rm -f "$target"
  fi
  mkdir -p "$(dirname "$target")"
  tmp="$target.partial"
  rm -f "$tmp"
  echo "Downloading ${target#$DEST/}"
  curl --fail --location --silent --show-error --retry 3 --output "$tmp" "$url"
  actual_sha="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  actual_bytes="$(wc -c < "$tmp" | tr -d ' ')"
  if [[ "$actual_sha" != "$expected_sha" || "$actual_bytes" != "$expected_bytes" ]]; then
    rm -f "$tmp"
    echo "SHA-256 or size mismatch for ${target#$DEST/}: $actual_sha ($actual_bytes bytes)" >&2
    return 1
  fi
  mv "$tmp" "$target"
}

while IFS=$'\t' read -r path url sha bytes; do
  [[ -n "$path" ]] || continue
  ensure_file "$DEST/$path" "$url" "$sha" "$bytes"
done < <(python3 - "$MANIFEST" <<'PY'
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
repo = re.search(r'const string Repo = "([^"]+)"', source).group(1)
revision = re.search(r'const string Revision = "([^"]+)"', source).group(1)
base = f"https://huggingface.co/{repo}/resolve/{revision}"
for path, sha, size in re.findall(r'Artifact\("([^"]+)", "([0-9a-f]{64})", (\d+)\)', source):
    print("\t".join((path, f"{base}/{path}", sha, size)))
PY
)

echo "All semantic model files are present and verified in $DEST"
