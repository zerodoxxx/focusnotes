#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

config="$root/Config/app.env"

assert_output() {
  local file="$1"
  local expected="$2"
  grep -Fxq "$expected" "$file" || {
    echo "Expected gate output '$expected' in $file" >&2
    cat "$file" >&2
    exit 1
  }
}

expect_gate_failure() {
  local message="$1"
  shift
  if env "$@" GITHUB_OUTPUT="$tmp/failed-output" WINDOWS_UPDATE_ED_KEY_1=placeholder \
      bash "$root/scripts/windows-release-gate.sh" "$config" > "$tmp/stdout" 2> "$tmp/stderr"; then
    echo "Expected gate failure: $message" >&2
    exit 1
  fi
  grep -Fq "$message" "$tmp/stderr" || {
    echo "Gate failed for an unexpected reason; expected '$message':" >&2
    cat "$tmp/stderr" >&2
    exit 1
  }
}

GITHUB_OUTPUT="$tmp/unsigned-output" WINDOWS_UPDATE_ED_KEY_1=placeholder \
  bash "$root/scripts/windows-release-gate.sh" "$config" > "$tmp/unsigned-log"
assert_output "$tmp/unsigned-output" 'enabled=true'
assert_output "$tmp/unsigned-output" 'signing_enabled=false'
grep -Fq 'unsigned Windows installers' "$tmp/unsigned-log"

GITHUB_OUTPUT="$tmp/signed-output" WINDOWS_UPDATE_ED_KEY_1=placeholder \
  SIGNPATH_API_TOKEN=placeholder WINDOWS_SIGN_TEMPLATE=placeholder WINDOWS_SIGNER_THUMBPRINTS=012345 \
  bash "$root/scripts/windows-release-gate.sh" "$config" > "$tmp/signed-log"
assert_output "$tmp/signed-output" 'enabled=true'
assert_output "$tmp/signed-output" 'signing_enabled=true'

expect_gate_failure 'Incomplete Windows Authenticode signing configuration' SIGNPATH_API_TOKEN=placeholder
expect_gate_failure 'Incomplete Windows Authenticode signing configuration' SIGNPATH_API_TOKEN=placeholder WINDOWS_SIGN_TEMPLATE=placeholder
expect_gate_failure 'Incomplete Windows Authenticode signing configuration' WINDOWS_SIGNER_THUMBPRINTS=012345

if env GITHUB_OUTPUT="$tmp/missing-key-output" bash "$root/scripts/windows-release-gate.sh" "$config" > "$tmp/stdout" 2> "$tmp/stderr"; then
  echo 'Expected gate failure without WINDOWS_UPDATE_ED_KEY_1.' >&2
  exit 1
fi
grep -Fq 'WINDOWS_UPDATE_ED_KEY_1 is required' "$tmp/stderr"

: > "$tmp/no-public-keys.env"
if env GITHUB_OUTPUT="$tmp/missing-public-output" WINDOWS_UPDATE_ED_KEY_1=placeholder \
    bash "$root/scripts/windows-release-gate.sh" "$tmp/no-public-keys.env" > "$tmp/stdout" 2> "$tmp/stderr"; then
  echo 'Expected gate failure without WINDOWS_UPDATE_ED_KEYS.' >&2
  exit 1
fi
grep -Fq 'WINDOWS_UPDATE_ED_KEYS is missing or malformed' "$tmp/stderr"

echo 'Windows release gate scenarios passed.'
