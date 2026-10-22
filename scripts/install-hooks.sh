#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"
configured="$(git config --get core.hooksPath || true)"
if [[ -n "$configured" && "$configured" != '.githooks' ]]; then
  echo "Existing core.hooksPath '$configured' was preserved. Chain .githooks/pre-commit and .githooks/pre-push from your hooks manually, preserving pre-push arguments and stdin." >&2
  exit 1
fi
if [[ -z "$configured" ]]; then
  for hook in "$(git rev-parse --git-path hooks)"/*; do
    if [[ -f "$hook" && -x "$hook" && "$hook" != *.sample ]]; then
      echo "Existing hook '$hook' was preserved. Chain .githooks/pre-commit and .githooks/pre-push from your hooks manually without changing core.hooksPath, preserving pre-push arguments and stdin." >&2
      exit 1
    fi
  done
fi
for hook in .githooks/pre-commit .githooks/pre-push; do
  if [[ ! -f "$hook" ]]; then
    echo "The versioned '$hook' hook is missing in this checkout." >&2
    exit 1
  fi
  chmod +x "$hook"
done

git config --local core.hooksPath .githooks
echo "Installed staged whitespace checks and source-aware pre-push build, functional, and performance checks (core.hooksPath=.githooks)."
