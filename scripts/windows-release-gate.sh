#!/usr/bin/env bash
set -euo pipefail

env_file="${1:-Config/app.env}"
if [[ ! -r "$env_file" ]]; then
  echo "Cannot read Windows release configuration: $env_file" >&2
  exit 1
fi

keys="$(sed -n 's/^WINDOWS_UPDATE_ED_KEYS=//p' "$env_file" | head -n 1)"
if [[ -z "$keys" || ! "$keys" =~ ^[^,:[:space:]]+:[^,[:space:]]+(,[^,:[:space:]]+:[^,[:space:]]+)*$ ]]; then
  echo "WINDOWS_UPDATE_ED_KEYS is missing or malformed in Config/app.env; run scripts/make-windows-update-key.sh." >&2
  exit 1
fi
if [[ -z "${WINDOWS_UPDATE_ED_KEY_1:-}" ]]; then
  echo "WINDOWS_UPDATE_ED_KEY_1 is required to sign Windows update indexes; run scripts/make-windows-update-key.sh 1." >&2
  exit 1
fi

token="${SIGNPATH_API_TOKEN:-}"
template="${WINDOWS_SIGN_TEMPLATE:-}"
thumbprints="${WINDOWS_SIGNER_THUMBPRINTS:-}"
if [[ -z "$token" && -z "$template" && -z "$thumbprints" ]]; then
  signing_enabled=false
  echo "No Windows Authenticode signing is configured; the release will contain unsigned Windows installers."
elif [[ -n "$token" && -n "$template" && -n "$thumbprints" ]]; then
  signing_enabled=true
  echo "Windows Authenticode signing is configured; the release inventory will be enforced."
else
  echo "Incomplete Windows Authenticode signing configuration. Set SIGNPATH_API_TOKEN, WINDOWS_SIGN_TEMPLATE, and WINDOWS_SIGNER_THUMBPRINTS together, or leave all three unset." >&2
  exit 1
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  output="$GITHUB_OUTPUT"
else
  output=/dev/stdout
fi
{
  echo "enabled=true"
  echo "signing_enabled=$signing_enabled"
} >> "$output"
